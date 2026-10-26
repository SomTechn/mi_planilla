-- Notificaciones: casos que faltaban
-- · adelanto registrado (y entregado) por administración a nombre del empleado
-- · vacaciones, permisos y horas extra registrados ya aprobados por administración o supervisión
-- · feriados con su nombre ("Feriado" en vez de "Permiso")
-- · marcajes rechazados (cualquiera) y aprobados que tenían alertas
-- · ajustes al banco de horas
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
    elsif ins and j->>'estado' = 'aprobado' then
      -- registrado por administración a nombre del empleado
      if j->>'desembolsado_en' is not null then
        perform private.pl_push_enviar(array[e.user_id], '💸 Se te entregó un adelanto',
          L || coalesce(' · ' || nullif(j->>'desembolso_metodo', ''), '') || ' · se descuenta en tu planilla', '#/mis-solicitudes', 'adel-' || v_id);
      else
        perform private.pl_push_enviar(array[e.user_id], '✅ Se registró un adelanto a tu nombre', L || ' · pendiente de entregar', '#/mis-solicitudes', 'adel-' || v_id);
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
    L := case t when 'pl_vacaciones' then 'Vacaciones' when 'pl_permisos' then case when j->>'feriado_id' is not null then 'Feriado' else 'Permiso' end
           else case when j->>'tipo' = 'descanso' then 'Descanso compensatorio' else 'Horas extra' end end;
    if ins and j->>'estado' = 'pendiente' then
      perform private.pl_push_enviar(private.pl_supervision_de(v_emp), '📥 Solicitud: ' || L, v_nom || ' · ' || rng, '#/solicitudes', t || '-' || v_id);
    elsif ins and j->>'estado' in ('aprobado', 'aprobada') then
      -- lo registró administración o supervisión directamente (el empleado no lo pidió)
      perform private.pl_push_enviar(array[e.user_id], case when t = 'pl_horas_extra' and j->>'tipo' = 'extra' then '⏱️ Se te registraron horas extra' else '✅ Se registró: ' || L end,
        rng || case when t = 'pl_horas_extra' and j->>'tipo' = 'extra' then case when j->>'destino' = 'pagar' then ' · se pagan en planilla' else ' · van a tu banco de horas' end else '' end,
        case when t = 'pl_horas_extra' then '#/mi-tiempo/horas' else '#/mis-solicitudes' end, t || '-' || v_id);
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

  elsif t = 'pl_horas_ajustes' then
    if not ins then return null; end if;
    perform private.pl_push_enviar(array[e.user_id], '⏱️ Ajuste a tu banco de horas',
      case when (j->>'horas')::numeric > 0 then '+' else '−' end || trim_scale(abs((j->>'horas')::numeric)) || ' h · ' || coalesce(j->>'motivo', ''), '#/mi-tiempo/horas', 'aj-' || v_id);

  elsif t = 'pl_marcajes' then
    if j->>'origen' is distinct from 'solicitud' and not (cambio and (j->>'estado' = 'rechazado' or jsonb_array_length(coalesce(j->'alertas', '[]'::jsonb)) > 0)) then return null; end if;
    rng := case j->>'tipo' when 'entrada' then 'Entrada' when 'salida' then 'Salida' when 'almuerzo_inicio' then 'Salida a almuerzo' else 'Regreso de almuerzo' end
           || ' del ' || to_char((j->>'fecha')::date, dm) || ' a las ' || lower(to_char(((j->>'marcado_en')::timestamptz) at time zone 'America/Tegucigalpa', 'HH12:MI am'));
    if ins and j->>'estado' = 'pendiente' then
      perform private.pl_push_enviar(private.pl_supervision_de(v_emp), '🕒 Marcaje olvidado por revisar', v_nom || ' · ' || rng, '#/marcajes', 'marc-' || v_id);
    elsif cambio and j->>'estado' in ('aprobado', 'rechazado') then
      perform private.pl_push_enviar(array[e.user_id], case when j->>'estado' = 'aprobado' then '✅ Tu marcaje fue aprobado' else '❌ Tu marcaje fue rechazado' end,
        rng || case when j->>'estado' = 'rechazado' then coalesce(' · ' || nullif(j->>'motivo_anulacion', ''), '') || ' · puedes volver a marcar' else '' end, '#/marcar', 'marc-' || v_id);
    end if;
  end if;
  return null;
exception when others then
  raise warning 'pl_push_tg %: %', tg_table_name, sqlerrm;
  return null;   -- un aviso nunca debe impedir guardar
end $$;

create trigger pl_push after insert on pl_horas_ajustes for each row execute function private.pl_push_tg();
