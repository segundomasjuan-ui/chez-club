-- =====================================================================
--  CHEZ CLUB · Fix 17 · Contar personas de previas por invitados reales
--  crear_previa (Puerta) no guarda pax; el conteo correcto = filas en
--  previa_invitados (titular + lista). Afecta get_calendario y get_resumen_fecha.
-- =====================================================================
create or replace function public.get_calendario(p_pin text, p_anio integer, p_mes integer)
returns json language plpgsql security definer set search_path to 'public' as $function$
declare v json;
begin
  if not public._is_staff(p_pin) then return json_build_object('ok',false,'mensaje','PIN incorrecto.'); end if;
  select coalesce(json_agg(json_build_object(
    'fecha',fecha,'nombre',nombre,'cupo',coalesce(cupo,20),'abierto',coalesce(abierto,false),
    'hora_inicio',coalesce(hora_inicio,''),'hora_fin',coalesce(hora_fin,''),'notas',coalesce(notas,''),
    'anotados',(select count(*) from public.rsvp r where r.fecha=n.fecha and upper(r.estado)='CONFIRMADO'),
    'previas',(select count(*) from public.previas pr where pr.fecha=n.fecha),
    'previas_pax',(select count(*) from public.previa_invitados i join public.previas pr on pr.id=i.previa_id where pr.fecha=n.fecha)
  ) order by fecha),'[]'::json) into v
  from public.noches n
  where fecha >= make_date(p_anio,p_mes,1) and fecha < (make_date(p_anio,p_mes,1)+interval '1 month');
  return json_build_object('ok',true,'noches',v);
end $function$;

create or replace function public.get_resumen_fecha(p_pin text, p_fecha date)
returns json language plpgsql security definer set search_path to 'public' as $function$
declare v_prev json; p_cant int; p_pax int; m_vend int; hm int; lst int;
begin
  if not public._is_staff(p_pin) then return json_build_object('ok',false,'mensaje','PIN incorrecto.'); end if;
  select coalesce(json_agg(json_build_object(
           'id',pr.id,'titular',pr.titular,
           'pax',(select count(*) from public.previa_invitados i where i.previa_id=pr.id),
           'tipo',coalesce(pr.tipo,'comun')) order by pr.creado),'[]'::json)
    into v_prev from public.previas pr where pr.fecha=p_fecha;
  select count(*) into p_cant from public.previas where fecha=p_fecha;
  select count(*) into p_pax from public.previa_invitados i join public.previas pr on pr.id=i.previa_id where pr.fecha=p_fecha;
  select count(*) into m_vend from public.mesas_noche where fecha=p_fecha and coalesce(titular,'')<>'';
  select coalesce(sum(coalesce(cantidad,1)),0) into hm from public.rsvp where fecha=p_fecha and upper(estado)='CONFIRMADO';
  select count(*) into lst from public.listas_noche where fecha=p_fecha;
  return json_build_object('ok',true,
    'previas', json_build_object('cantidad',p_cant,'pax',p_pax,'lista',v_prev),
    'mesas_vendidas', m_vend,
    'invitaciones', json_build_object('total', hm+lst, 'hm', hm, 'listas', lst));
end $function$;

notify pgrst, 'reload schema';
