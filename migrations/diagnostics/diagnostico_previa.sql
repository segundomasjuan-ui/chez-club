-- ============================================================
-- DIAGNÓSTICO guardado de previa (solo lectura). Pegar ambas salidas.
-- ============================================================

-- A) Código de editar_previa (para ver si se cae por un dato, ej. DNI vacío)
select pg_get_functiondef(oid) as codigo
from pg_proc where proname = 'editar_previa';

-- B) ¿anon puede ejecutar las funciones de previa?
--    (get_previas SÍ anda, así que sirve de comparación)
select proname,
       pg_get_function_identity_arguments(oid) as args,
       has_function_privilege('anon', oid, 'EXECUTE') as anon_puede
from pg_proc
where proname in ('editar_previa','crear_previa','get_previas','marcar_previa_invitado')
order by proname;
