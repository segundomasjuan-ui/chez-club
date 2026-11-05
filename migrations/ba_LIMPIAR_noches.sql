-- =====================================================================
--  CHEZ CLUB · LIMPIAR get_noches_abiertas
--  CORRÉ ESTO SOLO, EN UNA PESTAÑA VACÍA DEL EDITOR SQL.
--  (Borrá cualquier otra cosa que haya en el editor antes de pegar esto.)
-- =====================================================================

-- 1) Borra TODAS las versiones de get_noches_abiertas (cualquier firma).
do $$
declare r record;
begin
  for r in
    select oid::regprocedure as sig
    from pg_proc
    where proname = 'get_noches_abiertas'
      and pronamespace = 'public'::regnamespace
  loop
    execute 'drop function ' || r.sig::text || ' cascade';
  end loop;
end $$;

-- 2) Crea UNA sola versión.
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

-- 3) Verificación SIN llamar a la función (no puede dar "not unique").
--    Tiene que decir 1.
select count(*) as versiones_que_quedaron
from pg_proc
where proname = 'get_noches_abiertas'
  and pronamespace = 'public'::regnamespace;
