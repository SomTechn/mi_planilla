-- Vacaciones y permisos se pueden solicitar (o editar) con fechas de hasta 7 días atrás.
-- Antes: vacaciones solo desde hoy; permisos sin ningún límite hacia atrás.
-- Se edita el texto de cada función conservando su dueño y atributos; editar una solicitud usa estas mismas funciones.
do $$
declare d text;
begin
  d := pg_get_functiondef('pl_solicitar_vacaciones(date, date, text)'::regprocedure);
  if position($a$if p_desde < pl__hoy() then raise exception 'Las vacaciones deben ser a partir de hoy'; end if;$a$ in d) = 0 then
    raise exception 'pl_solicitar_vacaciones cambió; revisar a mano';
  end if;
  execute replace(d, $a$if p_desde < pl__hoy() then raise exception 'Las vacaciones deben ser a partir de hoy'; end if;$a$,
    $b$if p_desde < pl__hoy() - 7 then raise exception 'Solo puedes pedir vacaciones con fechas de hasta 7 días atrás'; end if;$b$);

  d := pg_get_functiondef('pl_solicitar_permiso(boolean, date, date, numeric, text)'::regprocedure);
  if position($a$if p_hasta < p_desde then raise exception 'La fecha final es antes de la inicial'; end if;$a$ in d) = 0 then
    raise exception 'pl_solicitar_permiso cambió; revisar a mano';
  end if;
  execute replace(d, $a$if p_hasta < p_desde then raise exception 'La fecha final es antes de la inicial'; end if;$a$,
    $b$if p_hasta < p_desde then raise exception 'La fecha final es antes de la inicial'; end if;
  if p_desde < pl__hoy() - 7 then raise exception 'Solo puedes pedir permisos con fechas de hasta 7 días atrás'; end if;$b$);
end $$;
