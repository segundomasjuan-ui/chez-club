-- =====================================================================
--  CHEZ CLUB · Fix 6 · get_noches_abiertas — ESTA es la causa raíz
--  "function get_noches_abiertas() is not unique" = hay varias versiones
--  apiladas de migraciones anteriores. La página llamaba, Postgres no
--  sabía cuál usar, tiraba error, y la página mostraba los botones de
--  ejemplo. Acá borramos TODAS las versiones (cualquier firma) y dejamos
--  una sola. Idempotente.
-- =====================================================================

-- 1) Borrar TODAS las funciones llamadas get_noches_abiertas en public,
--    sin importar sus parámetros.
do $$
declare r record;
begin
  for r in
    select oid::regprocedure as sig
    from pg_proc
    where proname = 'get_noches_abiertas'
      and pronamespace = 'public'::regnamespace
  loop
    execute 'drop function ' || r.sig::text;
  end loop;
end $$;

-- 2) Crear UNA sola versión, sin parámetros.
create function public.get_noches_abiertas()
returns json language plpgsql security definer set search_path to 'public' as $function$
declare v_hoy date; v_corte date; v_noches json;
begin
  v_hoy := (now() at time zone 'America/Argentina/Buenos_Aires')::date;
  v_corte := case when (now() at time zone 'America/Argentina/Buenos_Aires')::time < time '08:00'
                  then v_hoy - 1 else v_hoy end;
  select coalesce(json_agg(json_build_object(
            'fecha', to_char(fecha,'YYYY-MM-DD'),
            'nombre', nombre
         ) order by fecha), '[]'::json)
    into v_noches
  from public.noches
  where abierto = true and fecha >= v_corte;
  return json_build_object(
    'max_invitados', coalesce(public.cfg('max_invitados')::int, 2),
    'noches', v_noches
  );
end $function$;

grant execute on function public.get_noches_abiertas() to anon;

notify pgrst, 'reload schema';

-- 3) Verificación: cuántas versiones quedaron (debe decir 1) y qué devuelve.
select count(*) as versiones_de_la_funcion
from pg_proc where proname='get_noches_abiertas' and pronamespace='public'::regnamespace;

select public.get_noches_abiertas() as lo_que_devuelve_el_servidor;
