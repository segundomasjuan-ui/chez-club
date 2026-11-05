-- =====================================================================
--  CHEZ CLUB · Fix 15 · Puerta: SOLO noches abiertas, sin importar el día
--  get_noches_puerta devuelve las noches abierto=true cercanas a hoy
--  (ventana v_op-2 .. v_op+5), sin el bloque fijo jueves-sábado anterior.
-- =====================================================================
create or replace function public.get_noches_puerta(p_pin text)
returns json language plpgsql security definer set search_path to 'public' as $function$
declare v_now timestamp; v_op date; v_noches json; v_role text;
begin
  if coalesce(p_pin,'') = coalesce(public.cfg('pin_admin'),'__na__') then v_role:='admin';
  elsif coalesce(p_pin,'') = coalesce(public.cfg('pin_puerta'),'__np__') then v_role:='puerta';
  else return json_build_object('ok',false,'mensaje','PIN incorrecto.'); end if;

  v_now := now() at time zone 'America/Argentina/Buenos_Aires';
  v_op  := case when v_now::time < time '08:00' then v_now::date - 1 else v_now::date end;

  select coalesce(json_agg(json_build_object(
           'fecha',to_char(fecha,'YYYY-MM-DD'),'nombre',nombre,'abierto',true) order by fecha),'[]'::json)
    into v_noches from public.noches
    where coalesce(abierto,false)=true and fecha between (v_op - 2) and (v_op + 5);

  return json_build_object('ok',true,'role',v_role,'noches',v_noches);
end $function$;
grant execute on function public.get_noches_puerta(text) to anon;
notify pgrst, 'reload schema';
