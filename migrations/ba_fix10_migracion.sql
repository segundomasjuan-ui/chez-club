-- =====================================================================
--  CHEZ CLUB · Fix 10 · Tanda 1
--  Puerta · buscador general: el BA se devolvía solo con el nombre.
--  Ahora el snapshot usa "Nombre Apellido" para que se pueda buscar
--  (y mostrar) por apellido también.
--  Firma idéntica → create or replace.
-- =====================================================================
create or replace function public.get_noche_completa(p_pin text, p_fecha date)
returns json language plpgsql security definer set search_path to 'public' as $function$
declare v_cut text; v_benef text; v json;
begin
  if not public._is_staff(p_pin) then return json_build_object('ok',false,'mensaje','PIN incorrecto.'); end if;
  v_cut := public.cfg('cutoff_hm');
  v_benef := coalesce(public.cfg('beneficio_fijo'),'10 entradas · 5 consumiciones');
  with m as (
    select 'hm' as kind, r.id::bigint as id, r.nombre, coalesce(r.dni,'') as dni,
           ('House Member'|| case when coalesce(r.cantidad,1)>1 then ' · '||r.cantidad||' personas' else '' end) as detalle,
           (r.ingreso is not null and r.ingreso<>'') as llego, coalesce(r.ingreso,'') as hora,
           coalesce(v_cut,'') as limite, 1 as ord
    from public.rsvp r where r.fecha=p_fecha and upper(r.estado)='CONFIRMADO'
    union all
    select 'lista', l.id, l.nombre, coalesce(l.dni,''),
           (case l.tipo when 'fija' then 'Invitado' when 'influencer' then 'Influencer' else l.tipo end),
           (l.llegada is not null), coalesce(l.llegada,''), coalesce(l.limite,''), 2
    from public.listas_noche l where l.fecha=p_fecha and l.tipo in ('fija','influencer')
    union all
    select 'embajador', e.id,
           (e.nombre || case when coalesce(e.apellido,'')<>'' then ' '||e.apellido else '' end),
           coalesce(e.dni,''),
           (case when coalesce(e.es_ba,false) then 'Brand Ambassador · ' else 'Influencer fijo · ' end)||v_benef,
           (en.llegada is not null), coalesce(en.llegada,''), '', 2
    from public.embajadores e
    left join public.embajador_noche en on en.embajador_id=e.id and en.fecha=p_fecha
    where coalesce(e.activo,true)
    union all
    select 'previa', i.id, i.nombre, coalesce(i.dni,''),
           ('Previa · '||p.titular), (i.llegada is not null), coalesce(i.llegada,''), '', 3
    from public.previa_invitados i join public.previas p on p.id=i.previa_id where p.fecha=p_fecha
    union all
    select 'mesa', n.mesa_id, n.titular, coalesce(n.contacto,''),
           ('Mesa '||c.nombre|| case when coalesce(n.personas,0)>0 then ' · '||n.personas||' personas' else '' end),
           (n.llegada is not null), coalesce(n.llegada,''), '', 4
    from public.mesas_noche n join public.mesas_config c on c.id=n.mesa_id
    where n.fecha=p_fecha and coalesce(n.titular,'')<>''
  )
  select coalesce(json_agg(json_build_object(
    'kind',kind,'id',id,'nombre',nombre,'dni',dni,'detalle',detalle,
    'llego',llego,'hora',hora,'limite',limite) order by ord, lower(nombre)),'[]'::json) into v from m;
  return json_build_object('ok',true,'personas',v);
end $function$;

notify pgrst, 'reload schema';
