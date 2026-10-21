-- Mi Planilla como SaaS: varias empresas en la misma base.
-- Cada fila de las tablas pl_* pertenece a una empresa (empresa_id) y la seguridad por filas
-- solo deja ver y tocar las filas de la empresa del usuario. Los datos que ya existían
-- quedan en la empresa "principal" (la que ya usaba la app).

-- ============ 1. Empresas, planes, miembros y suscripciones ============
create table pl_planes (
  codigo text primary key,
  nombre text not null,
  max_empleados int,                       -- null = sin límite
  precio_mensual numeric not null default 0,
  descripcion text,
  orden int not null default 100,
  publico boolean not null default true    -- se muestra en la página de precios
);
insert into pl_planes (codigo, nombre, max_empleados, precio_mensual, descripcion, orden, publico) values
  ('emprendedor', 'Emprendedor', 10, 750, 'Hasta 10 colaboradores', 1, true),
  ('pyme', 'Pyme', 30, 1750, 'Hasta 30 colaboradores', 2, true),
  ('empresa', 'Empresa', 80, 3900, 'Hasta 80 colaboradores', 3, true),
  ('interno', 'Interno', null, 0, 'Sin límite (uso propio)', 99, false);

create table pl_empresas (
  id uuid primary key default gen_random_uuid(),
  nombre text not null,
  rtn text,
  telefono text,
  correo text,
  contacto text,
  plan text not null default 'emprendedor' references pl_planes(codigo),
  estado text not null default 'prueba' check (estado in ('prueba', 'activa', 'suspendida', 'cancelada')),
  vence_en date,                           -- null = no vence
  max_empleados int,                       -- si se llena, reemplaza el límite del plan
  principal boolean not null default false,
  nota text,
  creado_por uuid,
  creado_en timestamptz not null default now()
);
create unique index pl_empresas_una_principal on pl_empresas (principal) where principal;

create table pl_miembros (
  user_id uuid primary key references auth.users(id) on delete cascade,
  empresa_id uuid not null references pl_empresas(id) on delete cascade,
  creado_en timestamptz not null default now()
);
create index on pl_miembros (empresa_id);

create table pl_superadmins (user_id uuid primary key references auth.users(id) on delete cascade);

create table pl_suscripcion_pagos (
  id uuid primary key default gen_random_uuid(),
  empresa_id uuid not null references pl_empresas(id) on delete cascade,
  fecha date not null default current_date,
  monto numeric not null,
  meses int not null check (meses > 0),
  plan text references pl_planes(codigo),
  referencia text,
  nota text,
  vence_antes date,
  vence_despues date,
  registrado_por uuid default auth.uid(),
  creado_en timestamptz not null default now()
);
create index on pl_suscripcion_pagos (empresa_id);

-- datos del dueño del servicio (cuenta para pagos, WhatsApp de ventas, etc.)
create table pl_plataforma (clave text primary key, valor text);
insert into pl_plataforma (clave, valor) values
  ('pago_instrucciones', 'Transfiere el monto de tu plan y envía el comprobante por WhatsApp.'),
  ('pago_banco', ''), ('pago_cuenta', ''), ('pago_titular', ''),
  ('ventas_whatsapp', ''), ('ventas_correo', ''), ('dias_prueba', '15'), ('dias_gracia', '5');

-- la empresa que ya usaba la app
insert into pl_empresas (nombre, plan, estado, vence_en, principal)
select coalesce(nullif((select valor from pl_parametros where clave = 'empresa_nombre'), ''), 'Empresa principal'), 'interno', 'activa', null, true;

-- ============ 2. ¿De qué empresa es el usuario? ============
create or replace function pl_empresa_principal() returns uuid
language sql stable security definer set search_path = public as $$
  select id from pl_empresas where principal
$$;

-- Miembro explícito, o (para cuentas del ecosistema con perfil) la empresa principal.
create or replace function pl_empresa_de(p_uid uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select empresa_id from pl_miembros where user_id = p_uid),
    (select pl_empresa_principal() where exists (select 1 from perfiles where id = p_uid)))
$$;

create or replace function pl_empresa_actual() returns uuid
language sql stable security definer set search_path = public as $$
  select pl_empresa_de(auth.uid())
$$;

create or replace function pl_es_superadmin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from pl_superadmins where user_id = auth.uid())
$$;

-- La empresa puede escribir si está en prueba o activa y no pasó la gracia después del vencimiento.
create or replace function pl_empresa_vigente(p_empresa uuid default null) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((
    select e.estado in ('prueba', 'activa')
       and (e.vence_en is null or e.vence_en + coalesce((select valor::int from pl_plataforma where clave = 'dias_gracia'), 5) >= pl__hoy())
      from pl_empresas e where e.id = coalesce(p_empresa, pl_empresa_actual())), false)
$$;

-- Cuentas que pertenecen a una empresa cliente (no al ecosistema): no deben ver datos de las otras apps.
create or replace function pl_es_externo() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from pl_miembros m where m.user_id = auth.uid() and m.empresa_id is distinct from pl_empresa_principal())
$$;

-- miembros existentes de la app → empresa principal
insert into pl_miembros (user_id, empresa_id)
select distinct u, pl_empresa_principal() from (
  select user_id u from pl_empleados where user_id is not null
  union select user_id from pl_admins
  union select user_id from pl_supervisores) x
where exists (select 1 from auth.users where id = x.u)
on conflict do nothing;

-- ============ 3. empresa_id en todas las tablas de la app ============
do $$
declare t text; v_pri uuid := pl_empresa_principal();
begin
  for t in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'public' and c.relkind = 'r' and c.relname like 'pl\_%'
              and c.relname not in ('pl_planes', 'pl_empresas', 'pl_miembros', 'pl_superadmins', 'pl_suscripcion_pagos', 'pl_plataforma')
  loop
    execute format('alter table %I disable trigger user', t);
    execute format('alter table %I add column empresa_id uuid references pl_empresas(id) on delete cascade', t);
    execute format('update %I set empresa_id = %L', t, v_pri);
    execute format('alter table %I alter column empresa_id set default pl_empresa_actual(), alter column empresa_id set not null', t);
    execute format('create index %I on %I (empresa_id)', t || '_empresa_idx', t);
    execute format('alter table %I enable trigger user', t);
  end loop;
end $$;

-- únicos que ahora son por empresa
alter table pl_parametros drop constraint pl_parametros_pkey, add primary key (empresa_id, clave);
alter table pl_periodos drop constraint pl_periodos_codigo_key, add constraint pl_periodos_codigo_key unique (empresa_id, codigo);
alter table pl_conceptos drop constraint pl_conceptos_nombre_tipo_key, add constraint pl_conceptos_nombre_tipo_key unique (empresa_id, nombre, tipo);
alter table pl_pagos_extra drop constraint pl_pagos_extra_numero_key, add constraint pl_pagos_extra_numero_key unique (empresa_id, numero);
alter table pl_constancias drop constraint pl_constancias_folio_key, add constraint pl_constancias_folio_key unique (empresa_id, folio);

-- ============ 4. Funciones que ahora respetan la empresa ============
-- El admin general del ecosistema solo es admin de planilla en la empresa principal.
create or replace function pl_es_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select (exists (select 1 from perfiles where id = auth.uid() and rol = 'admin' and activo) and pl_empresa_actual() = pl_empresa_principal())
      or exists (select 1 from pl_admins where user_id = auth.uid())
$$;

create or replace function pl_nombres_usuarios(p_ids uuid[]) returns table(id uuid, nombre text, usuario text)
language sql stable security definer set search_path = public as $$
  select u.id,
         coalesce(e.nombre, p.nombre, split_part(u.email, '@', 1)) as nombre,
         coalesce(e.usuario, split_part(u.email, '@', 1)) as usuario
    from auth.users u
    left join pl_empleados e on e.user_id = u.id and e.empresa_id = pl_empresa_actual()
    left join perfiles p on p.id = u.id
   where u.id = any(p_ids) and pl_es_supervisor() and pl_empresa_de(u.id) = pl_empresa_actual()
$$;

-- La bitácora toma la empresa de la fila (también cuando escribe el servidor sin sesión).
create or replace function pl_tg_auditoria() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_nom text; v_old jsonb; v_new jsonb; v_id text; v_emp uuid;
begin
  if tg_op = 'UPDATE' then
    v_old := to_jsonb(old); v_new := to_jsonb(new);
    if v_old = v_new then return new; end if;
  elsif tg_op = 'INSERT' then
    if tg_table_name = 'pl_asistencia' then return new; end if;  -- la generación masiva no se registra
    v_new := to_jsonb(new);
  else
    v_old := to_jsonb(old);
  end if;
  v_id := coalesce(v_new->>'id', v_old->>'id', v_new->>'user_id', v_old->>'user_id', v_new->>'clave', v_old->>'clave');
  v_emp := coalesce((v_new->>'empresa_id')::uuid, (v_old->>'empresa_id')::uuid, pl_empresa_actual());
  select coalesce((select nombre from pl_empleados where user_id = auth.uid() limit 1),
                  (select nombre from perfiles where id = auth.uid()),
                  case when auth.uid() is null then 'Sistema' end) into v_nom;
  insert into pl_auditoria (empresa_id, tabla, registro_id, accion, antes, despues, usuario, usuario_nombre)
  values (v_emp, tg_table_name, v_id, lower(tg_op), v_old, v_new, auth.uid(), v_nom);
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;

-- Lista de empleados que usa la app de conciliación: solo los de la empresa principal.
create or replace function cb_empleados() returns table(id uuid, nombre text, cargo text, area text, user_id uuid)
language sql stable security definer set search_path to 'public' as $$
  select e.id, e.nombre, e.cargo, e.area, e.user_id
  from public.pl_empleados e
  where public.cb_permitido() and coalesce(e.activo, true) and e.fecha_baja is null
    and e.empresa_id = public.pl_empresa_principal()
  order by e.nombre;
$$;

-- empleado de la empresa del usuario (para las fotos de marcaje y odómetro)
create or replace function pl_empleado_mio(p_id text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from pl_empleados where id::text = p_id and empresa_id = pl_empresa_actual())
$$;

-- ============ 5. Las funciones de la app corren con un rol sin "bypass" ============
-- Antes corrían como postgres (que se salta la seguridad por filas). Ahora corren como
-- pl_definer, que sí la respeta: cada consulta dentro de ellas queda limitada a la empresa.
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'pl_definer') then
    create role pl_definer nologin inherit nobypassrls;
  end if;
end $$;
grant pl_definer to postgres;
-- hereda lo de un usuario normal (auth.uid(), etc.); en tablas de otras apps sigue limitado por sus propias reglas
grant authenticated to pl_definer;
grant usage on schema public, extensions to pl_definer;
grant select on perfiles, feriados to pl_definer;
create policy pl_definer_leer on perfiles for select to pl_definer using (true);
create policy pl_definer_leer on feriados for select to pl_definer using (true);
grant create on schema public to pl_definer;  -- requisito para cambiar el dueño; se quita abajo
do $$
declare r record;
begin
  for r in select c.relname, c.relkind from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'public' and c.relname like 'pl\_%' and c.relkind in ('r', 'S', 'v') loop
    if r.relkind = 'S' then execute format('grant usage, select, update on sequence %I to pl_definer', r.relname);
    else execute format('grant select, insert, update, delete on %I to pl_definer', r.relname); end if;
  end loop;
  for r in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname like 'pl%' loop
    execute format('grant execute on function %s to pl_definer', r.sig);
  end loop;
  -- dueño nuevo para las funciones de la app, salvo las que deben ver todas las empresas
  for r in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname like 'pl\_%' and p.prosecdef
              and p.proname not in ('pl_empresa_principal', 'pl_empresa_de', 'pl_empresa_actual', 'pl_es_superadmin',
                                    'pl_empresa_vigente', 'pl_es_externo', 'pl_nombres_usuarios', 'pl_tg_auditoria') loop
    execute format('alter function %s owner to pl_definer', r.sig);
  end loop;
end $$;
revoke create on schema public from pl_definer;

-- ============ 6. Seguridad por filas ============
do $$
declare t text;
begin
  for t in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'public' and c.relkind = 'r' and c.relname like 'pl\_%'
              and exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = c.relname and column_name = 'empresa_id')
              and c.relname not in ('pl_suscripcion_pagos', 'pl_miembros')
  loop
    -- las funciones de la app pueden todo... dentro de la empresa (ver las restrictivas)
    execute format('create policy pl_definer_todo on %I for all to pl_definer using (true) with check (true)', t);
    -- nadie ve ni escribe filas de otra empresa
    execute format('create policy pl_empresa on %I as restrictive for all to public using (empresa_id = (select pl_empresa_actual())) with check (empresa_id = (select pl_empresa_actual()))', t);
    -- con la suscripción vencida o suspendida la app queda en solo lectura
    execute format('create policy pl_vigente_ins on %I as restrictive for insert to public with check ((select pl_empresa_vigente()))', t);
    execute format('create policy pl_vigente_upd on %I as restrictive for update to public using ((select pl_empresa_vigente()))', t);
    execute format('create policy pl_vigente_del on %I as restrictive for delete to public using ((select pl_empresa_vigente()))', t);
  end loop;
end $$;

alter table pl_planes enable row level security;
alter table pl_empresas enable row level security;
alter table pl_miembros enable row level security;
alter table pl_superadmins enable row level security;
alter table pl_suscripcion_pagos enable row level security;
alter table pl_plataforma enable row level security;
create policy pl_planes_sel on pl_planes for select to anon, authenticated using (true);
create policy pl_plataforma_sel on pl_plataforma for select to anon, authenticated using (true);
create policy pl_empresas_sel on pl_empresas for select to authenticated using (id = (select pl_empresa_actual()) or (select pl_es_superadmin()));
create policy pl_miembros_sel on pl_miembros for select to authenticated using (user_id = (select auth.uid()) or (select pl_es_superadmin()));
create policy pl_superadmins_sel on pl_superadmins for select to authenticated using (user_id = (select auth.uid()));
create policy pl_susc_sel on pl_suscripcion_pagos for select to authenticated
  using ((empresa_id = (select pl_empresa_actual()) and (select pl_es_admin())) or (select pl_es_superadmin()));
grant select on pl_planes, pl_plataforma to anon;
grant select on pl_planes, pl_plataforma, pl_empresas, pl_miembros, pl_superadmins, pl_suscripcion_pagos to authenticated, pl_definer;
revoke insert, update, delete on pl_planes, pl_plataforma, pl_empresas, pl_miembros, pl_superadmins, pl_suscripcion_pagos from anon, authenticated;

-- fotos: el supervisor solo ve las de empleados de su empresa
alter policy pl_marcajes_foto_sel on storage.objects
  using (bucket_id = 'pl-marcajes' and (((storage.foldername(name))[1] = (pl_mi_empleado())::text) or (pl_es_supervisor() and pl_empleado_mio((storage.foldername(name))[1]))));
alter policy pl_odometro_foto_sel on storage.objects
  using (bucket_id = 'pl-odometro' and (((storage.foldername(name))[1] = (pl_mi_empleado())::text) or (pl_es_supervisor() and pl_empleado_mio((storage.foldername(name))[1]))));

-- las cuentas de empresas clientes no ven las tablas abiertas de las otras apps del ecosistema
create policy no_externos on parametros as restrictive for all to authenticated using (not (select pl_es_externo()));
create policy no_externos on caja_cajeros as restrictive for all to authenticated using (not (select pl_es_externo()));

-- ============ 7. Límite de empleados según el plan ============
create or replace function pl_tg_limite_empleados() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_max int; v_n int;
begin
  if not (coalesce(new.activo, true) and new.fecha_baja is null) then return new; end if;
  if tg_op = 'UPDATE' and coalesce(old.activo, true) and old.fecha_baja is null then return new; end if;
  select coalesce(e.max_empleados, p.max_empleados) into v_max
    from pl_empresas e left join pl_planes p on p.codigo = e.plan where e.id = new.empresa_id;
  if v_max is null then return new; end if;
  select count(*) into v_n from pl_empleados
   where empresa_id = new.empresa_id and coalesce(activo, true) and fecha_baja is null and id <> new.id;
  if v_n >= v_max then
    raise exception 'Tu plan permite hasta % colaboradores activos. Cambia de plan en Ajustes › Suscripción para agregar más.', v_max;
  end if;
  return new;
end $$;
create trigger pl_limite_empleados before insert or update of activo, fecha_baja on pl_empleados
  for each row execute function pl_tg_limite_empleados();

-- ============ 8. Alta de empresas nuevas (la llama la función de registro con la clave de servicio) ============
create or replace function pl_alta_empresa(p_user uuid, p_empresa text, p_rtn text, p_telefono text, p_nombre text, p_correo text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_emp uuid; v_pri uuid := pl_empresa_principal();
  v_dias int := coalesce((select valor::int from pl_plataforma where clave = 'dias_prueba'), 15);
begin
  if exists (select 1 from pl_miembros where user_id = p_user) then raise exception 'Esta cuenta ya pertenece a una empresa'; end if;
  insert into pl_empresas (nombre, rtn, telefono, correo, contacto, plan, estado, vence_en, creado_por)
  values (trim(p_empresa), nullif(trim(p_rtn), ''), nullif(trim(p_telefono), ''), lower(trim(p_correo)), trim(p_nombre),
          'emprendedor', 'prueba', pl__hoy() + v_dias, p_user)
  returning id into v_emp;
  insert into pl_miembros (user_id, empresa_id) values (p_user, v_emp);
  insert into pl_admins (user_id, autoriza, empresa_id) values (p_user, true, v_emp);
  -- conceptos generales (sin los de comisiones propios de la empresa principal)
  insert into pl_conceptos (nombre, tipo, aplica, orden, activo, empresa_id)
  select nombre, tipo, aplica, orden, activo, v_emp from pl_conceptos
   where empresa_id = v_pri and (aplica in ('ambos', 'salario') or nombre in ('Bonificaciones', 'Referidos', 'Verificaciones'));
  insert into pl_conceptos (nombre, tipo, aplica, orden, activo, empresa_id) values
    ('IHSS', 'deduccion', 'salario', 1, true, v_emp), ('RAP', 'deduccion', 'salario', 2, true, v_emp), ('ISR', 'deduccion', 'salario', 3, true, v_emp)
  on conflict do nothing;
  -- reglas con los valores por defecto, sin los datos propios de la empresa principal
  insert into pl_parametros (clave, valor, descripcion, empresa_id)
  select clave,
         case clave when 'empresa_nombre' then trim(p_empresa) when 'empresa_rtn' then coalesce(trim(p_rtn), '')
                    when 'empresa_telefono' then coalesce(trim(p_telefono), '') when 'firma_nombre' then trim(p_nombre)
                    when 'firma_cargo' then 'Gerente' when 'marcaje_habilitado' then 'no'
                    when 'empresa_logo' then '' when 'empresa_direccion' then '' when 'empresa_ciudad' then ''
                    when 'contab_banco' then '' else valor end,
         descripcion, v_emp
    from pl_parametros where empresa_id = v_pri;
  return v_emp;
end $$;
revoke all on function pl_alta_empresa(uuid, text, text, text, text, text) from public, anon, authenticated;
grant execute on function pl_alta_empresa(uuid, text, text, text, text, text) to service_role;

-- ============ 9. Suscripción (para el admin de cada empresa) ============
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
    'pagos', case when pl_es_admin() then (select coalesce(jsonb_agg(to_jsonb(s) order by s.fecha desc), '[]') from pl_suscripcion_pagos s where s.empresa_id = e.id) end)
  from pl_empresas e left join pl_planes p on p.codigo = e.plan
  where e.id = pl_empresa_actual()
$$;

-- ============ 10. Panel del dueño del servicio ============
create or replace function pl_sa_empresas() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not pl_es_superadmin() then raise exception 'Sin permiso'; end if;
  return (select coalesce(jsonb_agg(to_jsonb(x) order by x.principal desc, x.creado_en desc), '[]') from (
    select e.*, pl_empresa_vigente(e.id) as vigente,
           (select count(*) from pl_empleados m where m.empresa_id = e.id and coalesce(m.activo, true) and m.fecha_baja is null) as empleados,
           (select string_agg(u.email, ', ') from pl_admins a join auth.users u on u.id = a.user_id where a.empresa_id = e.id) as admins,
           (select max(s.fecha) from pl_suscripcion_pagos s where s.empresa_id = e.id) as ultimo_pago,
           (select coalesce(sum(s.monto), 0) from pl_suscripcion_pagos s where s.empresa_id = e.id) as total_pagado
      from pl_empresas e) x);
end $$;

create or replace function pl_sa_registrar_pago(p_empresa uuid, p_monto numeric, p_meses int, p_plan text default null, p_referencia text default null, p_nota text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare e pl_empresas; v_nuevo date;
begin
  if not pl_es_superadmin() then raise exception 'Sin permiso'; end if;
  select * into e from pl_empresas where id = p_empresa for update;
  if e.id is null then raise exception 'Empresa no encontrada'; end if;
  v_nuevo := (greatest(coalesce(e.vence_en, pl__hoy()), pl__hoy()) + make_interval(months => p_meses))::date;
  insert into pl_suscripcion_pagos (empresa_id, monto, meses, plan, referencia, nota, vence_antes, vence_despues)
  values (p_empresa, p_monto, p_meses, coalesce(nullif(p_plan, ''), e.plan), nullif(trim(p_referencia), ''), nullif(trim(p_nota), ''), e.vence_en, v_nuevo);
  update pl_empresas set estado = 'activa', vence_en = v_nuevo, plan = coalesce(nullif(p_plan, ''), plan) where id = p_empresa;
  return jsonb_build_object('vence_en', v_nuevo);
end $$;

create or replace function pl_sa_editar_empresa(p_empresa uuid, p_estado text, p_plan text, p_vence date, p_max int, p_nota text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not pl_es_superadmin() then raise exception 'Sin permiso'; end if;
  update pl_empresas set estado = p_estado, plan = p_plan, vence_en = p_vence, max_empleados = p_max, nota = nullif(trim(p_nota), '')
   where id = p_empresa;
end $$;

create or replace function pl_sa_guardar_plataforma(p_datos jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not pl_es_superadmin() then raise exception 'Sin permiso'; end if;
  insert into pl_plataforma (clave, valor) select key, value from jsonb_each_text(p_datos)
  on conflict (clave) do update set valor = excluded.valor;
end $$;

create or replace function pl_sa_guardar_plan(p_codigo text, p_nombre text, p_max int, p_precio numeric, p_descripcion text, p_publico boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not pl_es_superadmin() then raise exception 'Sin permiso'; end if;
  insert into pl_planes (codigo, nombre, max_empleados, precio_mensual, descripcion, publico)
  values (p_codigo, p_nombre, p_max, p_precio, p_descripcion, p_publico)
  on conflict (codigo) do update set nombre = excluded.nombre, max_empleados = excluded.max_empleados,
    precio_mensual = excluded.precio_mensual, descripcion = excluded.descripcion, publico = excluded.publico;
end $$;

revoke execute on function pl_sa_empresas(), pl_sa_registrar_pago(uuid, numeric, int, text, text, text),
  pl_sa_editar_empresa(uuid, text, text, date, int, text), pl_sa_guardar_plataforma(jsonb),
  pl_sa_guardar_plan(text, text, int, numeric, text, boolean), pl_mi_suscripcion() from public, anon;
grant execute on function pl_sa_empresas(), pl_sa_registrar_pago(uuid, numeric, int, text, text, text),
  pl_sa_editar_empresa(uuid, text, text, date, int, text), pl_sa_guardar_plataforma(jsonb),
  pl_sa_guardar_plan(text, text, int, numeric, text, boolean), pl_mi_suscripcion() to authenticated;

-- el dueño del proyecto administra la plataforma
insert into pl_superadmins (user_id) select id from auth.users where lower(email) = 'ramoska26som@gmail.com' on conflict do nothing;
