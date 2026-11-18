-- v74 (18-nov-2026). Aplicada como `pl_horas_en_formato_hora`.
-- Los textos que arma el servidor (comprobante, avisos push, notas de asistencia y mensajes de error) muestran
-- las horas en formato hora: 3.75 → '3:45 h'. Se cambia solo el texto de cada función (create or replace, misma firma).
create or replace function public.pl__hhmm(p numeric)
 returns text language sql immutable set search_path to 'public'
as $$
  select case when p is null then null else
    case when p < 0 and round(abs(p) * 60) > 0 then '−' else '' end
    || floor(round(abs(p) * 60) / 60)::int || ':' || lpad((round(abs(p) * 60)::int % 60)::text, 2, '0') || ' h' end
$$;

do $mig$
declare def text; nuevo text; par text[];
  cambios constant jsonb := jsonb_build_object(
    'private.pl_push_tg()', jsonb_build_array(
      jsonb_build_array($a$trim_scale((j->>'horas')::numeric) || ' h el '$a$, $a$pl__hhmm((j->>'horas')::numeric) || ' el '$a$),
      jsonb_build_array($a$trim_scale(abs((j->>'horas')::numeric)) || ' h · '$a$, $a$pl__hhmm(abs((j->>'horas')::numeric)) || ' · '$a$)),
    'public.pl__aplicar_descanso(pl_horas_extra)', jsonb_build_array(
      jsonb_build_array($a$h.horas || ' h'$a$, $a$pl__hhmm(h.horas)$a$)),
    'public.pl__aplicar_permiso(pl_permisos)', jsonb_build_array(
      jsonb_build_array($a$p.horas || ' h'$a$, $a$pl__hhmm(p.horas)$a$)),
    'public.pl__calc(uuid,uuid)', jsonb_build_array(
      jsonb_build_array($a$v_min||' min'$a$, $a$pl__hhmm(v_min / 60.0)$a$),
      jsonb_build_array($a$': ' || horas || ' h'$a$, $a$': ' || pl__hhmm(horas)$a$)),
    'public.pl_ajustar_horas(uuid,numeric,text)', jsonb_build_array(
      jsonb_build_array($a$'No se pueden restar % horas: el empleado tiene % horas de saldo', abs(p_horas), v_saldo$a$,
                        $a$'No se pueden restar %: el empleado tiene % de saldo', pl__hhmm(abs(p_horas)), pl__hhmm(v_saldo)$a$)),
    'public.pl_aprobar_extra_marcaje(jsonb,text,boolean)', jsonb_build_array(
      jsonb_build_array($a$trim_scale(h.horas) || ' h extra$a$, $a$pl__hhmm(h.horas) || ' extra$a$)),
    'public.pl_horas_extra_pago(uuid[],boolean,uuid)', jsonb_build_array(
      jsonb_build_array($a$le quedarían % h.$a$, $a$le quedarían %.$a$),
      jsonb_build_array($a$trim_scale(round((b->>'disponible')::numeric, 2))$a$, $a$pl__hhmm((b->>'disponible')::numeric)$a$)),
    'public.pl_resolver_horas(uuid,boolean,text,numeric,text)', jsonb_build_array(
      jsonb_build_array($a$'El empleado solo tiene % horas en su banco', b->>'saldo'$a$, $a$'El empleado solo tiene % en su banco', pl__hhmm((b->>'saldo')::numeric)$a$)),
    'public.pl_solicitar_descanso(date,numeric,text)', jsonb_build_array(
      jsonb_build_array($a$'Solo tienes % horas disponibles en tu banco de horas', b->>'disponible'$a$, $a$'Solo tienes % disponibles en tu banco de horas', pl__hhmm((b->>'disponible')::numeric)$a$)));
  k text; c jsonb;
begin
  for k, c in select * from jsonb_each(cambios) loop
    def := pg_get_functiondef(k::regprocedure); nuevo := def;
    for par in select array[x->>0, x->>1] from jsonb_array_elements(c) x loop
      if position(par[1] in nuevo) = 0 then raise exception 'No se encontró en %: %', k, par[1]; end if;
      nuevo := replace(nuevo, par[1], par[2]);
    end loop;
    execute nuevo;
  end loop;
end $mig$;
