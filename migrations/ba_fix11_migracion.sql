-- =====================================================================
--  CHEZ CLUB · Fix 11 · Previas: entradas/botellas + lista de invitados
--                        + edición (lado Brand Ambassador)
--  - previas.monto se mantiene como TOTAL = entradas + botellas
--    (así resumen, pagos y comisiones siguen funcionando sin cambios).
--  - El lado de Puerta (crear_previa/editar_previa) NO se toca acá:
--    sigue con monto único hasta pasar sus dumps.
-- =====================================================================

-- 1) Columnas nuevas -------------------------------------------------
alter table public.previas add column if not exists entradas_monto numeric;
alter table public.previas add column if not exists entradas_desc text;
alter table public.previas add column if not exists entradas_comp_url text;
alter table public.previas add column if not exists entradas_comp_nombre text;
alter table public.previas add column if not exists botellas_monto numeric;
alter table public.previas add column if not exists botellas_desc text;
alter table public.previas add column if not exists botellas_comp_url text;
alter table public.previas add column if not exists botellas_comp_nombre text;

-- Previas viejas: pasamos el monto único a "entradas" para no perderlo
update public.previas
   set entradas_monto = coalesce(monto,0)
 where entradas_monto is null and botellas_monto is null;

-- 2) ba_add_previa (nueva firma) -------------------------------------
do $$ declare r record; begin
  for r in select oid::regprocedure sig from pg_proc
           where proname='ba_add_previa' and pronamespace='public'::regnamespace
  loop execute 'drop function '||r.sig::text; end loop;
end $$;

create function public.ba_add_previa(
  p_token text, p_fecha date, p_titular text, p_dni text, p_pax integer,
  p_ent_monto numeric, p_ent_desc text, p_ent_comp_url text, p_ent_comp_nombre text,
  p_bot_monto numeric, p_bot_desc text, p_bot_comp_url text, p_bot_comp_nombre text)
returns json language plpgsql security definer set search_path to 'public' as $function$
declare v_me bigint; v_id bigint; v_dni text; v_total numeric; v_desc text;
begin
  v_me := public._ba(p_token);
  if v_me is null then return json_build_object('ok',false,'mensaje','Sesión vencida. Ingresá de nuevo.'); end if;
  if length(btrim(coalesce(p_titular,''))) < 2 then return json_build_object('ok',false,'mensaje','Falta el titular.'); end if;
  if coalesce(p_pax,0) < 1 then return json_build_object('ok',false,'mensaje','Indicá la cantidad de personas.'); end if;
  v_dni := nullif(regexp_replace(coalesce(p_dni,''),'[^0-9]','','g'),'');
  v_total := coalesce(p_ent_monto,0) + coalesce(p_bot_monto,0);
  v_desc := nullif(btrim(concat_ws(' · ',
              nullif(btrim(coalesce(p_ent_desc,'')),''),
              nullif(btrim(coalesce(p_bot_desc,'')),''))),'');
  insert into public.previas(fecha, titular, titular_dni, monto, descripcion, embajador_id, pax,
      entradas_monto, entradas_desc, entradas_comp_url, entradas_comp_nombre,
      botellas_monto, botellas_desc, botellas_comp_url, botellas_comp_nombre)
  values (p_fecha, btrim(p_titular), v_dni, v_total, v_desc, v_me, p_pax,
      coalesce(p_ent_monto,0), nullif(btrim(coalesce(p_ent_desc,'')),''), nullif(btrim(coalesce(p_ent_comp_url,'')),''), nullif(btrim(coalesce(p_ent_comp_nombre,'')),''),
      coalesce(p_bot_monto,0), nullif(btrim(coalesce(p_bot_desc,'')),''), nullif(btrim(coalesce(p_bot_comp_url,'')),''), nullif(btrim(coalesce(p_bot_comp_nombre,'')),''))
  returning id into v_id;
  insert into public.previa_invitados(previa_id, nombre, dni, orden) values (v_id, btrim(p_titular), v_dni, 0);
  return json_build_object('ok',true,'id',v_id);
end $function$;
grant execute on function public.ba_add_previa(text,date,text,text,integer,numeric,text,text,text,numeric,text,text,text) to anon;

-- 3) ba_editar_previa (nueva) ----------------------------------------
create or replace function public.ba_editar_previa(
  p_token text, p_previa_id bigint, p_titular text, p_dni text, p_pax integer,
  p_ent_monto numeric, p_ent_desc text, p_ent_comp_url text, p_ent_comp_nombre text,
  p_bot_monto numeric, p_bot_desc text, p_bot_comp_url text, p_bot_comp_nombre text)
returns json language plpgsql security definer set search_path to 'public' as $function$
declare v_me bigint; v_own bigint; v_dni text; v_total numeric; v_desc text;
begin
  v_me := public._ba(p_token);
  if v_me is null then return json_build_object('ok',false,'mensaje','Sesión vencida. Ingresá de nuevo.'); end if;
  select embajador_id into v_own from public.previas where id=p_previa_id;
  if v_own is null or v_own <> v_me then return json_build_object('ok',false,'mensaje','Esa previa no es tuya.'); end if;
  if length(btrim(coalesce(p_titular,''))) < 2 then return json_build_object('ok',false,'mensaje','Falta el titular.'); end if;
  if coalesce(p_pax,0) < 1 then return json_build_object('ok',false,'mensaje','Indicá la cantidad de personas.'); end if;
  v_dni := nullif(regexp_replace(coalesce(p_dni,''),'[^0-9]','','g'),'');
  v_total := coalesce(p_ent_monto,0) + coalesce(p_bot_monto,0);
  v_desc := nullif(btrim(concat_ws(' · ',
              nullif(btrim(coalesce(p_ent_desc,'')),''),
              nullif(btrim(coalesce(p_bot_desc,'')),''))),'');
  update public.previas set
     titular=btrim(p_titular), titular_dni=v_dni, pax=p_pax, monto=v_total, descripcion=v_desc,
     entradas_monto=coalesce(p_ent_monto,0), entradas_desc=nullif(btrim(coalesce(p_ent_desc,'')),''),
     entradas_comp_url   = coalesce(nullif(btrim(coalesce(p_ent_comp_url,'')),''), entradas_comp_url),
     entradas_comp_nombre= coalesce(nullif(btrim(coalesce(p_ent_comp_nombre,'')),''), entradas_comp_nombre),
     botellas_monto=coalesce(p_bot_monto,0), botellas_desc=nullif(btrim(coalesce(p_bot_desc,'')),''),
     botellas_comp_url   = coalesce(nullif(btrim(coalesce(p_bot_comp_url,'')),''), botellas_comp_url),
     botellas_comp_nombre= coalesce(nullif(btrim(coalesce(p_bot_comp_nombre,'')),''), botellas_comp_nombre)
   where id=p_previa_id;
  update public.previa_invitados set nombre=btrim(p_titular), dni=v_dni where previa_id=p_previa_id and orden=0;
  return json_build_object('ok',true);
end $function$;
grant execute on function public.ba_editar_previa(text,bigint,text,text,integer,numeric,text,text,text,numeric,text,text,text) to anon;

-- 4) Lista de invitados de la previa (BA) ----------------------------
create or replace function public.ba_previa_add_invitados(p_token text, p_previa_id bigint, p_items json)
returns json language plpgsql security definer set search_path to 'public' as $function$
declare v_me bigint; v_own bigint; it json; v_nom text; v_dni text; v_n int := 0;
begin
  v_me := public._ba(p_token);
  if v_me is null then return json_build_object('ok',false,'mensaje','Sesión vencida. Ingresá de nuevo.'); end if;
  select embajador_id into v_own from public.previas where id=p_previa_id;
  if v_own is null or v_own <> v_me then return json_build_object('ok',false,'mensaje','Esa previa no es tuya.'); end if;
  for it in select * from json_array_elements(coalesce(p_items,'[]'::json)) loop
    v_nom := btrim(coalesce(it->>'nombre',''));
    if length(v_nom) < 2 then continue; end if;
    v_dni := nullif(regexp_replace(coalesce(it->>'dni',''),'[^0-9]','','g'),'');
    insert into public.previa_invitados(previa_id, nombre, dni, orden) values (p_previa_id, v_nom, v_dni, 1);
    v_n := v_n + 1;
  end loop;
  return json_build_object('ok',true,'agregados',v_n);
end $function$;
grant execute on function public.ba_previa_add_invitados(text,bigint,json) to anon;

create or replace function public.ba_previa_quitar_invitado(p_token text, p_inv_id bigint)
returns json language plpgsql security definer set search_path to 'public' as $function$
declare v_me bigint; v_own bigint; v_orden int;
begin
  v_me := public._ba(p_token);
  if v_me is null then return json_build_object('ok',false,'mensaje','Sesión vencida. Ingresá de nuevo.'); end if;
  select p.embajador_id, i.orden into v_own, v_orden
    from public.previa_invitados i join public.previas p on p.id=i.previa_id where i.id=p_inv_id;
  if v_own is null or v_own <> v_me then return json_build_object('ok',false,'mensaje','Ese invitado no es tuyo.'); end if;
  if coalesce(v_orden,1) = 0 then return json_build_object('ok',false,'mensaje','No se puede quitar al titular.'); end if;
  delete from public.previa_invitados where id=p_inv_id;
  return json_build_object('ok',true);
end $function$;
grant execute on function public.ba_previa_quitar_invitado(text,bigint) to anon;

-- 5) get_previas (Puerta) · devuelve el desglose ---------------------
create or replace function public.get_previas(p_pin text, p_fecha date)
returns json language plpgsql security definer set search_path to 'public' as $function$
declare v json;
begin
  if not public._is_staff(p_pin) then return json_build_object('ok',false,'mensaje','PIN incorrecto.'); end if;
  select coalesce(json_agg(json_build_object(
    'id',p.id,'titular',p.titular,'titular_dni',coalesce(p.titular_dni,''),
    'monto',coalesce(p.monto,0),'descripcion',coalesce(p.descripcion,''),'arreglo',coalesce(p.descripcion,''),
    'ent_monto',coalesce(p.entradas_monto,0),'ent_desc',coalesce(p.entradas_desc,''),
    'ent_comp_url',coalesce(p.entradas_comp_url,''),
    'bot_monto',coalesce(p.botellas_monto,0),'bot_desc',coalesce(p.botellas_desc,''),
    'bot_comp_url',coalesce(p.botellas_comp_url,''),
    'comprobante_url',coalesce(p.comprobante_url,''),'comprobante_nombre',coalesce(p.comprobante_nombre,''),
    'invitados',(
      select coalesce(json_agg(json_build_object(
        'id',i.id,'nombre',i.nombre,'dni',coalesce(i.dni,''),
        'llego',(i.llegada is not null),'hora',coalesce(i.llegada,'')) order by i.orden, lower(i.nombre)),'[]'::json)
      from public.previa_invitados i where i.previa_id=p.id),
    'total',(select count(*) from public.previa_invitados i where i.previa_id=p.id),
    'ingresados',(select count(*) from public.previa_invitados i where i.previa_id=p.id and i.llegada is not null)
  ) order by p.creado),'[]'::json) into v
  from public.previas p where p.fecha=p_fecha;
  return json_build_object('ok',true,'previas',v);
end $function$;

-- 6) ba_noche (portal BA) · previa con desglose + invitados ----------
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
      'ent_monto', coalesce(p.entradas_monto,0), 'ent_desc', coalesce(p.entradas_desc,''),
      'ent_comp_url', coalesce(p.entradas_comp_url,''),
      'bot_monto', coalesce(p.botellas_monto,0), 'bot_desc', coalesce(p.botellas_desc,''),
      'bot_comp_url', coalesce(p.botellas_comp_url,''),
      'comp_url', coalesce(p.comprobante_url,''), 'comp_nombre', coalesce(p.comprobante_nombre,''),
      'invitados', (
        select coalesce(json_agg(json_build_object(
          'id', i.id, 'nombre', i.nombre, 'dni', coalesce(i.dni,''), 'orden', coalesce(i.orden,1),
          'llego', (i.llegada is not null)) order by i.orden, lower(i.nombre)),'[]'::json)
        from public.previa_invitados i where i.previa_id=p.id)
    ) order by p.creado),'[]'::json) into v_prev
  from public.previas p where p.fecha = p_fecha and p.embajador_id = v_me;
  return json_build_object('ok',true,'nombre_noche',coalesce(v_nombre,''),'abierto',v_abierto,
    'mesas',v_mesas,'invitados',v_inv,'previas',v_prev);
end $function$;

notify pgrst, 'reload schema';
