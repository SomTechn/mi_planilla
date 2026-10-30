-- Vacaciones, permisos y descanso compensatorio (horas extra) se pueden solicitar o editar
-- con fechas de hasta 3 días atrás.
-- Se edita el texto de cada función conservando su dueño y atributos; editar una solicitud usa estas mismas funciones.
-- Si una regla no se encuentra, se avisa con NOTICE y se continúa; la consulta final muestra cómo quedó cada función.
do $$
declare
  d text; n text;
  regla text := $r$if\s+p_(desde|fecha)\s*<\s*(pl__hoy\(\)|current_date)(\s*-\s*\d+)?\s+then\s+raise\s+exception\s+'[^']*';\s*end\s+if;$r$;
begin
  -- Vacaciones
  d := pg_get_functiondef('pl_solicitar_vacaciones(date, date, text)'::regprocedure);
  n := regexp_replace(d, regla,
    $b$if p_desde < pl__hoy() - 3 then raise exception 'Solo puedes pedir vacaciones con fechas de hasta 3 días atrás'; end if;$b$);
  if n = d then raise notice 'pl_solicitar_vacaciones: no se encontró la regla de fecha'; else execute n; end if;

  -- Permisos
  d := pg_get_functiondef('pl_solicitar_permiso(boolean, date, date, numeric, text)'::regprocedure);
  n := regexp_replace(d, regla,
    $b$if p_desde < pl__hoy() - 3 then raise exception 'Solo puedes pedir permisos con fechas de hasta 3 días atrás'; end if;$b$);
  if n = d then
    -- todavía no tenía límite hacia atrás: se agrega después de validar el rango
    n := replace(d, $a$if p_hasta < p_desde then raise exception 'La fecha final es antes de la inicial'; end if;$a$,
      $b$if p_hasta < p_desde then raise exception 'La fecha final es antes de la inicial'; end if;
  if p_desde < pl__hoy() - 3 then raise exception 'Solo puedes pedir permisos con fechas de hasta 3 días atrás'; end if;$b$);
  end if;
  if n = d then raise notice 'pl_solicitar_permiso: no se encontró dónde poner la regla'; else execute n; end if;

  -- Descanso compensatorio (banco de horas extra)
  for d in select pg_get_functiondef(p.oid) from pg_proc p join pg_namespace s on s.oid = p.pronamespace
           where s.nspname = 'public' and p.proname = 'pl_solicitar_descanso' loop
    n := regexp_replace(d, regla,
      $b$if p_fecha < pl__hoy() - 3 then raise exception 'Solo puedes pedir descanso con fechas de hasta 3 días atrás'; end if;$b$);
    if n = d then raise notice 'pl_solicitar_descanso: no tenía regla de fecha en la base (la app la controla)'; else execute n; end if;
  end loop;
end $$;

-- Verificación: debe mostrar "- 3" en cada función
select p.proname,
       substring(pg_get_functiondef(p.oid) from $r$if\s+p_(?:desde|fecha)\s*<\s*(?:pl__hoy\(\)|current_date)[^;]*;$r$) as regla
from pg_proc p join pg_namespace s on s.oid = p.pronamespace
where s.nspname = 'public' and p.proname in ('pl_solicitar_vacaciones', 'pl_solicitar_permiso', 'pl_solicitar_descanso');
