-- 1) Definición COMPLETA de las funciones de Puerta (pegame el texto entero).
--    Si alguna no existe, no aparece fila (eso también me sirve saberlo).
select p.oid::regprocedure as firma, pg_get_functiondef(p.oid) as definicion
from pg_proc p
where p.pronamespace = 'public'::regnamespace
  and p.proname in ('crear_previa','editar_previa')
order by p.proname;

-- 2) ¿Quedaron creadas las funciones del BA (ba_fix11)? Deben aparecer las 4.
select p.oid::regprocedure as firma
from pg_proc p
where p.pronamespace = 'public'::regnamespace
  and p.proname in ('ba_add_previa','ba_editar_previa','ba_previa_add_invitados','ba_previa_quitar_invitado')
order by p.proname;
