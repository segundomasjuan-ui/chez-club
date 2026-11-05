-- =====================================================================
--  CHEZ CLUB · Fix 7 · BA + Paula
--  - embajadores.pass_claro: contraseña legible para que el admin la vea
--    (decisión explícita; queda en texto en la base).
--  - ba_admin_upsert / ba_admin_reset_pass: guardan pass_claro.
--  - ba_admin_get: devuelve pass_claro y banco (datos bancarios libres).
--  - ba_resumen: suma invitados_total (lista de invitados del período).
--  Firmas idénticas a las actuales → create or replace, sin duplicar.
-- =====================================================================

alter table public.embajadores add column if not exists pass_claro text;

-- Backfill: para los que ya tienen contraseña pero no la tenemos legible,
-- dejamos un aviso (no se puede recuperar un bcrypt viejo).
update public.embajadores
   set pass_claro = '(desconocida — reseteá para ver una nueva)'
 where pass_hash is not null and pass_claro is null;

-- ---------------------------------------------------------------------
create or replace function public.ba_admin_upsert(
  p_pin text, p_id bigint, p_nombre text, p_apellido text, p_dni text, p_ig text,
  p_contacto text, p_banco text, p_email text, p_comision_pct numeric, p_pass text)
returns json language plpgsql security definer set search_path to 'public','extensions' as $function$
declare v_id bigint; v_gen text := null; v_email text; v_plain text;
begin
  if not public._is_admin(p_pin) then return json_build_object('ok',false,'mensaje','Necesitás el PIN de admin.'); end if;
  if length(btrim(coalesce(p_nombre,''))) < 2 then return json_build_object('ok',false,'mensaje','Falta el nombre.'); end if;
  v_email := lower(nullif(btrim(coalesce(p_email,'')),''));
  if v_email is not null and exists(
      select 1 from public.embajadores where lower(email)=v_email and id is distinct from p_id) then
    return json_build_object('ok',false,'mensaje','Ese email ya está en uso.');
  end if;

  if p_id is null then
    if nullif(btrim(coalesce(p_pass,'')),'') is null then
      v_gen := upper(substr(replace(gen_random_uuid()::text,'-',''),1,8));
    end if;
    v_plain := coalesce(nullif(btrim(coalesce(p_pass,'')),''), v_gen, 'cambiar123');
    insert into public.embajadores(nombre, apellido, dni, ig, contacto, banco, email, comision_pct, activo, es_ba, pass_hash, pass_claro)
    values (btrim(p_nombre), nullif(btrim(coalesce(p_apellido,'')),''),
            nullif(regexp_replace(coalesce(p_dni,''),'[^0-9]','','g'),''),
            nullif(public.normalizar_ig(coalesce(p_ig,'')),''),
            nullif(btrim(coalesce(p_contacto,'')),''), nullif(btrim(coalesce(p_banco,'')),''),
            v_email, coalesce(p_comision_pct,20), true, true,
            crypt(v_plain, gen_salt('bf')), v_plain)
    returning id into v_id;
  else
    v_id := p_id;
    update public.embajadores set
      nombre=btrim(p_nombre), apellido=nullif(btrim(coalesce(p_apellido,'')),''),
      dni=nullif(regexp_replace(coalesce(p_dni,''),'[^0-9]','','g'),''),
      ig=nullif(public.normalizar_ig(coalesce(p_ig,'')),''),
      contacto=nullif(btrim(coalesce(p_contacto,'')),''), banco=nullif(btrim(coalesce(p_banco,'')),''),
      email=v_email, comision_pct=coalesce(p_comision_pct,20), es_ba=true
    where id=v_id;
    if nullif(btrim(coalesce(p_pass,'')),'') is not null then
      update public.embajadores set pass_hash=crypt(btrim(p_pass), gen_salt('bf')), pass_claro=btrim(p_pass) where id=v_id;
    end if;
  end if;
  return json_build_object('ok',true,'id',v_id,'pass_generada',v_gen);
end $function$;

-- ---------------------------------------------------------------------
create or replace function public.ba_admin_reset_pass(p_pin text, p_id bigint)
returns json language plpgsql security definer set search_path to 'public','extensions' as $function$
declare v_gen text;
begin
  if not public._is_admin(p_pin) then return json_build_object('ok',false,'mensaje','Necesitás el PIN de admin.'); end if;
  v_gen := upper(substr(replace(gen_random_uuid()::text,'-',''),1,8));
  update public.embajadores set pass_hash = crypt(v_gen, gen_salt('bf')), pass_claro = v_gen where id = p_id;
  delete from public.embajador_sesion where embajador_id = p_id;
  return json_build_object('ok',true,'pass_generada',v_gen);
end $function$;

-- ---------------------------------------------------------------------
create or replace function public.ba_admin_get(p_pin text, p_id bigint, p_desde date, p_hasta date)
returns json language plpgsql security definer set search_path to 'public' as $function$
declare v_perfil json; v_mesas json; v_prev json; v_pct numeric; v_tm numeric; v_tp numeric;
begin
  if not public._is_admin(p_pin) then return json_build_object('ok',false,'mensaje','Necesitás el PIN de admin.'); end if;
  select coalesce(comision_pct,20) into v_pct from public.embajadores where id=p_id;
  select json_build_object('id',id,'nombre',nombre,'apellido',coalesce(apellido,''),
           'dni',coalesce(dni,''),'ig',coalesce(ig,''),'contacto',coalesce(contacto,''),
           'banco',coalesce(banco,''),'email',coalesce(email,''),'comision_pct',coalesce(comision_pct,20),
           'pass_claro',coalesce(pass_claro,''),
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

-- ---------------------------------------------------------------------
create or replace function public.ba_resumen(p_token text, p_desde date, p_hasta date)
returns json language plpgsql security definer set search_path to 'public' as $function$
declare v_me bigint; v_pct numeric; v_mesas json; v_prev json;
        v_tot_m numeric; v_tot_p numeric; v_inv int; v_inv_listas int;
begin
  v_me := public._ba(p_token);
  if v_me is null then return json_build_object('ok',false,'mensaje','Sesión vencida. Ingresá de nuevo.'); end if;
  select coalesce(comision_pct,20) into v_pct from public.embajadores where id=v_me;

  select coalesce(json_agg(json_build_object(
      'fecha', to_char(n.fecha,'YYYY-MM-DD'), 'mesa', c.nombre, 'categoria', coalesce(c.categoria,''),
      'monto', coalesce(n.monto,0), 'comision', round(coalesce(n.monto,0)*v_pct/100)
    ) order by n.fecha),'[]'::json),
    coalesce(sum(coalesce(n.monto,0)),0)
    into v_mesas, v_tot_m
  from public.mesas_noche n join public.mesas_config c on c.id=n.mesa_id
  where n.embajador_id=v_me and coalesce(n.titular,'')<>'' and n.fecha between p_desde and p_hasta;

  select coalesce(json_agg(json_build_object(
      'fecha', to_char(p.fecha,'YYYY-MM-DD'), 'titular', p.titular, 'pax', coalesce(p.pax,0),
      'monto', coalesce(p.monto,0), 'comision', round(coalesce(p.monto,0)*v_pct/100)
    ) order by p.fecha),'[]'::json),
    coalesce(sum(coalesce(p.monto,0)),0),
    coalesce(sum(coalesce(p.pax,0)),0)
    into v_prev, v_tot_p, v_inv
  from public.previas p
  where p.embajador_id=v_me and p.fecha between p_desde and p_hasta;

  select count(*) into v_inv_listas
  from public.listas_noche
  where embajador_id=v_me and fecha between p_desde and p_hasta;

  return json_build_object('ok',true,'comision_pct',v_pct,
    'desde',to_char(p_desde,'YYYY-MM-DD'),'hasta',to_char(p_hasta,'YYYY-MM-DD'),
    'mesas',v_mesas,'previas',v_prev,
    'total_mesas',v_tot_m,'total_previas',v_tot_p,'total_vendido',v_tot_m+v_tot_p,
    'comision_total', round((v_tot_m+v_tot_p)*v_pct/100),
    'invitados_previa', v_inv, 'invitados_total', v_inv_listas);
end $function$;

-- ---------------------------------------------------------------------
notify pgrst, 'reload schema';

select 'ok' as estado, count(*) filter (where pass_claro is not null) as con_pass_legible
from public.embajadores;
