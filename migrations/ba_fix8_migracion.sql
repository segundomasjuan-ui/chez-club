-- =====================================================================
--  CHEZ CLUB · Fix 8 · get_ba_puerta con mesas/previas + comprobantes
--  Para que desde la caja de Brand Ambassadors en Puerta se vean las
--  mesas y previas que vendió cada BA, con su comprobante.
--  Firma idéntica → create or replace.
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
      'ingresados', (select count(*) from public.listas_noche l where l.fecha=p_fecha and l.embajador_id=e.id and l.llegada is not null),
      'mesas', (
        select coalesce(json_agg(json_build_object(
                 'mesa', c.nombre, 'titular', coalesce(n.titular,''), 'monto', coalesce(n.monto,0),
                 'comp_url', coalesce(n.comprobante_url,''))
               order by c.orden),'[]'::json)
        from public.mesas_noche n join public.mesas_config c on c.id=n.mesa_id
        where n.fecha=p_fecha and n.embajador_id=e.id and coalesce(n.titular,'')<>''),
      'previas', (
        select coalesce(json_agg(json_build_object(
                 'titular', p.titular, 'pax', coalesce(p.pax,0), 'monto', coalesce(p.monto,0),
                 'arreglo', coalesce(p.descripcion,''), 'comp_url', coalesce(p.comprobante_url,''))
               order by p.creado),'[]'::json)
        from public.previas p where p.fecha=p_fecha and p.embajador_id=e.id)
    ) order by lower(e.nombre)),'[]'::json) into v
  from public.embajadores e
  left join public.embajador_noche en on en.embajador_id=e.id and en.fecha=p_fecha
  where coalesce(e.activo,true);
  return json_build_object('ok',true,'lista',v);
end $function$;

notify pgrst, 'reload schema';
