-- Volcá estas dos funciones y pegame el texto completo.
select pg_get_functiondef('public.crear_previa'::regproc)  as crear_previa;
select pg_get_functiondef('public.editar_previa'::regproc) as editar_previa;

-- Y las columnas actuales de la tabla previas (para el modelo entradas/botellas):
select column_name, data_type
from information_schema.columns
where table_schema='public' and table_name='previas'
order by ordinal_position;
