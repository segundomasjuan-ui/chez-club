-- ============================================================
-- 1) REPRODUCIR lo que hace la web (ejecutar como anon).
--    Pegame qué devuelve: el JSON, o el error (ej. "permission denied").
-- ============================================================
set role anon;
select get_noches_abiertas();
reset role;

-- ============================================================
-- 2) ARREGLO: darle a anon permiso de ejecutar la función.
--    Inofensivo si ya lo tenía.
-- ============================================================
grant execute on function public.get_noches_abiertas() to anon;

-- 3) Refrescar el cache de la API para que tome el cambio al toque.
notify pgrst, 'reload schema';
