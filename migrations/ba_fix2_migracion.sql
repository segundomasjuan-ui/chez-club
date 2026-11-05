-- =====================================================================
--  CHEZ CLUB · Correcciones Mesas + Previa
--  - Precio de mesa numérico y editable (admin, desde la puerta)
--  - Consumos automáticos por horario (80/70/50 %, redondeo arriba $10.000)
--  - Comprobantes de mesa y previa visibles en Puerta y CRM
--  - Previa con "Arreglo" (texto) y comprobante de pago
--  Idempotente.
-- =====================================================================

-- 1) Precio numérico de mesa -------------------------------------------
alter table public.mesas_config add column if not exists precio_num numeric;
update public.mesas_config
  set precio_num = nullif(regexp_replace(coalesce(precio,''),'[^0-9]','','g'),'')::numeric
  where precio_num is null;

-- 2) Previa: arreglo (usa 'descripcion') + comprobante -----------------
alter table public.previas add column if not exists comprobante_url text;
alter table public.previas add column if not exists comprobante_nombre text;

-- 3) Editar precio de una mesa (solo admin) ----------------------------
create or replace function public.set_mesa_precio(p_pin text, p_mesa_id bigint, p_precio_num numeric)
returns json language plpgsql security definer set search_path to 'public' as $function$
declare v_txt text;
begin
  if not public._is_admin(p_pin) then return json_build_object('ok',false,'mensaje','Necesitás el PIN de admin.'); end if;
  if coalesce(p_precio_num,0) <= 0 then return json_build_object('ok',false,'mensaje','Precio inválido.'); end if;
  v_txt := '$' || replace(to_char(round(p_precio_num), 'FM999,999,999'), ',', '.');
  update public.mesas_config set precio_num = round(p_precio_num), precio = v_txt where id = p_mesa_id;
  return json_build_object('ok',true,'precio',v_txt);
end $function$;
grant execute on function public.set_mesa_precio(text,bigint,numeric) to anon;

-- 4) get_mesas_noche: precio desde precio_num + consumos auto + comprobante
create or replace function public.get_mesas_noche(p_pin text, p_fecha date)
returns json language plpgsql security definer set search_path to 'public' as $function$
declare v_lista json;
begin
  if not public._is_staff(p_pin) then return json_build_object('ok',false,'mensaje','PIN incorrecto.'); end if;
  select coalesce(json_agg(json_build_object(
    'mesa_id',c.id,'nombre',c.nombre,'categoria',coalesce(c.categoria,''),
    'precio', coalesce(nullif(c.precio,''), case when c.precio_num is not null then '$'||replace(to_char(c.precio_num,'FM999,999,999'),',','.') else '' end),
    'precio_num', c.precio_num,
    'consumos', case when c.precio_num is not null then json_build_array(
        json_build_object('horario','00:30–01:30','monto', ceil(c.precio_num*0.8/10000)*10000),
        json_build_object('horario','01:30–02:30','monto', ceil(c.precio_num*0.7/10000)*10000),
        json_build_object('horario','desde 02:30','monto', ceil(c.precio_num*0.5/10000)*10000)
      ) else '[]'::json end,
    'disposicion',coalesce(c.disposicion,''),
    'titular',coalesce(n.titular,''),'contacto',coalesce(n.contacto,''),'personas',coalesce(n.personas,0),
    'estado',coalesce(nullif(n.estado,''),'Libre'),'nota',coalesce(n.nota,''),
    'comprobante_url',coalesce(n.comprobante_url,''),'comprobante_nombre',coalesce(n.comprobante_nombre,''),
    'llego',(n.llegada is not null),'hora',coalesce(n.llegada,'')
  ) order by c.orden) ,'[]'::json) into v_lista
  from public.mesas_config c
  left join public.mesas_noche n on n.mesa_id=c.id and n.fecha=p_fecha
  where coalesce(c.activo,true);
  return json_build_object('ok',true,'lista',v_lista);
end $function$;

-- 5) get_previas: devuelve arreglo (descripcion) + comprobante ---------
create or replace function public.get_previas(p_pin text, p_fecha date)
returns json language plpgsql security definer set search_path to 'public' as $function$
declare v json;
begin
  if not public._is_staff(p_pin) then return json_build_object('ok',false,'mensaje','PIN incorrecto.'); end if;
  select coalesce(json_agg(json_build_object(
    'id',p.id,'titular',p.titular,'titular_dni',coalesce(p.titular_dni,''),
    'monto',coalesce(p.monto,0),'descripcion',coalesce(p.descripcion,''),'arreglo',coalesce(p.descripcion,''),
    'comprobante_url',coalesce(p.comprobante_url,''),'comprobante_nombre',coalesce(p.comprobante_nombre,''),
    'invitados',(
      select coalesce(json_agg(json_build_object(
        'id',i.id,'nombre',i.nombre,'dni',coalesce(i.dni,''),
        'llego',(i.llegada is not null),'hora',coalesce(i.llegada,'')) order by lower(i.nombre)),'[]'::json)
      from public.previa_invitados i where i.previa_id=p.id),
    'total',(select count(*) from public.previa_invitados i where i.previa_id=p.id),
    'ingresados',(select count(*) from public.previa_invitados i where i.previa_id=p.id and i.llegada is not null)
  ) order by p.creado),'[]'::json) into v
  from public.previas p where p.fecha=p_fecha;
  return json_build_object('ok',true,'previas',v);
end $function$;

-- 6) BA · previa con Arreglo (reemplaza la firma vieja) ----------------
drop function if exists public.ba_add_previa(text,date,text,text,numeric,integer);
create or replace function public.ba_add_previa(
  p_token text, p_fecha date, p_titular text, p_dni text, p_monto numeric, p_pax integer, p_arreglo text)
returns json language plpgsql security definer set search_path to 'public' as $function$
declare v_me bigint; v_id bigint; v_dni text;
begin
  v_me := public._ba(p_token);
  if v_me is null then return json_build_object('ok',false,'mensaje','Sesión vencida. Ingresá de nuevo.'); end if;
  if length(btrim(coalesce(p_titular,''))) < 2 then return json_build_object('ok',false,'mensaje','Falta el titular.'); end if;
  if coalesce(p_pax,0) < 1 then return json_build_object('ok',false,'mensaje','Indicá la cantidad de personas.'); end if;
  v_dni := nullif(regexp_replace(coalesce(p_dni,''),'[^0-9]','','g'),'');
  insert into public.previas(fecha, titular, titular_dni, monto, descripcion, embajador_id, pax)
  values (p_fecha, btrim(p_titular), v_dni, coalesce(p_monto,0),
          nullif(btrim(coalesce(p_arreglo,'')),''), v_me, p_pax)
  returning id into v_id;
  insert into public.previa_invitados(previa_id, nombre, dni, orden) values (v_id, btrim(p_titular), v_dni, 0);
  return json_build_object('ok',true,'id',v_id);
end $function$;
grant execute on function public.ba_add_previa(text,date,text,text,numeric,integer,text) to anon;

-- 7) BA · comprobante de previa ----------------------------------------
create or replace function public.ba_set_previa_comprobante(
  p_token text, p_previa_id bigint, p_url text, p_nombre text)
returns json language plpgsql security definer set search_path to 'public' as $function$
declare v_me bigint; v_ok bigint;
begin
  v_me := public._ba(p_token);
  if v_me is null then return json_build_object('ok',false,'mensaje','Sesión vencida. Ingresá de nuevo.'); end if;
  select id into v_ok from public.previas where id=p_previa_id and embajador_id=v_me;
  if v_ok is null then return json_build_object('ok',false,'mensaje','Esa previa no es tuya.'); end if;
  update public.previas set comprobante_url=nullif(btrim(coalesce(p_url,'')),''),
         comprobante_nombre=nullif(btrim(coalesce(p_nombre,'')),'') where id=p_previa_id;
  return json_build_object('ok',true);
end $function$;
grant execute on function public.ba_set_previa_comprobante(text,bigint,text,text) to anon;

-- 8) ba_noche: previa con arreglo + comprobante ------------------------
create or replace function public.ba_noche(p_token text, p_fecha date)
returns json language plpgsql security definer set search_path to 'public' as $function$
declare v_me bigint; v_mesas json; v_inv json; v_prev json; v_nombre text; v_abierto boolean;
begin
  v_me := public._ba(p_token);
  if v_me is null then return json_build_object('ok',false,'mensaje','Sesión vencida. Ingresá de nuevo.'); end if;
  select nombre, coalesce(abierto,false) into v_nombre, v_abierto from public.noches where fecha = p_fecha;
  select coalesce(json_agg(json_build_object(
      'mesa_id', c.id, 'nombre', c.nombre, 'categoria', coalesce(c.categoria,''),
      'precio', coalesce(nullif(c.precio,''), case when c.precio_num is not null then '$'||replace(to_char(c.precio_num,'FM999,999,999'),',','.') else '' end),
      'precio_sug', c.precio_num,
      'titular', coalesce(n.titular,''), 'contacto', coalesce(n.contacto,''),
      'personas', coalesce(n.personas,0), 'monto', n.monto,
      'estado', coalesce(nullif(n.estado,''),'Libre'),
      'mia', (n.embajador_id = v_me), 'tomada', (coalesce(n.titular,'')<>''),
      'llego', (n.llegada is not null),
      'comp_url', coalesce(n.comprobante_url,''), 'comp_nombre', coalesce(n.comprobante_nombre,'')
    ) order by c.orden),'[]'::json) into v_mesas
  from public.mesas_config c
  left join public.mesas_noche n on n.mesa_id = c.id and n.fecha = p_fecha
  where coalesce(c.activo,true);
  select coalesce(json_agg(json_build_object(
      'id', id, 'nombre', nombre, 'dni', coalesce(dni,''), 'llego', (llegada is not null)
    ) order by lower(nombre)),'[]'::json) into v_inv
  from public.listas_noche where fecha = p_fecha and embajador_id = v_me;
  select coalesce(json_agg(json_build_object(
      'id', p.id, 'titular', p.titular, 'dni', coalesce(p.titular_dni,''),
      'monto', coalesce(p.monto,0), 'pax', coalesce(p.pax,0),
      'arreglo', coalesce(p.descripcion,''),
      'comp_url', coalesce(p.comprobante_url,''), 'comp_nombre', coalesce(p.comprobante_nombre,'')
    ) order by p.creado),'[]'::json) into v_prev
  from public.previas p where p.fecha = p_fecha and p.embajador_id = v_me;
  return json_build_object('ok',true,'nombre_noche',coalesce(v_nombre,''),'abierto',v_abierto,
    'mesas',v_mesas,'invitados',v_inv,'previas',v_prev);
end $function$;

-- 9) ba_admin_get: comprobante en mesas, arreglo+comprobante en previas -
create or replace function public.ba_admin_get(p_pin text, p_id bigint, p_desde date, p_hasta date)
returns json language plpgsql security definer set search_path to 'public' as $function$
declare v_perfil json; v_mesas json; v_prev json; v_pct numeric; v_tm numeric; v_tp numeric;
begin
  if not public._is_admin(p_pin) then return json_build_object('ok',false,'mensaje','Necesitás el PIN de admin.'); end if;
  select coalesce(comision_pct,20) into v_pct from public.embajadores where id=p_id;
  select json_build_object('id',id,'nombre',nombre,'apellido',coalesce(apellido,''),
           'dni',coalesce(dni,''),'ig',coalesce(ig,''),'contacto',coalesce(contacto,''),
           'banco',coalesce(banco,''),'email',coalesce(email,''),'comision_pct',coalesce(comision_pct,20),
           'tiene_pass',(pass_hash is not null))
    into v_perfil from public.embajadores where id=p_id;
  if v_perfil is null then return json_build_object('ok',false,'mensaje','No existe ese embajador.'); end if;
  select coalesce(json_agg(json_build_object(
      'fecha', to_char(n.fecha,'YYYY-MM-DD'), 'mesa', c.nombre, 'titular', n.titular,
      'monto', coalesce(n.monto,0), 'comision', round(coalesce(n.monto,0)*v_pct/100),
      'comp_url', coalesce(n.comprobante_url,'')
    ) order by n.fecha),'[]'::json), coalesce(sum(coalesce(n.monto,0)),0)
    into v_mesas, v_tm
  from public.mesas_noche n join public.mesas_config c on c.id=n.mesa_id
  where n.embajador_id=p_id and coalesce(n.titular,'')<>'' and n.fecha between p_desde and p_hasta;
  select coalesce(json_agg(json_build_object(
      'fecha', to_char(p.fecha,'YYYY-MM-DD'), 'titular', p.titular, 'pax', coalesce(p.pax,0),
      'monto', coalesce(p.monto,0), 'comision', round(coalesce(p.monto,0)*v_pct/100),
      'arreglo', coalesce(p.descripcion,''), 'comp_url', coalesce(p.comprobante_url,'')
    ) order by p.fecha),'[]'::json), coalesce(sum(coalesce(p.monto,0)),0)
    into v_prev, v_tp
  from public.previas p where p.embajador_id=p_id and p.fecha between p_desde and p_hasta;
  return json_build_object('ok',true,'perfil',v_perfil,'mesas',v_mesas,'previas',v_prev,
    'total_vendido', v_tm+v_tp, 'comision_total', round((v_tm+v_tp)*v_pct/100),
    'desde',to_char(p_desde,'YYYY-MM-DD'),'hasta',to_char(p_hasta,'YYYY-MM-DD'));
end $function$;

-- =====================================================================
notify pgrst, 'reload schema';
