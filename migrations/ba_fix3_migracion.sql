-- =====================================================================
--  CHEZ CLUB · Correcciones 3
--  - House Members: nunca mostrar noches pasadas (garantía servidor)
--  - Precio de mesa editable POR NOCHE (override), con default de catálogo
--  - CRM: ventas del BA por el mes seleccionado arriba
--  Idempotente.
-- =====================================================================

-- 1) HM · solo noches de hoy en adelante (con gracia hasta las 08:00) ---
create or replace function public.get_noches_abiertas()
returns json language plpgsql security definer set search_path to 'public' as $function$
declare v_hoy date; v_corte date; v_noches json;
begin
  v_hoy := (now() at time zone 'America/Argentina/Buenos_Aires')::date;
  v_corte := case when (now() at time zone 'America/Argentina/Buenos_Aires')::time < time '08:00'
                  then v_hoy - 1 else v_hoy end;
  select coalesce(json_agg(json_build_object('fecha',to_char(fecha,'YYYY-MM-DD'),'nombre',nombre) order by fecha),'[]'::json)
    into v_noches
  from public.noches where abierto = true and fecha >= v_corte;
  return json_build_object('max_invitados', coalesce(public.cfg('max_invitados')::int,2), 'noches', v_noches);
end $function$;

-- 2) Precio por noche -------------------------------------------------
alter table public.mesas_noche add column if not exists precio_num numeric;

-- Defaults de catálogo (por orden de mesa)
update public.mesas_config set precio_num=500000, precio='$500.000' where orden=1;
update public.mesas_config set precio_num=400000, precio='$400.000' where orden in (2,3,4);
update public.mesas_config set precio_num=350000, precio='$350.000' where orden=5;
update public.mesas_config set precio_num=300000, precio='$300.000' where orden=6;

-- Editar precio SOLO de esa mesa en esa noche (null = volver al default)
drop function if exists public.set_mesa_precio(text,bigint,numeric);
create or replace function public.set_mesa_precio(p_pin text, p_fecha date, p_mesa_id bigint, p_precio_num numeric)
returns json language plpgsql security definer set search_path to 'public' as $function$
begin
  if not public._is_admin(p_pin) then return json_build_object('ok',false,'mensaje','Necesitás el PIN de admin.'); end if;
  if p_precio_num is not null and p_precio_num <= 0 then return json_build_object('ok',false,'mensaje','Precio inválido.'); end if;
  insert into public.mesas_noche(fecha, mesa_id, precio_num)
  values (p_fecha, p_mesa_id, case when p_precio_num is null then null else round(p_precio_num) end)
  on conflict (fecha, mesa_id) do update set precio_num = excluded.precio_num;
  return json_build_object('ok',true);
end $function$;
grant execute on function public.set_mesa_precio(text,date,bigint,numeric) to anon;

-- get_mesas_noche: precio EFECTIVO = override de la noche o default
create or replace function public.get_mesas_noche(p_pin text, p_fecha date)
returns json language plpgsql security definer set search_path to 'public' as $function$
declare v_lista json;
begin
  if not public._is_staff(p_pin) then return json_build_object('ok',false,'mensaje','PIN incorrecto.'); end if;
  select coalesce(json_agg(json_build_object(
    'mesa_id',c.id,'nombre',c.nombre,'categoria',coalesce(c.categoria,''),
    'precio', case when coalesce(n.precio_num,c.precio_num) is not null
                   then '$'||replace(to_char(coalesce(n.precio_num,c.precio_num),'FM999,999,999'),',','.')
                   else coalesce(c.precio,'') end,
    'precio_num', coalesce(n.precio_num, c.precio_num),
    'precio_editado', (n.precio_num is not null),
    'consumos', case when coalesce(n.precio_num,c.precio_num) is not null then json_build_array(
        json_build_object('horario','00:30–01:30','monto', ceil(coalesce(n.precio_num,c.precio_num)*0.8/10000)*10000),
        json_build_object('horario','01:30–02:30','monto', ceil(coalesce(n.precio_num,c.precio_num)*0.7/10000)*10000),
        json_build_object('horario','desde 02:30','monto', ceil(coalesce(n.precio_num,c.precio_num)*0.5/10000)*10000)
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

-- ba_noche: precio efectivo para el portal del BA
create or replace function public.ba_noche(p_token text, p_fecha date)
returns json language plpgsql security definer set search_path to 'public' as $function$
declare v_me bigint; v_mesas json; v_inv json; v_prev json; v_nombre text; v_abierto boolean;
begin
  v_me := public._ba(p_token);
  if v_me is null then return json_build_object('ok',false,'mensaje','Sesión vencida. Ingresá de nuevo.'); end if;
  select nombre, coalesce(abierto,false) into v_nombre, v_abierto from public.noches where fecha = p_fecha;
  select coalesce(json_agg(json_build_object(
      'mesa_id', c.id, 'nombre', c.nombre, 'categoria', coalesce(c.categoria,''),
      'precio', case when coalesce(n.precio_num,c.precio_num) is not null
                     then '$'||replace(to_char(coalesce(n.precio_num,c.precio_num),'FM999,999,999'),',','.')
                     else coalesce(c.precio,'') end,
      'precio_sug', coalesce(n.precio_num, c.precio_num),
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

-- 3) CRM · lista de BA por el mes seleccionado -------------------------
drop function if exists public.ba_admin_list(text);
create or replace function public.ba_admin_list(p_pin text, p_anio int, p_mes int)
returns json language plpgsql security definer set search_path to 'public' as $function$
declare v json; v_d0 date; v_d1 date;
begin
  if not public._is_admin(p_pin) then return json_build_object('ok',false,'mensaje','Necesitás el PIN de admin.'); end if;
  v_d0 := make_date(p_anio, p_mes, 1);
  v_d1 := (v_d0 + interval '1 month' - interval '1 day')::date;
  select coalesce(json_agg(json_build_object(
    'id', e.id, 'nombre', e.nombre, 'apellido', coalesce(e.apellido,''),
    'email', coalesce(e.email,''), 'tiene_pass', (e.pass_hash is not null),
    'comision_pct', coalesce(e.comision_pct,20),
    'ventas_mes', v.vendido, 'comision_mes', round(v.vendido*coalesce(e.comision_pct,20)/100)
  ) order by lower(e.nombre)),'[]'::json) into v
  from public.embajadores e
  cross join lateral (
    select
      coalesce((select sum(coalesce(m.monto,0)) from public.mesas_noche m
                where m.embajador_id=e.id and coalesce(m.titular,'')<>'' and m.fecha between v_d0 and v_d1),0)
    + coalesce((select sum(coalesce(p.monto,0)) from public.previas p
                where p.embajador_id=e.id and p.fecha between v_d0 and v_d1),0) as vendido
  ) v
  where coalesce(e.activo,true) and coalesce(e.es_ba,false);
  return json_build_object('ok',true,'embajadores',v,'mes', to_char(v_d0,'YYYY-MM'));
end $function$;
grant execute on function public.ba_admin_list(text,int,int) to anon;

-- =====================================================================
notify pgrst, 'reload schema';
