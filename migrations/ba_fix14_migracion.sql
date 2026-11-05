-- =====================================================================
--  CHEZ CLUB · Fix 14 · Previa BA: lista de invitados en el mismo alta
--  ba_add_previa / ba_editar_previa ahora reciben p_items (la lista),
--  así el BA carga titular + datos + lista todo junto (como en Puerta).
-- =====================================================================

do $$ declare r record; begin
  for r in select oid::regprocedure sig from pg_proc
           where proname in ('ba_add_previa','ba_editar_previa') and pronamespace='public'::regnamespace
  loop execute 'drop function '||r.sig::text; end loop;
end $$;

create function public.ba_add_previa(
  p_token text, p_fecha date, p_titular text, p_dni text, p_pax integer,
  p_ent_monto numeric, p_ent_desc text, p_ent_comp_url text, p_ent_comp_nombre text,
  p_bot_monto numeric, p_bot_desc text, p_bot_comp_url text, p_bot_comp_nombre text,
  p_items json)
returns json language plpgsql security definer set search_path to 'public' as $function$
declare v_me bigint; v_id bigint; v_dni text; v_total numeric; v_desc text; it json; v_nom text; v_idni text;
begin
  v_me := public._ba(p_token);
  if v_me is null then return json_build_object('ok',false,'mensaje','Sesión vencida. Ingresá de nuevo.'); end if;
  if length(btrim(coalesce(p_titular,''))) < 2 then return json_build_object('ok',false,'mensaje','Falta el titular.'); end if;
  if coalesce(p_pax,0) < 1 then return json_build_object('ok',false,'mensaje','Indicá la cantidad de personas.'); end if;
  v_dni := nullif(regexp_replace(coalesce(p_dni,''),'[^0-9]','','g'),'');
  v_total := coalesce(p_ent_monto,0) + coalesce(p_bot_monto,0);
  v_desc := nullif(btrim(concat_ws(' · ', nullif(btrim(coalesce(p_ent_desc,'')),''), nullif(btrim(coalesce(p_bot_desc,'')),''))),'');
  insert into public.previas(fecha, titular, titular_dni, monto, descripcion, embajador_id, pax,
      entradas_monto, entradas_desc, entradas_comp_url, entradas_comp_nombre,
      botellas_monto, botellas_desc, botellas_comp_url, botellas_comp_nombre)
  values (p_fecha, btrim(p_titular), v_dni, v_total, v_desc, v_me, p_pax,
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
grant execute on function public.ba_add_previa(text,date,text,text,integer,numeric,text,text,text,numeric,text,text,text,json) to anon;

create function public.ba_editar_previa(
  p_token text, p_previa_id bigint, p_titular text, p_dni text, p_pax integer,
  p_ent_monto numeric, p_ent_desc text, p_ent_comp_url text, p_ent_comp_nombre text,
  p_bot_monto numeric, p_bot_desc text, p_bot_comp_url text, p_bot_comp_nombre text,
  p_items json)
returns json language plpgsql security definer set search_path to 'public' as $function$
declare v_me bigint; v_own bigint; v_dni text; v_total numeric; v_desc text; it json; v_nom text; v_idni text;
begin
  v_me := public._ba(p_token);
  if v_me is null then return json_build_object('ok',false,'mensaje','Sesión vencida. Ingresá de nuevo.'); end if;
  select embajador_id into v_own from public.previas where id=p_previa_id;
  if v_own is null or v_own <> v_me then return json_build_object('ok',false,'mensaje','Esa previa no es tuya.'); end if;
  if length(btrim(coalesce(p_titular,''))) < 2 then return json_build_object('ok',false,'mensaje','Falta el titular.'); end if;
  if coalesce(p_pax,0) < 1 then return json_build_object('ok',false,'mensaje','Indicá la cantidad de personas.'); end if;
  v_dni := nullif(regexp_replace(coalesce(p_dni,''),'[^0-9]','','g'),'');
  v_total := coalesce(p_ent_monto,0) + coalesce(p_bot_monto,0);
  v_desc := nullif(btrim(concat_ws(' · ', nullif(btrim(coalesce(p_ent_desc,'')),''), nullif(btrim(coalesce(p_bot_desc,'')),''))),'');
  update public.previas set
     titular=btrim(p_titular), titular_dni=v_dni, pax=p_pax, monto=v_total, descripcion=v_desc,
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
grant execute on function public.ba_editar_previa(text,bigint,text,text,integer,numeric,text,text,text,numeric,text,text,text,json) to anon;

notify pgrst, 'reload schema';
