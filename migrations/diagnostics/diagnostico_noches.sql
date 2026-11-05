-- ============================================================
-- DIAGNÓSTICO (solo lectura, no cambia nada)
-- Correr en el SQL editor de Supabase y pegarme AMBOS resultados.
-- ============================================================

-- 1) ¿get_noches_abiertas sigue funcionando? (si da error, pegá el texto completo)
select get_noches_abiertas();

-- 2) ¿Qué funciones hay y qué devuelven? (busca colisiones con la ruleta)
select p.proname                                   as funcion,
       pg_get_function_arguments(p.oid)            as argumentos,
       pg_get_function_result(p.oid)               as devuelve
from   pg_proc p
join   pg_namespace n on n.oid = p.pronamespace
where  n.nspname = 'public'
  and  p.proname in ('_noche_activa','get_noches_abiertas','registrar_rsvp','abrir_semana_auto')
order by p.proname;
