-- Notificaciones push de Mi Planilla.
-- Al empleado: comprobante listo, solicitud aprobada o rechazada, adelanto entregado.
-- A administración/supervisión: solicitudes nuevas de los empleados.
-- Los avisos salen desde la base (triggers) hacia la función planilla-push, que los envía a los teléfonos.

-- teléfonos suscritos a la app de planilla (separados de los de VerifyCredito)
create table pl_push_subs (
  endpoint text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  empresa_id uuid references pl_empresas(id) on delete cascade,
  p256dh text not null,
  auth text not null,
  agente text,
  creado_en timestamptz not null default now(),
  actualizado_en timestamptz not null default now()
);
create index on pl_push_subs (user_id);
alter table pl_push_subs enable row level security;   -- sin políticas: solo por las funciones de abajo
revoke all on pl_push_subs from anon, authenticated;

create or replace function pl_guardar_push(p_endpoint text, p_p256dh text, p_auth text, p_agente text default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or pl_empresa_actual() is null then raise exception 'Sin permiso'; end if;
  insert into pl_push_subs (endpoint, user_id, empresa_id, p256dh, auth, agente) values (p_endpoint, auth.uid(), pl_empresa_actual(), p_p256dh, p_auth, left(p_agente, 300))
  on conflict (endpoint) do update set user_id = auth.uid(), empresa_id = pl_empresa_actual(), p256dh = excluded.p256dh, auth = excluded.auth,
    agente = excluded.agente, actualizado_en = now();
end $$;

create or replace function pl_borrar_push(p_endpoint text) returns void
language sql security definer set search_path = public as $$
  delete from pl_push_subs where endpoint = p_endpoint and user_id = auth.uid();
$$;
revoke execute on function pl_guardar_push(text, text, text, text), pl_borrar_push(text) from public, anon;
grant execute on function pl_guardar_push(text, text, text, text), pl_borrar_push(text) to authenticated;

-- ============ envío ============
create or replace function private.pl_push_enviar(p_ids uuid[], p_titulo text, p_cuerpo text, p_url text, p_tag text default null) returns void
language plpgsql security definer set search_path = public as $$
declare v_ids uuid[]; sec text;
begin
  -- quien hizo el cambio no recibe su propio aviso
  v_ids := array(select distinct x from unnest(p_ids) x where x is not null and x is distinct from auth.uid());
  if coalesce(array_length(v_ids, 1), 0) = 0 or not exists (select 1 from pl_push_subs where user_id = any(v_ids)) then return; end if;
  select v into sec from private.push_config where k = 'secreto';
  perform net.http_post(
    url := 'https://edmvfqelxsxevpmxgbav.supabase.co/functions/v1/planilla-push',
    body := jsonb_build_object('ids', to_jsonb(v_ids), 'title', p_titulo, 'body', coalesce(p_cuerpo, ''), 'url', p_url, 'tag', p_tag),
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-pl-secreto', sec),
    timeout_milliseconds := 10000);
end $$;

create or replace function private.pl_admins_de(p_empresa uuid) returns uuid[]
language sql stable security definer set search_path = public as $$
  select array(
    select user_id from pl_admins where empresa_id = p_empresa
    union select id from perfiles where rol = 'admin' and activo and p_empresa = pl_empresa_principal())
$$;

create or replace function private.pl_supervision_de(p_empresa uuid) returns uuid[]
language sql stable security definer set search_path = public as $$
  select private.pl_admins_de(p_empresa) || array(select user_id from pl_supervisores where empresa_id = p_empresa)
$$;

-- ============ qué se avisa ============
create or replace function private.pl_push_tg() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  j jsonb := to_jsonb(new);
  o jsonb := case when tg_op = 'UPDATE' then to_jsonb(old) else '{}'::jsonb end;
  ins boolean := tg_op = 'INSERT';
  -- pasó de pendiente a resuelto
  cambio boolean := tg_op = 'UPDATE' and o->>'estado' = 'pendiente' and (j->>'estado') is distinct from 'pendiente';
  e record; v_emp uuid := (j->>'empresa_id')::uuid; v_nom text; p text[];
  ok boolean; L text; rng text; t text := tg_table_name; v_id text := j->>'id';
  dm text := 'DD/MM';
begin
  select user_id, nombre into e from pl_empleados where id = (j->>'empleado_id')::uuid;
  p := string_to_array(trim(coalesce(e.nombre, '')), ' ');
  v_nom := case when array_length(p, 1) >= 3 then p[1] || ' ' || p[array_length(p, 1) - 1] else coalesce(nullif(e.nombre, ''), 'Un empleado') end;

  if t = 'pl_comprobantes' then
    if (j->>'anulado')::boolean or not (ins or ((o->>'anulado')::boolean and not (j->>'anulado')::boolean)) then return null; end if;
    perform private.pl_push_enviar(array[e.user_id], case when ins then '💵 Tu comprobante de pago está listo' else '💵 Tu comprobante de pago fue actualizado' end,
      coalesce((select nombre from pl_periodos where id = (j->>'periodo_id')::uuid) || ' · ', '') || 'Neto L ' || to_char((j->>'neto')::numeric, 'FM999,999,990.00'),
      '#/mi-comprobante/' || v_id, 'comp-' || v_id);

  elsif t = 'pl_pagos_extra' then
    if not ins or (j->>'anulado')::boolean then return null; end if;
    perform private.pl_push_enviar(array[e.user_id],
      '💵 Tu pago de ' || case j->>'tipo' when 'depreciacion' then 'depreciación' else j->>'tipo' end || ' está listo',
      'L ' || to_char((j->>'monto')::numeric, 'FM999,999,990.00') || coalesce(' · ' || (j->>'numero'), ''), '#/pago/' || v_id, 'pago-' || v_id);

  elsif t = 'pl_adelantos' then
    L := 'L ' || to_char((j->>'monto')::numeric, 'FM999,999,990.00');
    if ins and j->>'origen' = 'empleado' then
      if j->>'estado' = 'pendiente' then
        perform private.pl_push_enviar(private.pl_admins_de(v_emp), '💰 Solicitud de adelanto', v_nom || ' pide ' || L || coalesce(' · ' || (j->>'motivo_revision'), ''), '#/solicitudes', 'adel-' || v_id);
      elsif j->>'estado' = 'aprobado' then
        perform private.pl_push_enviar(private.pl_admins_de(v_emp), '💰 Adelanto aprobado automáticamente', v_nom || ' · ' || L || ' · pendiente de entregar', '#/adelantos', 'adel-' || v_id);
      end if;
    elsif cambio and j->>'estado' in ('aprobado', 'rechazado') then
      perform private.pl_push_enviar(array[e.user_id], case when j->>'estado' = 'aprobado' then '✅ Tu adelanto fue aprobado' else '❌ Tu adelanto fue rechazado' end,
        L || coalesce(' · ' || nullif(j->>'respuesta', ''), ''), '#/mis-solicitudes', 'adel-' || v_id);
    end if;
    if tg_op = 'UPDATE' and o->>'desembolsado_en' is null and j->>'desembolsado_en' is not null then
      perform private.pl_push_enviar(array[e.user_id], '💸 Tu adelanto fue entregado',
        L || coalesce(' · ' || nullif(j->>'desembolso_metodo', ''), ''), '#/mis-solicitudes', 'adel-' || v_id);
    end if;

  elsif t in ('pl_vacaciones', 'pl_permisos', 'pl_horas_extra') then
    if t = 'pl_vacaciones' and j->>'tipo' <> 'solicitud' then return null; end if;
    if t = 'pl_horas_extra' then
      rng := trim_scale((j->>'horas')::numeric) || ' h el ' || to_char((j->>'fecha')::date, dm);
    elsif t = 'pl_permisos' and j->>'horas' is not null then
      rng := trim_scale((j->>'horas')::numeric) || ' h el ' || to_char((j->>'desde')::date, dm);
    else
      rng := case when t = 'pl_vacaciones' then trim_scale((j->>'dias')::numeric) || ' día(s) · ' else '' end || to_char((j->>'desde')::date, dm)
             || case when j->>'hasta' <> j->>'desde' then ' al ' || to_char((j->>'hasta')::date, dm) else '' end;
    end if;
    L := case t when 'pl_vacaciones' then 'Vacaciones' when 'pl_permisos' then 'Permiso'
           else case when j->>'tipo' = 'descanso' then 'Descanso compensatorio' else 'Horas extra' end end;
    if ins and j->>'estado' = 'pendiente' then
      perform private.pl_push_enviar(private.pl_supervision_de(v_emp), '📥 Solicitud: ' || L, v_nom || ' · ' || rng, '#/solicitudes', t || '-' || v_id);
    elsif cambio and j->>'estado' in ('aprobado', 'aprobada', 'rechazado', 'rechazada') then
      ok := j->>'estado' in ('aprobado', 'aprobada');
      perform private.pl_push_enviar(array[e.user_id], case when ok then '✅ Aprobado: ' || L else '❌ Rechazado: ' || L end,
        rng || coalesce(' · ' || nullif(j->>'respuesta', ''), ''), '#/mis-solicitudes', t || '-' || v_id);
    end if;

  elsif t = 'pl_constancia_solicitudes' then
    if ins and j->>'estado' = 'pendiente' then
      perform private.pl_push_enviar(private.pl_admins_de(v_emp), '📄 Solicitud de constancia', v_nom || coalesce(' · para ' || nullif(j->>'dirigido_a', ''), ''), '#/solicitudes', 'const-' || v_id);
    elsif cambio and j->>'estado' in ('emitida', 'rechazada') then
      perform private.pl_push_enviar(array[e.user_id], case when j->>'estado' = 'emitida' then '📄 Tu constancia está lista' else '❌ Tu constancia fue rechazada' end,
        coalesce(nullif(j->>'respuesta', ''), case when j->>'estado' = 'emitida' then 'Ya puedes descargarla en la app' else '' end), '#/mis-solicitudes', 'const-' || v_id);
    end if;

  elsif t = 'pl_marcajes' then
    if j->>'origen' is distinct from 'solicitud' then return null; end if;
    rng := case j->>'tipo' when 'entrada' then 'Entrada' when 'salida' then 'Salida' when 'almuerzo_inicio' then 'Salida a almuerzo' else 'Regreso de almuerzo' end
           || ' del ' || to_char((j->>'fecha')::date, dm) || ' a las ' || lower(to_char(((j->>'marcado_en')::timestamptz) at time zone 'America/Tegucigalpa', 'HH12:MI am'));
    if ins and j->>'estado' = 'pendiente' then
      perform private.pl_push_enviar(private.pl_supervision_de(v_emp), '🕒 Marcaje olvidado por revisar', v_nom || ' · ' || rng, '#/marcajes', 'marc-' || v_id);
    elsif cambio and j->>'estado' in ('aprobado', 'rechazado') then
      perform private.pl_push_enviar(array[e.user_id], case when j->>'estado' = 'aprobado' then '✅ Tu marcaje fue aprobado' else '❌ Tu marcaje fue rechazado' end,
        rng, '#/mi-tiempo', 'marc-' || v_id);
    end if;
  end if;
  return null;
exception when others then
  raise warning 'pl_push_tg %: %', tg_table_name, sqlerrm;
  return null;   -- un aviso nunca debe impedir guardar
end $$;

create trigger pl_push after insert or update of anulado on pl_comprobantes for each row execute function private.pl_push_tg();
create trigger pl_push after insert on pl_pagos_extra for each row execute function private.pl_push_tg();
create trigger pl_push after insert or update of estado, desembolsado_en on pl_adelantos for each row execute function private.pl_push_tg();
create trigger pl_push after insert or update of estado on pl_vacaciones for each row execute function private.pl_push_tg();
create trigger pl_push after insert or update of estado on pl_permisos for each row execute function private.pl_push_tg();
create trigger pl_push after insert or update of estado on pl_horas_extra for each row execute function private.pl_push_tg();
create trigger pl_push after insert or update of estado on pl_constancia_solicitudes for each row execute function private.pl_push_tg();
create trigger pl_push after insert or update of estado on pl_marcajes for each row execute function private.pl_push_tg();
