-- =====================================================================
--  CHEZ CLUB · Casilla "Brand Ambassadors" en la Puerta
--  RPC que devuelve los BA vigentes con su lista de invitados por noche.
--  Idempotente.
-- =====================================================================
create or replace function public.get_ba_puerta(p_pin text, p_fecha date)
returns json language plpgsql security definer set search_path to 'public' as $function$
declare v json;
begin
  if not public._is_staff(p_pin) then return json_build_object('ok',false,'mensaje','PIN incorrecto.'); end if;
  select coalesce(json_agg(json_build_object(
      'id', e.id, 'nombre', e.nombre, 'apellido', coalesce(e.apellido,''),
      'dni', coalesce(e.dni,''), 'ig', coalesce(e.ig,''),
      'llego', (en.llegada is not null), 'hora', coalesce(en.llegada,''),
      'invitados', (
        select coalesce(json_agg(json_build_object(
                 'id', l.id, 'nombre', l.nombre, 'dni', coalesce(l.dni,''),
                 'llego', (l.llegada is not null), 'hora', coalesce(l.llegada,''))
               order by lower(l.nombre)),'[]'::json)
        from public.listas_noche l where l.fecha = p_fecha and l.embajador_id = e.id),
      'total', (select count(*) from public.listas_noche l where l.fecha=p_fecha and l.embajador_id=e.id),
      'ingresados', (select count(*) from public.listas_noche l where l.fecha=p_fecha and l.embajador_id=e.id and l.llegada is not null)
    ) order by lower(e.nombre)),'[]'::json) into v
  from public.embajadores e
  left join public.embajador_noche en on en.embajador_id=e.id and en.fecha=p_fecha
  where coalesce(e.activo,true);
  return json_build_object('ok',true,'lista',v);
end $function$;

grant execute on function public.get_ba_puerta(text,date) to anon;

notify pgrst, 'reload schema';
