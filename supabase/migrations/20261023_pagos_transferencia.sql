-- Pago de suscripción por transferencia dentro de la app.
-- El admin de la empresa reporta su transferencia (con foto del comprobante) o pide una cotización;
-- el dueño del servicio la confirma o rechaza desde Plataforma. Al confirmar se registra el pago y se extiende el plan.

create table pl_suscripcion_reportes (
  id uuid primary key default gen_random_uuid(),
  empresa_id uuid not null references pl_empresas(id) on delete cascade,
  tipo text not null default 'pago' check (tipo in ('pago', 'cotizacion')),
  plan text references pl_planes(codigo),
  meses int check (meses between 1 and 24),
  monto numeric check (monto >= 0),
  fecha_transferencia date,
  banco_origen text,
  referencia text,
  colaboradores int,
  nota text,
  comprobante_path text,
  estado text not null default 'pendiente' check (estado in ('pendiente', 'aprobado', 'rechazado', 'cancelado')),
  respuesta text,
  pago_id uuid references pl_suscripcion_pagos(id) on delete set null,
  reportado_por uuid default auth.uid(),
  reportado_en timestamptz not null default now(),
  revisado_por uuid,
  revisado_en timestamptz
);
create index on pl_suscripcion_reportes (empresa_id, reportado_en desc);
create index on pl_suscripcion_reportes (estado) where estado = 'pendiente';
alter table pl_suscripcion_reportes enable row level security;
create policy pl_srep_sel on pl_suscripcion_reportes for select to authenticated
  using ((empresa_id = (select pl_empresa_actual()) and (select pl_es_admin())) or (select pl_es_superadmin()));
grant select on pl_suscripcion_reportes to authenticated;
revoke insert, update, delete on pl_suscripcion_reportes from anon, authenticated;

insert into pl_plataforma (clave, valor) values ('pago_tipo_cuenta', '') on conflict (clave) do nothing;

-- comprobantes: carpeta por empresa; solo sus admins y el dueño del servicio los ven
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('pl-suscripcion', 'pl-suscripcion', false, 5242880, array['image/jpeg', 'image/png', 'image/webp', 'application/pdf'])
on conflict (id) do nothing;
create policy pl_susc_comp_ins on storage.objects for insert to authenticated
  with check (bucket_id = 'pl-suscripcion' and (storage.foldername(name))[1] = (select pl_empresa_actual())::text and (select pl_es_admin()));
create policy pl_susc_comp_sel on storage.objects for select to authenticated
  using (bucket_id = 'pl-suscripcion' and ((select pl_es_superadmin())
         or ((storage.foldername(name))[1] = (select pl_empresa_actual())::text and (select pl_es_admin()))));

-- ============ admin de la empresa ============
create or replace function pl_reportar_pago(p_plan text, p_meses int, p_monto numeric, p_fecha date, p_banco text,
  p_referencia text, p_nota text default null, p_comprobante text default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_emp uuid := pl_empresa_actual(); v_id uuid; v_pl pl_planes;
begin
  if v_emp is null or not pl_es_admin() then raise exception 'Solo el administrador de la empresa puede reportar pagos'; end if;
  if v_emp = pl_empresa_principal() then raise exception 'Esta empresa no paga suscripción'; end if;
  select * into v_pl from pl_planes where codigo = p_plan;
  if v_pl.codigo is null then raise exception 'Elige un plan'; end if;
  if coalesce(p_meses, 0) not between 1 and 24 then raise exception 'Elige cuántos meses pagas'; end if;
  if coalesce(p_monto, 0) <= 0 then raise exception 'Escribe el monto transferido'; end if;
  if p_fecha is null or p_fecha > pl__hoy() or p_fecha < pl__hoy() - 60 then raise exception 'Revisa la fecha de la transferencia'; end if;
  if coalesce(trim(p_referencia), '') = '' then raise exception 'Escribe el número de referencia de la transferencia'; end if;
  if coalesce(p_comprobante, '') <> '' and split_part(p_comprobante, '/', 1) <> v_emp::text then raise exception 'Comprobante no válido'; end if;
  if exists (select 1 from pl_suscripcion_reportes where empresa_id = v_emp and tipo = 'pago' and estado in ('pendiente', 'aprobado')
              and lower(trim(referencia)) = lower(trim(p_referencia))) then
    raise exception 'Ya reportaste una transferencia con esa referencia';
  end if;
  insert into pl_suscripcion_reportes (empresa_id, tipo, plan, meses, monto, fecha_transferencia, banco_origen, referencia, nota, comprobante_path)
  values (v_emp, 'pago', p_plan, p_meses, p_monto, p_fecha, nullif(trim(p_banco), ''), trim(p_referencia), nullif(trim(p_nota), ''), nullif(p_comprobante, ''))
  returning id into v_id;
  return v_id;
end $$;

create or replace function pl_solicitar_cotizacion(p_colaboradores int, p_nota text default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_emp uuid := pl_empresa_actual(); v_id uuid;
begin
  if v_emp is null or not pl_es_admin() then raise exception 'Solo el administrador de la empresa puede pedir cotización'; end if;
  if coalesce(p_colaboradores, 0) < 1 then raise exception 'Indica cuántos colaboradores tendrás'; end if;
  if exists (select 1 from pl_suscripcion_reportes where empresa_id = v_emp and tipo = 'cotizacion' and estado = 'pendiente') then
    raise exception 'Ya tienes una cotización en proceso; te contactaremos pronto';
  end if;
  insert into pl_suscripcion_reportes (empresa_id, tipo, plan, colaboradores, nota)
  values (v_emp, 'cotizacion', 'personalizado', p_colaboradores, nullif(trim(p_nota), '')) returning id into v_id;
  return v_id;
end $$;

create or replace function pl_cancelar_reporte(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not pl_es_admin() then raise exception 'Sin permiso'; end if;
  update pl_suscripcion_reportes set estado = 'cancelado', revisado_en = now(), revisado_por = auth.uid()
   where id = p_id and empresa_id = pl_empresa_actual() and estado = 'pendiente';
  if not found then raise exception 'Solo se pueden cancelar reportes pendientes'; end if;
end $$;

-- ============ dueño del servicio ============
create or replace function pl_sa_reportes() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not pl_es_superadmin() then raise exception 'Sin permiso'; end if;
  return (select coalesce(jsonb_agg(to_jsonb(x) order by x.estado <> 'pendiente', x.reportado_en desc), '[]') from (
    select r.*, e.nombre as empresa, e.plan as plan_actual, e.vence_en, e.contacto, e.telefono, e.correo,
           (select count(*) from pl_empleados m where m.empresa_id = r.empresa_id and coalesce(m.activo, true) and m.fecha_baja is null) as empleados
      from pl_suscripcion_reportes r join pl_empresas e on e.id = r.empresa_id
     where r.estado = 'pendiente' or r.reportado_en > now() - interval '60 days') x);
end $$;

create or replace function pl_sa_resolver_reporte(p_id uuid, p_aprobar boolean, p_respuesta text default null,
  p_monto numeric default null, p_meses int default null, p_plan text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r pl_suscripcion_reportes; res jsonb; v_pago uuid;
begin
  if not pl_es_superadmin() then raise exception 'Sin permiso'; end if;
  select * into r from pl_suscripcion_reportes where id = p_id for update;
  if r.id is null or r.estado <> 'pendiente' then raise exception 'Ese reporte ya fue resuelto'; end if;
  if p_aprobar and r.tipo = 'pago' then
    res := pl_sa_registrar_pago(r.empresa_id, coalesce(p_monto, r.monto), coalesce(p_meses, r.meses), coalesce(nullif(p_plan, ''), r.plan),
                                r.referencia, coalesce(nullif(trim(p_respuesta), ''), 'Transferencia reportada en la app'));
    select id into v_pago from pl_suscripcion_pagos where empresa_id = r.empresa_id order by creado_en desc limit 1;
  end if;
  update pl_suscripcion_reportes set estado = case when p_aprobar then 'aprobado' else 'rechazado' end,
    respuesta = nullif(trim(p_respuesta), ''), revisado_por = auth.uid(), revisado_en = now(), pago_id = v_pago
   where id = p_id;
  return coalesce(res, '{}'::jsonb);
end $$;

revoke execute on function pl_reportar_pago(text, int, numeric, date, text, text, text, text), pl_solicitar_cotizacion(int, text),
  pl_cancelar_reporte(uuid), pl_sa_reportes(), pl_sa_resolver_reporte(uuid, boolean, text, numeric, int, text) from public, anon;
grant execute on function pl_reportar_pago(text, int, numeric, date, text, text, text, text), pl_solicitar_cotizacion(int, text),
  pl_cancelar_reporte(uuid), pl_sa_reportes(), pl_sa_resolver_reporte(uuid, boolean, text, numeric, int, text) to authenticated;

-- la suscripción del admin incluye sus reportes
create or replace function pl_mi_suscripcion() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'empresa', jsonb_build_object('id', e.id, 'nombre', e.nombre, 'plan', e.plan, 'estado', e.estado, 'vence_en', e.vence_en, 'principal', e.principal),
    'plan', to_jsonb(p),
    'max_empleados', coalesce(e.max_empleados, p.max_empleados),
    'empleados', (select count(*) from pl_empleados m where m.empresa_id = e.id and coalesce(m.activo, true) and m.fecha_baja is null),
    'vigente', pl_empresa_vigente(e.id),
    'dias', e.vence_en - pl__hoy(),
    'superadmin', pl_es_superadmin(),
    'pagos', case when pl_es_admin() then (select coalesce(jsonb_agg(to_jsonb(s) order by s.fecha desc), '[]') from pl_suscripcion_pagos s where s.empresa_id = e.id) end,
    'reportes', case when pl_es_admin() then (select coalesce(jsonb_agg(to_jsonb(r) order by r.reportado_en desc), '[]') from pl_suscripcion_reportes r where r.empresa_id = e.id and r.reportado_en > now() - interval '120 days') end)
  from pl_empresas e left join pl_planes p on p.codigo = e.plan
  where e.id = pl_empresa_actual()
$$;

-- el panel muestra cuántos reportes esperan revisión
create or replace function pl_sa_empresas() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not pl_es_superadmin() then raise exception 'Sin permiso'; end if;
  return (select coalesce(jsonb_agg(to_jsonb(x) order by x.principal desc, x.creado_en desc), '[]') from (
    select e.*, pl_empresa_vigente(e.id) as vigente,
           (select count(*) from pl_empleados m where m.empresa_id = e.id and coalesce(m.activo, true) and m.fecha_baja is null) as empleados,
           (select string_agg(u.email, ', ') from pl_admins a join auth.users u on u.id = a.user_id where a.empresa_id = e.id) as admins,
           (select max(s.fecha) from pl_suscripcion_pagos s where s.empresa_id = e.id) as ultimo_pago,
           (select coalesce(sum(s.monto), 0) from pl_suscripcion_pagos s where s.empresa_id = e.id) as total_pagado,
           (select count(*) from pl_suscripcion_reportes r where r.empresa_id = e.id and r.estado = 'pendiente') as reportes_pendientes
      from pl_empresas e) x);
end $$;

-- ============ avisos ============
create or replace function private.pl_push_susc_tg() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_emp text; v_plan text;
begin
  select nombre into v_emp from pl_empresas where id = new.empresa_id;
  select nombre into v_plan from pl_planes where codigo = new.plan;
  if tg_op = 'INSERT' then
    perform private.pl_push_enviar(array(select user_id from pl_superadmins),
      case when new.tipo = 'cotizacion' then '🧾 Solicitud de cotización' else '🏦 Transferencia por confirmar' end,
      v_emp || ' · ' || case when new.tipo = 'cotizacion' then new.colaboradores || ' colaboradores'
                             else 'L ' || to_char(new.monto, 'FM999,999,990.00') || ' · ' || coalesce(v_plan, '') || ' · ' || new.meses || ' mes(es)' end,
      '#/plataforma', 'srep-' || new.id);
  elsif old.estado = 'pendiente' and new.estado in ('aprobado', 'rechazado') then
    perform private.pl_push_enviar(private.pl_admins_de(new.empresa_id),
      case when new.tipo = 'cotizacion' then '🧾 Cotización atendida'
           when new.estado = 'aprobado' then '✅ Pago confirmado' else '❌ Pago no confirmado' end,
      coalesce(new.respuesta, case when new.estado = 'aprobado' and new.tipo = 'pago' then 'Tu plan ' || coalesce(v_plan, '') || ' quedó activo' else '' end),
      '#/suscripcion', 'srep-' || new.id);
  end if;
  return null;
exception when others then
  raise warning 'pl_push_susc_tg: %', sqlerrm;
  return null;
end $$;
create trigger pl_push after insert or update of estado on pl_suscripcion_reportes for each row execute function private.pl_push_susc_tg();
