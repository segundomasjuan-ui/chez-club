-- =====================================================================
--  CHEZ CLUB · Separar "Influencer fijo" de "Brand Ambassador"
--  - Marca explícita es_ba en embajadores (true = vendedor con portal)
--  - Influencer fijo  = es_ba=false (ej. Sol Cánovas)
--  - Brand Ambassador = es_ba=true  (los del portal /brandambassadors)
--  - Los invitados que carga un BA pasan a ser "Invitados" (tipo fija)
--  - Buscador muestra el beneficio (10 entradas · 5 consumiciones)
--  Idempotente.
-- =====================================================================

-- 1) Marca + backfill ---------------------------------------------------
alter table public.embajadores add column if not exists es_ba boolean not null default false;
-- Los que ya tienen portal (email/clave) son Brand Ambassadors:
update public.embajadores set es_ba=true where (email is not null or pass_hash is not null) and es_ba=false;
-- Invitados cargados por un BA: eran 'influencer', pasan a 'fija' (Invitados):
update public.listas_noche set tipo='fija' where embajador_id is not null and tipo='influencer';

-- 2) Beneficio editable desde config -----------------------------------
insert into public.config(clave,valor) values ('beneficio_fijo','10 entradas · 5 consumiciones')
on conflict (clave) do nothing;

-- 3) Alta de BA marca es_ba=true ---------------------------------------
create or replace function public.ba_admin_upsert(
  p_pin text, p_id bigint, p_nombre text, p_apellido text, p_dni text, p_ig text,
  p_contacto text, p_banco text, p_email text, p_comision_pct numeric, p_pass text)
returns json language plpgsql security definer set search_path to 'public','extensions' as $function$
declare v_id bigint; v_gen text := null; v_email text;
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
    insert into public.embajadores(nombre, apellido, dni, ig, contacto, banco, email, comision_pct, activo, es_ba, pass_hash)
    values (btrim(p_nombre), nullif(btrim(coalesce(p_apellido,'')),''),
            nullif(regexp_replace(coalesce(p_dni,''),'[^0-9]','','g'),''),
            nullif(public.normalizar_ig(coalesce(p_ig,'')),''),
            nullif(btrim(coalesce(p_contacto,'')),''), nullif(btrim(coalesce(p_banco,'')),''),
            v_email, coalesce(p_comision_pct,20), true, true,
            crypt(coalesce(nullif(btrim(p_pass,''),''), v_gen, 'cambiar123'), gen_salt('bf')))
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
      update public.embajadores set pass_hash=crypt(btrim(p_pass), gen_salt('bf')) where id=v_id;
    end if;
  end if;
  return json_build_object('ok',true,'id',v_id,'pass_generada',v_gen);
end $function$;

-- 4) Invitados del BA se cargan como 'fija' (Invitados) -----------------
create or replace function public.ba_add_guests(p_token text, p_fecha date, p_items jsonb)
returns json language plpgsql security definer set search_path to 'public' as $function$
declare v_me bigint; el jsonb; v_nombre text; v_dni text; v_ord int; v_n int := 0;
begin
  v_me := public._ba(p_token);
  if v_me is null then return json_build_object('ok',false,'mensaje','Sesión vencida. Ingresá de nuevo.'); end if;
  select coalesce(max(orden),0) into v_ord from public.listas_noche where fecha=p_fecha and tipo='fija';
  for el in select * from jsonb_array_elements(coalesce(p_items,'[]'::jsonb)) loop
    v_nombre := btrim(coalesce(el->>'nombre',''));
    v_dni := regexp_replace(coalesce(el->>'dni',''),'[^0-9]','','g');
    if length(v_nombre) >= 2 then
      v_ord := v_ord + 1; v_n := v_n + 1;
      insert into public.listas_noche(fecha, tipo, nombre, dni, orden, embajador_id)
      values (p_fecha, 'fija', v_nombre, nullif(v_dni,''), v_ord, v_me);
    end if;
  end loop;
  return json_build_object('ok',true,'agregados',v_n);
end $function$;

-- 5) Casilla de puerta: SOLO Brand Ambassadors (es_ba) + beneficio ------
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
        from public.listas_noche l where l.fecha=p_fecha and l.embajador_id=e.id),
      'total', (select count(*) from public.listas_noche l where l.fecha=p_fecha and l.embajador_id=e.id),
      'ingresados', (select count(*) from public.listas_noche l where l.fecha=p_fecha and l.embajador_id=e.id and l.llegada is not null)
    ) order by lower(e.nombre)),'[]'::json) into v
  from public.embajadores e
  left join public.embajador_noche en on en.embajador_id=e.id and en.fecha=p_fecha
  where coalesce(e.activo,true) and coalesce(e.es_ba,false);
  return json_build_object('ok',true,'lista',v,'beneficio',coalesce(public.cfg('beneficio_fijo'),'10 entradas · 5 consumiciones'));
end $function$;

-- 6) Lista de Influencers: fijos = SOLO Influencer fijo (no es_ba) ------
create or replace function public.get_lista_simple(p_pin text, p_fecha date, p_tipo text)
returns json language plpgsql security definer set search_path to 'public' as $function$
declare v_lista json;
begin
  if not public._is_staff(p_pin) then return json_build_object('ok',false,'mensaje','PIN incorrecto.'); end if;
  if p_tipo = 'influencer' then
    select coalesce(json_agg(json_build_object(
             'id',x.id,'amb_id',x.amb_id,'fijo',x.fijo,'nombre',x.nombre,'dni',x.dni,'ig',x.ig,
             'limite','','llego',x.llego,'hora',x.hora,'vencido',false) order by lower(x.nombre)),'[]'::json) into v_lista
    from (
      select l.id, null::bigint as amb_id, false as fijo, l.nombre, coalesce(l.dni,'') dni, coalesce(l.ig,'') ig,
             (l.llegada is not null) as llego, coalesce(l.llegada,'') as hora
      from public.listas_noche l where l.fecha=p_fecha and l.tipo='influencer'
      union all
      select null::bigint, e.id, true, e.nombre, coalesce(e.dni,''), coalesce(e.ig,''),
             (en.llegada is not null), coalesce(en.llegada,'')
      from public.embajadores e
      left join public.embajador_noche en on en.embajador_id=e.id and en.fecha=p_fecha
      where coalesce(e.activo,true) and not coalesce(e.es_ba,false)
    ) x;
  else
    select coalesce(json_agg(json_build_object(
             'id',id,'amb_id',null,'fijo',false,'nombre',nombre,'dni',coalesce(dni,''),'ig',coalesce(ig,''),
             'limite',coalesce(limite,''),'llego',(llegada is not null),'hora',coalesce(llegada,''),
             'vencido', public.esta_vencido(p_fecha, limite, (llegada is not null))) order by lower(nombre)),'[]'::json) into v_lista
    from public.listas_noche where fecha=p_fecha and tipo=p_tipo;
  end if;
  return json_build_object('ok',true,'lista',v_lista,'leyenda',coalesce(public.cfg('leyenda_'||p_tipo),''));
end $function$;

-- 7) Buscador (get_noche_completa): etiqueta + beneficio por tipo ------
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
    select 'embajador', e.id, e.nombre, coalesce(e.dni,''),
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

-- 8) buscar_global (por si el admin lo usa): misma etiqueta + beneficio -
create or replace function public.buscar_global(p_pin text, p_fecha date, p_q text)
returns json language plpgsql security definer set search_path to 'public' as $function$
declare v_q text; v_dni text; v_benef text; v json;
begin
  if not public._is_staff(p_pin) then return json_build_object('ok',false,'mensaje','PIN incorrecto.'); end if;
  v_q := btrim(coalesce(p_q,''));
  if length(v_q) < 2 then return json_build_object('ok',true,'resultados','[]'::json); end if;
  v_dni := regexp_replace(v_q,'[^0-9]','','g');
  v_benef := coalesce(public.cfg('beneficio_fijo'),'10 entradas · 5 consumiciones');
  with matches as (
    select 'hm' as kind, r.id::bigint as id, r.nombre as nombre, coalesce(r.dni,'') as dni,
           ('House Member'|| case when coalesce(r.cantidad,1)>1 then ' · '||r.cantidad||' personas' else '' end) as detalle,
           (r.ingreso is not null and r.ingreso<>'') as llego, coalesce(r.ingreso,'') as hora, 1 as ord
    from public.rsvp r
    where r.fecha=p_fecha and upper(r.estado)='CONFIRMADO'
      and ( r.nombre ilike '%'||v_q||'%' or (length(v_dni)>=6 and coalesce(r.dni,'') like '%'||v_dni||'%') )
    union all
    select 'lista', l.id, l.nombre, coalesce(l.dni,''),
           (case l.tipo when 'fija' then 'Invitado' when 'influencer' then 'Influencer' else l.tipo end),
           (l.llegada is not null), coalesce(l.llegada,''), 2
    from public.listas_noche l
    where l.fecha=p_fecha and l.tipo in ('fija','influencer')
      and ( l.nombre ilike '%'||v_q||'%' or (length(v_dni)>=6 and coalesce(l.dni,'') like '%'||v_dni||'%') )
    union all
    select 'embajador', e.id, e.nombre, coalesce(e.dni,''),
           (case when coalesce(e.es_ba,false) then 'Brand Ambassador · ' else 'Influencer fijo · ' end)||v_benef,
           (en.llegada is not null), coalesce(en.llegada,''), 2
    from public.embajadores e
    left join public.embajador_noche en on en.embajador_id=e.id and en.fecha=p_fecha
    where coalesce(e.activo,true)
      and ( e.nombre ilike '%'||v_q||'%' or (length(v_dni)>=6 and coalesce(e.dni,'') like '%'||v_dni||'%') )
    union all
    select 'previa', i.id, i.nombre, coalesce(i.dni,''),
           ('Previa · '||p.titular), (i.llegada is not null), coalesce(i.llegada,''), 3
    from public.previa_invitados i join public.previas p on p.id=i.previa_id
    where p.fecha=p_fecha
      and ( i.nombre ilike '%'||v_q||'%' or (length(v_dni)>=6 and coalesce(i.dni,'') like '%'||v_dni||'%') )
    union all
    select 'mesa', n.mesa_id, n.titular, coalesce(n.contacto,''),
           ('Mesa '||c.nombre|| case when coalesce(n.personas,0)>0 then ' · '||n.personas||' personas' else '' end),
           (n.llegada is not null), coalesce(n.llegada,''), 4
    from public.mesas_noche n join public.mesas_config c on c.id=n.mesa_id
    where n.fecha=p_fecha and coalesce(n.titular,'')<>''
      and n.titular ilike '%'||v_q||'%'
  )
  select coalesce(json_agg(json_build_object(
    'kind',kind,'id',id,'nombre',nombre,'dni',dni,'detalle',detalle,'llego',llego,'hora',hora
  ) order by ord, lower(nombre)),'[]'::json) into v from matches;
  return json_build_object('ok',true,'resultados',v);
end $function$;

-- 9) Totales: Influencers = fijos NO-BA; agrega bloque 'ba' -------------
create or replace function public.get_totales_noche(p_pin text, p_fecha date)
returns json language plpgsql security definer set search_path to 'public' as $function$
declare hm_t int; hm_i int; inv_t int; inv_i int; infl_t int; infl_i int;
        prev_t int; prev_i int; mesas_t int; mesas_i int;
        embf_t int; embf_i int; ba_t int; ba_i int;
begin
  if not public._is_staff(p_pin) then return json_build_object('ok',false,'mensaje','PIN incorrecto.'); end if;
  select coalesce(sum(cantidad),0), coalesce(sum(cantidad) filter (where ingreso is not null and ingreso<>''),0)
    into hm_t, hm_i from public.rsvp where fecha=p_fecha and upper(estado)='CONFIRMADO';
  select coalesce(count(*),0), coalesce(count(*) filter (where llegada is not null and llegada<>''),0)
    into inv_t, inv_i from public.listas_noche where fecha=p_fecha and tipo='fija';
  select coalesce(count(*),0), coalesce(count(*) filter (where llegada is not null and llegada<>''),0)
    into infl_t, infl_i from public.listas_noche where fecha=p_fecha and tipo='influencer';
  -- Influencer fijo (no es_ba)
  select coalesce(count(*),0) into embf_t from public.embajadores where coalesce(activo,true) and not coalesce(es_ba,false);
  select coalesce(count(*),0) into embf_i from public.embajadores e
    join public.embajador_noche en on en.embajador_id=e.id and en.fecha=p_fecha
    where coalesce(e.activo,true) and not coalesce(e.es_ba,false) and en.llegada is not null and en.llegada<>'';
  -- Brand Ambassadors (es_ba)
  select coalesce(count(*),0) into ba_t from public.embajadores where coalesce(activo,true) and coalesce(es_ba,false);
  select coalesce(count(*),0) into ba_i from public.embajadores e
    join public.embajador_noche en on en.embajador_id=e.id and en.fecha=p_fecha
    where coalesce(e.activo,true) and coalesce(e.es_ba,false) and en.llegada is not null and en.llegada<>'';
  select coalesce(count(*),0), coalesce(count(*) filter (where i.llegada is not null),0)
    into prev_t, prev_i from public.previa_invitados i join public.previas p on p.id=i.previa_id where p.fecha=p_fecha;
  select coalesce(sum(coalesce(personas,0)) filter (where coalesce(titular,'')<>''),0),
         coalesce(sum(coalesce(personas,0)) filter (where coalesce(titular,'')<>'' and llegada is not null and llegada<>''),0)
    into mesas_t, mesas_i from public.mesas_noche where fecha=p_fecha;
  infl_t := infl_t + embf_t; infl_i := infl_i + embf_i;
  return json_build_object('ok',true,
    'grand',       json_build_object('total', hm_t+inv_t+infl_t+ba_t+prev_t+mesas_t, 'ingresos', hm_i+inv_i+infl_i+ba_i+prev_i+mesas_i),
    'hm',          json_build_object('total', hm_t,    'ingresos', hm_i),
    'invitados',   json_build_object('total', inv_t,   'ingresos', inv_i),
    'influencers', json_build_object('total', infl_t,  'ingresos', infl_i),
    'ba',          json_build_object('total', ba_t,    'ingresos', ba_i),
    'previa',      json_build_object('total', prev_t,  'ingresos', prev_i),
    'mesas',       json_build_object('total', mesas_t, 'ingresos', mesas_i));
end $function$;

-- 10) Resumen: Influencers no cuenta BA; agrega 'ba' -------------------
create or replace function public.get_resumen_noche(p_pin text, p_fecha date)
returns json language plpgsql security definer set search_path to 'public' as $function$
declare
  m_vend int; m_ing int; m_rec numeric; m_pers int;
  p_cant int; p_rec numeric; p_inv int; p_ing int;
  hm_i int; inv_i int; infl_i int; prev_i int; mesas_pi int; embf_i int; ba_i int;
begin
  if not public._is_staff(p_pin) then return json_build_object('ok',false,'mensaje','PIN incorrecto.'); end if;
  select coalesce(count(*) filter (where coalesce(n.titular,'')<>''),0),
         coalesce(count(*) filter (where n.llegada is not null and n.llegada<>''),0),
         coalesce(sum(nullif(regexp_replace(coalesce(c.precio,''),'[^0-9]','','g'),'')::numeric)
                  filter (where coalesce(n.titular,'')<>''),0),
         coalesce(sum(coalesce(n.personas,0)) filter (where coalesce(n.titular,'')<>''),0)
    into m_vend, m_ing, m_rec, m_pers
  from public.mesas_noche n join public.mesas_config c on c.id=n.mesa_id where n.fecha=p_fecha;
  select coalesce(count(*),0), coalesce(sum(coalesce(monto,0)),0) into p_cant, p_rec from public.previas where fecha=p_fecha;
  select coalesce(count(*),0), coalesce(count(*) filter (where i.llegada is not null),0)
    into p_inv, p_ing from public.previa_invitados i join public.previas p on p.id=i.previa_id where p.fecha=p_fecha;
  select coalesce(sum(cantidad) filter (where ingreso is not null and ingreso<>''),0)
    into hm_i from public.rsvp where fecha=p_fecha and upper(estado)='CONFIRMADO';
  select coalesce(count(*) filter (where llegada is not null and llegada<>''),0)
    into inv_i from public.listas_noche where fecha=p_fecha and tipo='fija';
  select coalesce(count(*) filter (where llegada is not null and llegada<>''),0)
    into infl_i from public.listas_noche where fecha=p_fecha and tipo='influencer';
  select coalesce(count(*),0) into embf_i from public.embajadores e
    join public.embajador_noche en on en.embajador_id=e.id and en.fecha=p_fecha
    where coalesce(e.activo,true) and not coalesce(e.es_ba,false) and en.llegada is not null and en.llegada<>'';
  select coalesce(count(*),0) into ba_i from public.embajadores e
    join public.embajador_noche en on en.embajador_id=e.id and en.fecha=p_fecha
    where coalesce(e.activo,true) and coalesce(e.es_ba,false) and en.llegada is not null and en.llegada<>'';
  select coalesce(sum(coalesce(personas,0)) filter (where coalesce(titular,'')<>'' and llegada is not null and llegada<>''),0)
    into mesas_pi from public.mesas_noche where fecha=p_fecha;
  infl_i := infl_i + embf_i;
  prev_i := p_ing;
  return json_build_object('ok',true,
    'mesas',   json_build_object('vendidas',m_vend,'ingresadas',m_ing,'recaudado',m_rec,'personas',m_pers),
    'previas', json_build_object('cantidad',p_cant,'recaudado',p_rec,'invitados',p_inv,'ingresados',p_ing),
    'ingresos',json_build_object('hm',hm_i,'invitados',inv_i,'influencers',infl_i,'ba',ba_i,'previa',prev_i,'mesas',mesas_pi,
                                 'total', hm_i+inv_i+infl_i+ba_i+prev_i+mesas_pi),
    'plata_total', m_rec + p_rec);
end $function$;

-- 11) Beneficio también para el portal del BA --------------------------
create or replace function public.ba_bootstrap(p_token text)
returns json language plpgsql security definer set search_path to 'public' as $function$
declare v_me bigint; v_desde date; v_hasta date; v_noches json; v_ba json;
begin
  v_me := public._ba(p_token);
  if v_me is null then return json_build_object('ok',false,'mensaje','Sesión vencida. Ingresá de nuevo.'); end if;
  update public.embajador_sesion set ultimo_uso = now() where token = p_token;
  v_desde := (date_trunc('month', (now() at time zone 'America/Argentina/Buenos_Aires')) - interval '1 month')::date;
  v_hasta := (date_trunc('month', (now() at time zone 'America/Argentina/Buenos_Aires')) + interval '2 month' - interval '1 day')::date;
  select coalesce(json_agg(json_build_object(
      'fecha', to_char(x.fecha,'YYYY-MM-DD'), 'nombre', coalesce(x.nombre,''),
      'abierto', coalesce(x.abierto,false), 'cupo', coalesce(x.cupo,0),
      'mis_invitados', (select count(*) from public.listas_noche l where l.fecha=x.fecha and l.embajador_id=v_me),
      'mis_mesas',     (select count(*) from public.mesas_noche m where m.fecha=x.fecha and m.embajador_id=v_me and coalesce(m.titular,'')<>''),
      'mis_previas',   (select count(*) from public.previas pr where pr.fecha=x.fecha and pr.embajador_id=v_me),
      'libres',        (select count(*) from public.mesas_config c
                         left join public.mesas_noche m on m.mesa_id=c.id and m.fecha=x.fecha
                         where coalesce(c.activo,true) and coalesce(m.titular,'')='')
    ) order by x.fecha),'[]'::json) into v_noches
  from public.noches x where x.fecha between v_desde and v_hasta;
  select json_build_object('id',id,'nombre',nombre,'apellido',coalesce(apellido,''),
           'comision_pct',coalesce(comision_pct,20),'email',coalesce(email,'')) into v_ba
    from public.embajadores where id = v_me;
  return json_build_object('ok',true,'ba',v_ba,'noches',v_noches,
    'beneficio', coalesce(public.cfg('beneficio_fijo'),'10 entradas · 5 consumiciones'),
    'hoy', to_char((now() at time zone 'America/Argentina/Buenos_Aires')::date,'YYYY-MM-DD'));
end $function$;

-- =====================================================================
notify pgrst, 'reload schema';
