-- =====================================================================
--  CHEZ CLUB · Fix 5 · get_noches_abiertas DEFINITIVO
--  Deja UNA sola función, sin parámetros, para que la llamada POST
--  nunca sea ambigua (el problema no era caché: la página mostraba
--  botones de ejemplo cuando esta llamada fallaba). Vuelve al POST
--  simple y confiable. Filtra noches pasadas. Recarga el schema.
-- =====================================================================

-- Borrar CUALQUIER versión previa (con o sin parámetro) para que no
-- queden dos funciones con el mismo nombre (eso rompe la llamada).
drop function if exists public.get_noches_abiertas(text);
drop function if exists public.get_noches_abiertas();

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

-- Diagnóstico: esto es lo que va a recibir la página
select public.get_noches_abiertas() as lo_que_devuelve_el_servidor;
