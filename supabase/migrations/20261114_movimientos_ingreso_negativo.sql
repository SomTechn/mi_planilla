-- v69 (14-nov-2026). Aplicada como `pl_movimientos_ingreso_negativo`.
-- Los ingresos de la planilla pueden ser negativos (ajuste que resta, por ejemplo un ajuste salarial); las deducciones siguen en cero o más.
alter table public.pl_movimientos drop constraint pl_movimientos_monto_check;
alter table public.pl_movimientos add constraint pl_movimientos_monto_check check (tipo = 'ingreso' or monto >= 0);
