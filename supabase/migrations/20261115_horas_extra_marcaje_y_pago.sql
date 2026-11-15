-- v70 (15-nov-2026). Aplicada como `pl_horas_extra_marcaje_y_pago`.
-- 1) pl_aprobar_extra_marcaje: administración, gerencia o supervisión aprueban de un solo las horas extra que salen del marcaje
--    (quedan aprobadas, para pagar o para el banco de horas). Las horas las calcula el servidor con pl_marcaje_resumen.
-- 2) pl_horas_extra_pago: pasar a pago horas extra ya registradas que estaban en el banco de horas (o regresarlas al banco
--    mientras la planilla siga abierta).

create or replace function public.pl_aprobar_extra_marcaje(p_items jsonb, p_destino text, p_aprobar_marcas boolean default true)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare it jsonb; v_emp uuid; v_fecha date; e pl_empleados; r record; h pl_horas_extra;
  v_ini time; v_fin time; v_h numeric; v_per uuid; k int; v_pend int;
  n_new int := 0; n_upd int := 0; n_mk int := 0; t_h numeric := 0; omit jsonb := '[]'::jsonb;
begin
  if not pl_es_supervisor() then raise exception 'Solo administración, gerencia o supervisión'; end if;
  if coalesce(p_destino, '') not in ('pagar', 'compensar') then raise exception 'Elige si las horas se pagan o van al banco de horas'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'Elige al menos un día'; end if;
  if jsonb_array_length(p_items) > 500 then raise exception 'Son demasiados días a la vez (máximo 500)'; end if;

  for it in select * from jsonb_array_elements(p_items) loop
    v_emp := nullif(it->>'empleado_id', '')::uuid; v_fecha := nullif(it->>'fecha', '')::date;
    e := null; h := null;
    select * into e from pl_empleados where id = v_emp;
    if e.id is null or v_fecha is null then
      omit := omit || jsonb_build_object('empleado_id', v_emp, 'fecha', v_fecha, 'motivo', 'Empleado o fecha no válidos'); continue;
    end if;
    if not pl_es_admin() and v_emp = pl_mi_empleado() then
      omit := omit || jsonb_build_object('empleado_id', v_emp, 'fecha', v_fecha, 'motivo', 'Tus propias horas extra las aprueba administración'); continue;
    end if;
    if not e.activo or e.fecha_baja is not null then
      omit := omit || jsonb_build_object('empleado_id', v_emp, 'fecha', v_fecha, 'motivo', 'El empleado no está activo'); continue;
    end if;
    if p_destino = 'pagar' and not e.recibe_salario then
      omit := omit || jsonb_build_object('empleado_id', v_emp, 'fecha', v_fecha, 'motivo', 'No está en la planilla de salario; no se le pueden pagar horas extra'); continue;
    end if;
    if v_fecha > pl__hoy() then
      omit := omit || jsonb_build_object('empleado_id', v_emp, 'fecha', v_fecha, 'motivo', 'Es un día que todavía no pasa'); continue;
    end if;
    if v_fecha < pl__hoy() - 62 then
      omit := omit || jsonb_build_object('empleado_id', v_emp, 'fecha', v_fecha, 'motivo', 'Solo se aprueban horas extra de los últimos 2 meses'); continue;
    end if;

    -- con p_aprobar_marcas también cuentan las marcas por revisar (se aprueban abajo si se registran las horas)
    select * into r from pl_marcaje_resumen(v_fecha, v_fecha, v_emp, not p_aprobar_marcas) limit 1;
    if r.empleado_id is null or coalesce(r.extra_min, 0) <= 0 then
      select count(*) into v_pend from pl_marcajes where empleado_id = v_emp and fecha = v_fecha and not anulado and estado = 'pendiente';
      omit := omit || jsonb_build_object('empleado_id', v_emp, 'fecha', v_fecha, 'motivo',
        case when r.empleado_id is null then 'No está en la planilla de salario'
             when not p_aprobar_marcas and v_pend > 0 then 'Tiene marcajes por revisar; apruébalos primero'
             when r.m_salida is null then 'Sin marcaje de salida'
             when r.sin_horario then 'Sin horario ese día'
             else 'Sin horas extra según el marcaje' end);
      continue;
    end if;
    v_ini := case when r.libre then r.m_entrada else r.h_salida end;
    v_fin := r.m_salida;
    v_h := round(r.extra_min / 60.0, 2);
    v_per := case when p_destino = 'pagar' then pl__periodo_para_fecha(v_fecha) end;

    -- solicitud pendiente creada desde marcaje ("Aplicar a la planilla"): se aprueba con las horas del marcaje
    select * into h from pl_horas_extra
     where empleado_id = v_emp and fecha = v_fecha and tipo = 'extra' and estado = 'pendiente' and origen = 'marcaje'
     order by solicitado_en limit 1 for update;
    if h.id is null then
      -- otras horas extra de ese día que se cruzan con este horario
      select * into h from pl_horas_extra
       where empleado_id = v_emp and fecha = v_fecha and tipo = 'extra' and estado not in ('rechazada', 'cancelada')
         and (hora_inicio is null or hora_fin is null or (hora_inicio < v_fin and v_ini < hora_fin))
       order by (estado = 'pendiente') desc, solicitado_en limit 1;
      if h.id is not null then
        omit := omit || jsonb_build_object('empleado_id', v_emp, 'fecha', v_fecha, 'motivo',
          case when h.estado = 'pendiente' then 'Tiene una solicitud de horas extra pendiente ese día; resuélvela en Solicitudes'
               else 'Ya tiene ' || trim_scale(h.horas) || ' h extra registradas ese día' end);
        continue;
      end if;
    end if;

    if p_aprobar_marcas then
      update pl_marcajes set estado = 'aprobado', revisado_por = auth.uid(), revisado_en = now()
       where empleado_id = v_emp and fecha = v_fecha and not anulado and estado = 'pendiente';
      get diagnostics k = row_count; n_mk := n_mk + k;
    end if;

    if h.id is not null then
      update pl_horas_extra set estado = 'aprobada', horas = v_h, hora_inicio = v_ini, hora_fin = v_fin,
             destino = p_destino, preferencia = coalesce(preferencia, p_destino), periodo_id = v_per,
             resuelto_por = auth.uid(), resuelto_en = now(), respuesta = 'Aprobada desde marcaje'
       where id = h.id;
      n_upd := n_upd + 1;
    else
      insert into pl_horas_extra (empleado_id, tipo, fecha, horas, hora_inicio, hora_fin, motivo, preferencia, destino, estado, origen,
                                  solicitado_por, resuelto_por, resuelto_en, respuesta, periodo_id)
      values (v_emp, 'extra', v_fecha, v_h, v_ini, v_fin,
              case when r.libre then 'Trabajó en su día libre (según marcaje)' else 'Después de su hora de salida (según marcaje)' end,
              p_destino, p_destino, 'aprobada', 'marcaje', auth.uid(), auth.uid(), now(), 'Aprobada desde marcaje', v_per);
      n_new := n_new + 1;
    end if;
    t_h := t_h + v_h;
  end loop;

  return jsonb_build_object('creadas', n_new, 'aprobadas', n_upd, 'horas', t_h, 'marcas_aprobadas', n_mk, 'omitidas', omit);
end $function$;

create or replace function public.pl_horas_extra_pago(p_ids uuid[], p_pagar boolean default true, p_periodo uuid default null)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare per pl_periodos; h pl_horas_extra; e pl_empleados; b jsonb; v_emp uuid; emps uuid[] := '{}';
  n int := 0; t numeric := 0; v_hoy text := to_char(pl__hoy(), 'DD/MM/YYYY');
begin
  if not pl_es_supervisor() then raise exception 'Solo administración, gerencia o supervisión'; end if;
  if coalesce(array_length(p_ids, 1), 0) = 0 then raise exception 'Elige al menos un registro de horas extra'; end if;
  if p_pagar and p_periodo is not null then
    select * into per from pl_periodos where id = p_periodo;
    if per.id is null or per.tipo <> 'salario' then raise exception 'Elige una planilla de salario'; end if;
    if per.estado <> 'abierta' then raise exception 'Esa planilla ya está cerrada'; end if;
  end if;

  for h in select * from pl_horas_extra where id = any(p_ids) order by empleado_id, fecha for update loop
    if not pl_es_admin() and h.empleado_id = pl_mi_empleado() then raise exception 'Tus propias horas extra las paga administración'; end if;
    if h.tipo <> 'extra' or h.estado <> 'aprobada' then raise exception 'Solo se pueden pagar horas extra aprobadas'; end if;
    if p_pagar then
      if h.destino is distinct from 'compensar' then raise exception 'Las horas del % ya están en pago', to_char(h.fecha, 'DD/MM'); end if;
      if not h.empleado_id = any(emps) then
        select * into e from pl_empleados where id = h.empleado_id;
        if not e.recibe_salario then raise exception '% no está en la planilla de salario; no se le pueden pagar horas extra', e.nombre; end if;
      end if;
      update pl_horas_extra set destino = 'pagar', periodo_id = coalesce(p_periodo, pl__periodo_para_fecha(h.fecha)),
             respuesta = concat_ws(' · ', nullif(trim(respuesta), ''), 'Pasada del banco a pago el ' || v_hoy)
       where id = h.id;
    else
      if h.destino is distinct from 'pagar' then raise exception 'Las horas del % no están en pago', to_char(h.fecha, 'DD/MM'); end if;
      if h.periodo_id is not null and exists (select 1 from pl_periodos where id = h.periodo_id and estado <> 'abierta') then
        raise exception 'Las horas del % ya se pagaron en una planilla cerrada', to_char(h.fecha, 'DD/MM');
      end if;
      update pl_horas_extra set destino = 'compensar', periodo_id = null,
             respuesta = concat_ws(' · ', nullif(trim(respuesta), ''), 'Regresada al banco de horas el ' || v_hoy)
       where id = h.id;
    end if;
    n := n + 1; t := t + h.horas;
    if not h.empleado_id = any(emps) then emps := emps || h.empleado_id; end if;
  end loop;
  if n = 0 then raise exception 'No se encontraron esas horas extra'; end if;

  -- pagar no puede dejar el banco en negativo (horas que ya se usaron o se pidieron como descanso)
  if p_pagar then
    foreach v_emp in array emps loop
      b := pl_banco_horas(v_emp);
      if (b->>'disponible')::numeric < 0 then
        select * into e from pl_empleados where id = v_emp;
        raise exception 'No alcanza el banco de horas de %: le quedarían % h. Ya usó o pidió descanso con parte de esas horas.',
          e.nombre, trim_scale(round((b->>'disponible')::numeric, 2));
      end if;
    end loop;
  end if;
  return jsonb_build_object('registros', n, 'horas', t);
end $function$;

-- para cambiar el dueño, pl_definer necesita create en public solo durante esta transacción
grant create on schema public to pl_definer;
alter function public.pl_aprobar_extra_marcaje(jsonb, text, boolean) owner to pl_definer;
alter function public.pl_horas_extra_pago(uuid[], boolean, uuid) owner to pl_definer;
revoke create on schema public from pl_definer;
revoke execute on function public.pl_aprobar_extra_marcaje(jsonb, text, boolean) from public, anon;
revoke execute on function public.pl_horas_extra_pago(uuid[], boolean, uuid) from public, anon;
grant execute on function public.pl_aprobar_extra_marcaje(jsonb, text, boolean) to authenticated;
grant execute on function public.pl_horas_extra_pago(uuid[], boolean, uuid) to authenticated;
