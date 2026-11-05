-- =====================================================================
--  CHEZ CLUB · Fix 13
--  A) crear_previa / editar_previa con entradas/botellas (Puerta).
--     monto = entradas + botellas; descripcion = las dos descripciones.
--  B) ba_generar_pagos_mes: vencimiento = 7 del mes en que corre
--     (corre el día 1 → vence el 7). Así los pagos salen con fecha.
-- =====================================================================

-- A) -----------------------------------------------------------------
do $$ declare r record; begin
  for r in select oid::regprocedure sig from pg_proc
           where proname in ('crear_previa','editar_previa') and pronamespace='public'::regnamespace
  loop execute 'drop function '||r.sig::text; end loop;
end $$;

create function public.crear_previa(
  p_pin text, p_fecha date, p_titular text, p_dni text,
  p_ent_monto numeric, p_ent_desc text, p_ent_comp_url text, p_ent_comp_nombre text,
  p_bot_monto numeric, p_bot_desc text, p_bot_comp_url text, p_bot_comp_nombre text,
  p_items json)
returns json language plpgsql security definer set search_path to 'public' as $function$
declare v_id bigint; v_dni text; it json; v_nom text; v_idni text; v_total numeric; v_desc text;
begin
  if not public._is_staff(p_pin) then return json_build_object('ok',false,'mensaje','PIN incorrecto.'); end if;
  if length(btrim(coalesce(p_titular,''))) < 2 then return json_build_object('ok',false,'mensaje','Falta el titular.'); end if;
  v_dni := nullif(regexp_replace(coalesce(p_dni,''),'[^0-9]','','g'),'');
  v_total := coalesce(p_ent_monto,0) + coalesce(p_bot_monto,0);
  v_desc := nullif(btrim(concat_ws(' · ', nullif(btrim(coalesce(p_ent_desc,'')),''), nullif(btrim(coalesce(p_bot_desc,'')),''))),'');
  insert into public.previas(fecha, titular, titular_dni, monto, descripcion,
      entradas_monto, entradas_desc, entradas_comp_url, entradas_comp_nombre,
      botellas_monto, botellas_desc, botellas_comp_url, botellas_comp_nombre)
  values (p_fecha, btrim(p_titular), v_dni, v_total, v_desc,
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
grant execute on function public.crear_previa(text,date,text,text,numeric,text,text,text,numeric,text,text,text,json) to anon;

create function public.editar_previa(
  p_pin text, p_previa_id bigint, p_titular text, p_dni text,
  p_ent_monto numeric, p_ent_desc text, p_ent_comp_url text, p_ent_comp_nombre text,
  p_bot_monto numeric, p_bot_desc text, p_bot_comp_url text, p_bot_comp_nombre text,
  p_items json)
returns json language plpgsql security definer set search_path to 'public' as $function$
declare v_dni text; it json; v_nom text; v_idni text; v_total numeric; v_desc text;
begin
  if not public._is_staff(p_pin) then return json_build_object('ok',false,'mensaje','PIN incorrecto.'); end if;
  if not exists(select 1 from public.previas where id=p_previa_id) then return json_build_object('ok',false,'mensaje','No existe la previa.'); end if;
  if length(btrim(coalesce(p_titular,''))) < 2 then return json_build_object('ok',false,'mensaje','Falta el titular.'); end if;
  v_dni := nullif(regexp_replace(coalesce(p_dni,''),'[^0-9]','','g'),'');
  v_total := coalesce(p_ent_monto,0) + coalesce(p_bot_monto,0);
  v_desc := nullif(btrim(concat_ws(' · ', nullif(btrim(coalesce(p_ent_desc,'')),''), nullif(btrim(coalesce(p_bot_desc,'')),''))),'');
  update public.previas set
     titular=btrim(p_titular), titular_dni=v_dni, monto=v_total, descripcion=v_desc,
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
grant execute on function public.editar_previa(text,bigint,text,text,numeric,text,text,text,numeric,text,text,text,json) to anon;

-- B) ba_generar_pagos_mes con vencimiento el 7 ------------------------
create or replace function public.ba_generar_pagos_mes(p_ref date default null)
returns json language plpgsql security definer set search_path to 'public' as $function$
declare v_ref date; v_d0 date; v_d1 date; v_ym text; v_mesn text; v_vence date; r record; v_com numeric; v_pid bigint; v_n int := 0;
        v_meses text[] := array['enero','febrero','marzo','abril','mayo','junio','julio','agosto','septiembre','octubre','noviembre','diciembre'];
begin
  v_ref := coalesce(p_ref, (now() at time zone 'America/Argentina/Buenos_Aires')::date);
  v_d0  := (date_trunc('month', v_ref) - interval '1 month')::date;     -- 1er día mes anterior
  v_d1  := (date_trunc('month', v_ref) - interval '1 day')::date;       -- último día mes anterior
  v_vence := (date_trunc('month', v_ref) + interval '6 days')::date;    -- 7 del mes en que corre
  v_ym  := to_char(v_d0,'YYYY-MM');
  v_mesn := v_meses[extract(month from v_d0)::int] || ' ' || to_char(v_d0,'YYYY');

  for r in
    select e.id, e.nombre, coalesce(e.apellido,'') ape, coalesce(e.banco,'') banco,
           coalesce(e.contacto,'') contacto, coalesce(e.comision_pct,20) pct
    from public.embajadores e where coalesce(e.activo,true)
  loop
    if exists(select 1 from public.ba_pago_mes where embajador_id=r.id and ym=v_ym) then continue; end if;
    v_com := round((
        coalesce((select sum(coalesce(m.monto,0)) from public.mesas_noche m
                  where m.embajador_id=r.id and coalesce(m.titular,'')<>'' and m.fecha between v_d0 and v_d1),0)
      + coalesce((select sum(coalesce(p.monto,0)) from public.previas p
                  where p.embajador_id=r.id and p.fecha between v_d0 and v_d1),0)
      ) * r.pct / 100);
    if v_com > 0 then
      insert into public.pagos(concepto, monto, destinatario, alias_cbu, contacto, vence)
      values ('Comisión BA · '||r.nombre||' '||r.ape||' · '||v_mesn,
              v_com, btrim(r.nombre||' '||r.ape), nullif(r.banco,''), nullif(r.contacto,''), v_vence)
      returning id into v_pid;
      insert into public.ba_pago_mes(embajador_id, ym, pago_id) values (r.id, v_ym, v_pid);
      v_n := v_n + 1;
    end if;
  end loop;
  return json_build_object('ok',true,'mes',v_ym,'pagos_creados',v_n,'vence',to_char(v_vence,'YYYY-MM-DD'));
end $function$;

notify pgrst, 'reload schema';
