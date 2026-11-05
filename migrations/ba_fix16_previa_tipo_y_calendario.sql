-- =====================================================================
--  CHEZ CLUB · Fix 16 · Tipo de previa + previas en calendario + resumen
--  * previas.tipo (comun/influencer/marca)
--  * crear_previa/editar_previa reciben p_tipo (con default -> no rompe el HTML viejo)
--  * get_previas devuelve tipo; get_calendario suma previas + previas_pax
--  * get_resumen_fecha (nuevo): previas c/tipo + mesas vendidas + invitaciones
-- =====================================================================
alter table public.previas add column if not exists tipo text default 'comun';

do $$ declare r record; begin
  for r in select oid::regprocedure sig from pg_proc
           where proname in ('crear_previa','editar_previa') and pronamespace='public'::regnamespace
  loop execute 'drop function '||r.sig::text; end loop;
end $$;

create function public.crear_previa(
  p_pin text, p_fecha date, p_titular text, p_dni text,
  p_ent_monto numeric, p_ent_desc text, p_ent_comp_url text, p_ent_comp_nombre text,
  p_bot_monto numeric, p_bot_desc text, p_bot_comp_url text, p_bot_comp_nombre text,
  p_items json, p_tipo text default 'comun')
returns json language plpgsql security definer set search_path to 'public' as $function$
declare v_id bigint; v_dni text; it json; v_nom text; v_idni text; v_total numeric; v_desc text; v_tipo text;
begin
  if not public._is_staff(p_pin) then return json_build_object('ok',false,'mensaje','PIN incorrecto.'); end if;
  if length(btrim(coalesce(p_titular,''))) < 2 then return json_build_object('ok',false,'mensaje','Falta el titular.'); end if;
  v_tipo := lower(coalesce(nullif(btrim(p_tipo),''),'comun'));
  if v_tipo not in ('comun','influencer','marca') then v_tipo := 'comun'; end if;
  v_dni := nullif(regexp_replace(coalesce(p_dni,''),'[^0-9]','','g'),'');
  v_total := coalesce(p_ent_monto,0) + coalesce(p_bot_monto,0);
  v_desc := nullif(btrim(concat_ws(' · ', nullif(btrim(coalesce(p_ent_desc,'')),''), nullif(btrim(coalesce(p_bot_desc,'')),''))),'');
  insert into public.previas(fecha, titular, titular_dni, monto, descripcion, tipo,
      entradas_monto, entradas_desc, entradas_comp_url, entradas_comp_nombre,
      botellas_monto, botellas_desc, botellas_comp_url, botellas_comp_nombre)
  values (p_fecha, btrim(p_titular), v_dni, v_total, v_desc, v_tipo,
      coalesce(p_ent_monto,0), nullif(btrim(coalesce(p_ent_desc,'')),''), nullif(btrim(coalesce(p_ent_comp_url,'')),''), nullif(btrim(coalesce(p_ent_comp_nombre,'')),''),
      coalesce(p_bot_monto,0), nullif(btrim(coalesce(p_bot_desc,'')),''), nullif(btrim(coalesce(p_bot_comp_url,'')),''), nullif(btrim(coalesce(p_bot_comp_nombre,'')),''))
  returning id into v_id;
  insert into public.previa_invitados(previa_id, nombre, dni, orden) values (v_id, btrim(p_titular), v_dni, 0);
  for it in select * from json_array_elements(coalesce(p_items,'[]'::json)) loop
    v_nom := btrim(coalesce(it->>'nombre','')); if length(v_nom) < 2 then continue; end if;
    v_idni := nullif(regexp_replace(coalesce(it->>'dni',''),'[^0-9]','','g'),'');
    insert into public.previa_invitados(previa_id, nombre, dni, orden) values (v_id, v_nom, v_idni, 1);
  end loop;
  return json_build_object('ok',true,'id',v_id);
end $function$;
grant execute on function public.crear_previa(text,date,text,text,numeric,text,text,text,numeric,text,text,text,json,text) to anon;

create function public.editar_previa(
  p_pin text, p_previa_id bigint, p_titular text, p_dni text,
  p_ent_monto numeric, p_ent_desc text, p_ent_comp_url text, p_ent_comp_nombre text,
  p_bot_monto numeric, p_bot_desc text, p_bot_comp_url text, p_bot_comp_nombre text,
  p_items json, p_tipo text default 'comun')
returns json language plpgsql security definer set search_path to 'public' as $function$
declare v_dni text; it json; v_nom text; v_idni text; v_total numeric; v_desc text; v_tipo text;
begin
  if not public._is_staff(p_pin) then return json_build_object('ok',false,'mensaje','PIN incorrecto.'); end if;
  if not exists(select 1 from public.previas where id=p_previa_id) then return json_build_object('ok',false,'mensaje','No existe la previa.'); end if;
  if length(btrim(coalesce(p_titular,''))) < 2 then return json_build_object('ok',false,'mensaje','Falta el titular.'); end if;
  v_tipo := lower(coalesce(nullif(btrim(p_tipo),''),'comun'));
  if v_tipo not in ('comun','influencer','marca') then v_tipo := 'comun'; end if;
  v_dni := nullif(regexp_replace(coalesce(p_dni,''),'[^0-9]','','g'),'');
  v_total := coalesce(p_ent_monto,0) + coalesce(p_bot_monto,0);
  v_desc := nullif(btrim(concat_ws(' · ', nullif(btrim(coalesce(p_ent_desc,'')),''), nullif(btrim(coalesce(p_bot_desc,'')),''))),'');
  update public.previas set
     titular=btrim(p_titular), titular_dni=v_dni, monto=v_total, descripcion=v_desc, tipo=v_tipo,
     entradas_monto=coalesce(p_ent_monto,0), entradas_desc=nullif(btrim(coalesce(p_ent_desc,'')),''),
     entradas_comp_url   = coalesce(nullif(btrim(coalesce(p_ent_comp_url,'')),''), entradas_comp_url),
     entradas_comp_nombre= coalesce(nullif(btrim(coalesce(p_ent_comp_nombre,'')),''), entradas_comp_nombre),
     botellas_monto=coalesce(p_bot_monto,0), botellas_desc=nullif(btrim(coalesce(p_bot_desc,'')),''),
     botellas_comp_url   = coalesce(nullif(btrim(coalesce(p_bot_comp_url,'')),''), botellas_comp_url),
     botellas_comp_nombre= coalesce(nullif(btrim(coalesce(p_bot_comp_nombre,'')),''), botellas_comp_nombre)
   where id=p_previa_id;
  delete from public.previa_invitados where previa_id=p_previa_id;
  insert into public.previa_invitados(previa_id, nombre, dni, orden) values (p_previa_id, btrim(p_titular), v_dni, 0);
  for it in select * from json_array_elements(coalesce(p_items,'[]'::json)) loop
    v_nom := btrim(coalesce(it->>'nombre','')); if length(v_nom) < 2 then continue; end if;
    v_idni := nullif(regexp_replace(coalesce(it->>'dni',''),'[^0-9]','','g'),'');
    insert into public.previa_invitados(previa_id, nombre, dni, orden) values (p_previa_id, v_nom, v_idni, 1);
  end loop;
  return json_build_object('ok',true);
end $function$;
grant execute on function public.editar_previa(text,bigint,text,text,numeric,text,text,text,numeric,text,text,text,json,text) to anon;

create or replace function public.get_previas(p_pin text, p_fecha date)
returns json language plpgsql security definer set search_path to 'public' as $function$
declare v json;
begin
  if not public._is_staff(p_pin) then return json_build_object('ok',false,'mensaje','PIN incorrecto.'); end if;
  select coalesce(json_agg(json_build_object(
    'id',p.id,'titular',p.titular,'titular_dni',coalesce(p.titular_dni,''),
    'tipo',coalesce(p.tipo,'comun'),
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
    'previas_pax',(select coalesce(sum(coalesce(pr.pax,0)),0) from public.previas pr where pr.fecha=n.fecha)
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
           'id',id,'titular',titular,'pax',coalesce(pax,0),'tipo',coalesce(tipo,'comun')) order by creado),'[]'::json)
    into v_prev from public.previas where fecha=p_fecha;
  select count(*), coalesce(sum(coalesce(pax,0)),0) into p_cant, p_pax from public.previas where fecha=p_fecha;
  select count(*) into m_vend from public.mesas_noche where fecha=p_fecha and coalesce(titular,'')<>'';
  select coalesce(sum(coalesce(cantidad,1)),0) into hm from public.rsvp where fecha=p_fecha and upper(estado)='CONFIRMADO';
  select count(*) into lst from public.listas_noche where fecha=p_fecha;
  return json_build_object('ok',true,
    'previas', json_build_object('cantidad',p_cant,'pax',p_pax,'lista',v_prev),
    'mesas_vendidas', m_vend,
    'invitaciones', json_build_object('total', hm+lst, 'hm', hm, 'listas', lst));
end $function$;
grant execute on function public.get_resumen_fecha(text,date) to anon;

notify pgrst, 'reload schema';
