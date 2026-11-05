-- =====================================================================
--  CHEZ CLUB · Fix 4 · House Members noches
--  - get_noches_abiertas pasa a STABLE y acepta _cb (cache-buster) para
--    poder llamarse por GET con URL única (mata caché del WebView de IG).
--  - Filtro fecha >= hoy (gracia hasta 08:00). Nunca noches pasadas.
--  - Dropea versiones viejas para que no haya ambigüedad de overload.
--  - Al final: DIAGNÓSTICO que muestra EXACTO lo que ve la página.
--  Idempotente.
-- =====================================================================

drop function if exists public.get_noches_abiertas();
drop function if exists public.get_noches_abiertas(text);

create or replace function public.get_noches_abiertas(_cb text default null)
returns json language plpgsql stable security definer set search_path to 'public' as $function$
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

grant execute on function public.get_noches_abiertas(text) to anon;

notify pgrst, 'reload schema';

-- =====================================================================
--  DIAGNÓSTICO (mirá los resultados abajo, no hace falta mandármelos:
--  si "lo_que_devuelve_el_servidor" NO tiene noches del finde pasado,
--  el servidor está limpio y el problema era 100% caché de Instagram)
-- =====================================================================

-- 1) Esto es EXACTAMENTE lo que recibe la página:
select public.get_noches_abiertas() as lo_que_devuelve_el_servidor;

-- 2) Estado crudo de la tabla (¿hay noches viejas con abierto=true?):
select fecha, nombre, abierto,
       (fecha >= (now() at time zone 'America/Argentina/Buenos_Aires')::date) as es_hoy_o_futura
from public.noches
order by fecha desc
limit 12;
