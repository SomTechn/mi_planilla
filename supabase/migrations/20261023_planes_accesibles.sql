-- Planes más accesibles + plan personalizado (más de 30 colaboradores, precio a cotizar).
-- El plan personalizado no tiene límite propio: al asignarlo, el superadmin pone el límite y el precio acordado en la empresa.
insert into pl_planes (codigo, nombre, max_empleados, precio_mensual, descripcion, orden, publico) values
  ('emprendedor', 'Emprendedor', 7, 650, 'Hasta 7 colaboradores', 1, true),
  ('pyme', 'Pyme', 15, 1100, 'Hasta 15 colaboradores', 2, true),
  ('empresa', 'Empresa', 30, 1750, 'Hasta 30 colaboradores', 3, true),
  ('personalizado', 'Personalizado', null, 0, 'Más de 30 colaboradores · precio a tu medida', 4, true)
on conflict (codigo) do update set nombre = excluded.nombre, max_empleados = excluded.max_empleados, precio_mensual = excluded.precio_mensual,
  descripcion = excluded.descripcion, orden = excluded.orden, publico = excluded.publico;
