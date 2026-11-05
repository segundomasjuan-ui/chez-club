-- ============================================================
-- DIAGNÓSTICO 2 (solo lectura). Pegar las TRES salidas.
-- ============================================================

-- A) Qué devuelve HOY get_noches_abiertas (el JSON completo con las noches)
select get_noches_abiertas();

-- B) El código de get_noches_abiertas (para ver si usa _noche_activa y cómo)
select pg_get_functiondef('get_noches_abiertas()'::regprocedure);

-- C) El código de _noche_activa (la que creó la ruleta)
select pg_get_functiondef('_noche_activa()'::regprocedure);
