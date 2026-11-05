-- ============================================================
-- Ver el código de las funciones de previa + listado de noches.
-- Solo lectura. Pegar la salida completa (las tres filas 'codigo').
-- ============================================================
select proname, pg_get_functiondef(oid) as codigo
from pg_proc
where proname in ('get_noches_puerta','crear_previa','editar_previa')
order by proname;
