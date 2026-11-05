-- =====================================================================
--  CHEZ CLUB · BRAND AMBASSADORS · Migración Parte 1
--  - Extiende la tabla embajadores (perfil de vendedor)
--  - Agrega atribución (embajador_id) a mesas / listas / previas
--  - Login propio con token de sesión (contraseña hasheada bcrypt)
--  - RPCs ba_*  (app del embajador)  y  ba_admin_*  (CRM de Paula)
--  - Generador de pagos mensuales (la programación pg_cron va en Parte 3)
--  Idempotente: se puede correr más de una vez sin romper nada.
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- 1) PERFIL DEL EMBAJADOR  (extiende la tabla que ya existe)
-- ---------------------------------------------------------------------
alter table public.embajadores add column if not exists apellido     text;
alter table public.embajadores add column if not exists contacto     text;
alter table public.embajadores add column if not exists banco        text;   -- alias / CBU
alter table public.embajadores add column if not exists email        text;   -- usuario de login
alter table public.embajadores add column if not exists pass_hash    text;   -- bcrypt
alter table public.embajadores add column if not exists comision_pct numeric not null default 20;
alter table public.embajadores add column if not exists creado       timestamptz not null default now();

create unique index if not exists embajadores_email_uq
  on public.embajadores (lower(email)) where email is not null;

-- Sesiones de los embajadores (un token por login)
create table if not exists public.embajador_sesion (
  token        text primary key,
  embajador_id bigint not null references public.embajadores(id) on delete cascade,
  creado       timestamptz not null default now(),
  ultimo_uso   timestamptz not null default now()
);
create index if not exists embajador_sesion_emb_idx on public.embajador_sesion(embajador_id);

-- Notas de contacto por cliente (CRM del propio embajador)
create table if not exists public.embajador_cliente (
  embajador_id bigint not null references public.embajadores(id) on delete cascade,
  dni          text   not null,
  tel          text,
  ig           text,
  nota         text,
  primary key (embajador_id, dni)
);

-- ---------------------------------------------------------------------
-- 2) ATRIBUCIÓN DE VENTAS  (columnas nuevas, todas NULL -> no rompen nada)
-- ---------------------------------------------------------------------
alter table public.mesas_noche add column if not exists embajador_id     bigint references public.embajadores(id);
alter table public.mesas_noche add column if not exists monto            numeric;         -- lo que se vendió (para comisión)
alter table public.mesas_noche add column if not exists comprobante_url  text;
alter table public.mesas_noche add column if not exists comprobante_nombre text;

alter table public.listas_noche add column if not exists embajador_id bigint references public.embajadores(id);

alter table public.previas add column if not exists embajador_id bigint references public.embajadores(id);
alter table public.previas add column if not exists pax          int;

create index if not exists mesas_noche_emb_idx  on public.mesas_noche(embajador_id);
create index if not exists listas_noche_emb_idx on public.listas_noche(embajador_id);
create index if not exists previas_emb_idx      on public.previas(embajador_id);

-- ---------------------------------------------------------------------
-- 3) HELPER: valida token -> devuelve embajador_id (o NULL)
-- ---------------------------------------------------------------------
create or replace function public._ba(p_token text)
returns bigint language sql stable security definer set search_path to 'public' as $$
  select s.embajador_id
  from public.embajador_sesion s
  join public.embajadores e on e.id = s.embajador_id
  where s.token = p_token and coalesce(e.activo,true)
$$;

-- ---------------------------------------------------------------------
-- 4) LOGIN / LOGOUT del embajador
-- ---------------------------------------------------------------------
create or replace function public.ba_login(p_email text, p_pass text)
returns json language plpgsql security definer set search_path to 'public','extensions' as $function$
declare v_id bigint; v_hash text; v_tok text; v_nombre text; v_ape text; v_pct numeric;
begin
  select id, pass_hash, nombre, coalesce(apellido,''), coalesce(comision_pct,20)
    into v_id, v_hash, v_nombre, v_ape, v_pct
  from public.embajadores
  where lower(email) = lower(btrim(coalesce(p_email,''))) and coalesce(activo,true);

  if v_id is null or v_hash is null or v_hash <> crypt(coalesce(p_pass,''), v_hash) then
    return json_build_object('ok',false,'mensaje','Usuario o contraseña incorrectos.');
  end if;

  v_tok := replace(gen_random_uuid()::text,'-','') || replace(gen_random_uuid()::text,'-','');
  insert into public.embajador_sesion(token, embajador_id) values (v_tok, v_id);
  delete from public.embajador_sesion where embajador_id = v_id and creado < now() - interval '60 days';

  return json_build_object('ok',true,'token',v_tok,
    'ba', json_build_object('id',v_id,'nombre',v_nombre,'apellido',v_ape,'comision_pct',v_pct));
end $function$;

create or replace function public.ba_logout(p_token text)
returns json language plpgsql security definer set search_path to 'public' as $function$
begin
  delete from public.embajador_sesion where token = p_token;
  return json_build_object('ok',true);
end $function$;

-- ---------------------------------------------------------------------
-- 5) BOOTSTRAP: perfil + calendario (ventana de fechas con mis conteos)
-- ---------------------------------------------------------------------
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
      'fecha', to_char(x.fecha,'YYYY-MM-DD'),
      'nombre', coalesce(x.nombre,''),
      'abierto', coalesce(x.abierto,false),
      'cupo', coalesce(x.cupo,0),
      'mis_invitados', (select count(*) from public.listas_noche l where l.fecha=x.fecha and l.embajador_id=v_me),
      'mis_mesas',     (select count(*) from public.mesas_noche m where m.fecha=x.fecha and m.embajador_id=v_me and coalesce(m.titular,'')<>''),
      'mis_previas',   (select count(*) from public.previas pr where pr.fecha=x.fecha and pr.embajador_id=v_me),
      'libres',        (select count(*) from public.mesas_config c
                         left join public.mesas_noche m on m.mesa_id=c.id and m.fecha=x.fecha
                         where coalesce(c.activo,true) and coalesce(m.titular,'')='')
    ) order by x.fecha),'[]'::json) into v_noches
  from public.noches x
  where x.fecha between v_desde and v_hasta;

  select json_build_object('id',id,'nombre',nombre,'apellido',coalesce(apellido,''),
           'comision_pct',coalesce(comision_pct,20),'email',coalesce(email,''))
    into v_ba from public.embajadores where id = v_me;

  return json_build_object('ok',true,'ba',v_ba,'noches',v_noches,
    'hoy', to_char((now() at time zone 'America/Argentina/Buenos_Aires')::date,'YYYY-MM-DD'));
end $function$;

-- ---------------------------------------------------------------------
-- 6) DETALLE DE UNA NOCHE (mesas + mi lista + mis previas)
-- ---------------------------------------------------------------------
create or replace function public.ba_noche(p_token text, p_fecha date)
returns json language plpgsql security definer set search_path to 'public' as $function$
declare v_me bigint; v_mesas json; v_inv json; v_prev json; v_nombre text; v_abierto boolean;
begin
  v_me := public._ba(p_token);
  if v_me is null then return json_build_object('ok',false,'mensaje','Sesión vencida. Ingresá de nuevo.'); end if;

  select nombre, coalesce(abierto,false) into v_nombre, v_abierto from public.noches where fecha = p_fecha;

  select coalesce(json_agg(json_build_object(
      'mesa_id', c.id, 'nombre', c.nombre, 'categoria', coalesce(c.categoria,''),
      'precio', coalesce(c.precio,''),
      'precio_sug', nullif(regexp_replace(coalesce(c.precio,''),'[^0-9]','','g'),'')::numeric,
      'titular', coalesce(n.titular,''), 'contacto', coalesce(n.contacto,''),
      'personas', coalesce(n.personas,0), 'monto', n.monto,
      'estado', coalesce(nullif(n.estado,''),'Libre'),
      'mia', (n.embajador_id = v_me),
      'tomada', (coalesce(n.titular,'')<>''),
      'llego', (n.llegada is not null),
      'comp_url', coalesce(n.comprobante_url,''), 'comp_nombre', coalesce(n.comprobante_nombre,'')
    ) order by c.orden),'[]'::json) into v_mesas
  from public.mesas_config c
  left join public.mesas_noche n on n.mesa_id = c.id and n.fecha = p_fecha
  where coalesce(c.activo,true);

  select coalesce(json_agg(json_build_object(
      'id', id, 'nombre', nombre, 'dni', coalesce(dni,''), 'llego', (llegada is not null)
    ) order by lower(nombre)),'[]'::json) into v_inv
  from public.listas_noche
  where fecha = p_fecha and embajador_id = v_me;

  select coalesce(json_agg(json_build_object(
      'id', p.id, 'titular', p.titular, 'dni', coalesce(p.titular_dni,''),
      'monto', coalesce(p.monto,0), 'pax', coalesce(p.pax,0)
    ) order by p.creado),'[]'::json) into v_prev
  from public.previas p
  where p.fecha = p_fecha and p.embajador_id = v_me;

  return json_build_object('ok',true,'nombre_noche',coalesce(v_nombre,''),'abierto',v_abierto,
    'mesas',v_mesas,'invitados',v_inv,'previas',v_prev);
end $function$;

-- ---------------------------------------------------------------------
-- 7) MESAS: vender / liberar / comprobante
-- ---------------------------------------------------------------------
create or replace function public.ba_vender_mesa(
  p_token text, p_fecha date, p_mesa_id bigint,
  p_titular text, p_contacto text, p_personas integer, p_monto numeric)
returns json language plpgsql security definer set search_path to 'public' as $function$
declare v_me bigint; v_tit text; v_emb bigint;
begin
  v_me := public._ba(p_token);
  if v_me is null then return json_build_object('ok',false,'mensaje','Sesión vencida. Ingresá de nuevo.'); end if;
  if length(btrim(coalesce(p_titular,''))) < 2 then return json_build_object('ok',false,'mensaje','Falta el titular de la mesa.'); end if;

  select titular, embajador_id into v_tit, v_emb from public.mesas_noche where fecha=p_fecha and mesa_id=p_mesa_id;
  if coalesce(v_tit,'')<>'' and (v_emb is distinct from v_me) then
    return json_build_object('ok',false,'mensaje','Esa mesa ya está vendida.');
  end if;

  insert into public.mesas_noche(fecha, mesa_id, titular, contacto, personas, monto, estado, embajador_id)
  values (p_fecha, p_mesa_id, btrim(p_titular), btrim(coalesce(p_contacto,'')),
          nullif(coalesce(p_personas,0),0), nullif(coalesce(p_monto,0),0), 'Reservada', v_me)
  on conflict (fecha, mesa_id) do update set
    titular = excluded.titular, contacto = excluded.contacto, personas = excluded.personas,
    monto = excluded.monto, estado = 'Reservada', embajador_id = v_me;

  return json_build_object('ok',true);
end $function$;

create or replace function public.ba_liberar_mesa(p_token text, p_fecha date, p_mesa_id bigint)
returns json language plpgsql security definer set search_path to 'public' as $function$
declare v_me bigint; v_emb bigint;
begin
  v_me := public._ba(p_token);
  if v_me is null then return json_build_object('ok',false,'mensaje','Sesión vencida. Ingresá de nuevo.'); end if;
  select embajador_id into v_emb from public.mesas_noche where fecha=p_fecha and mesa_id=p_mesa_id;
  if v_emb is distinct from v_me then return json_build_object('ok',false,'mensaje','Esa mesa no es tuya.'); end if;

  update public.mesas_noche
    set titular='', contacto='', personas=null, monto=null, estado='Libre',
        embajador_id=null, comprobante_url=null, comprobante_nombre=null
    where fecha=p_fecha and mesa_id=p_mesa_id;
  return json_build_object('ok',true);
end $function$;

create or replace function public.ba_set_comprobante(
  p_token text, p_fecha date, p_mesa_id bigint, p_url text, p_nombre text)
returns json language plpgsql security definer set search_path to 'public' as $function$
declare v_me bigint; v_emb bigint;
begin
  v_me := public._ba(p_token);
  if v_me is null then return json_build_object('ok',false,'mensaje','Sesión vencida. Ingresá de nuevo.'); end if;
  select embajador_id into v_emb from public.mesas_noche where fecha=p_fecha and mesa_id=p_mesa_id;
  if v_emb is distinct from v_me then return json_build_object('ok',false,'mensaje','Esa mesa no es tuya.'); end if;

  update public.mesas_noche
    set comprobante_url = nullif(btrim(coalesce(p_url,'')),''),
        comprobante_nombre = nullif(btrim(coalesce(p_nombre,'')),'')
    where fecha=p_fecha and mesa_id=p_mesa_id;
  return json_build_object('ok',true);
end $function$;

-- ---------------------------------------------------------------------
-- 8) LISTA DE INVITADOS del embajador  (van a listas_noche tipo influencer)
-- ---------------------------------------------------------------------
create or replace function public.ba_add_guests(p_token text, p_fecha date, p_items jsonb)
returns json language plpgsql security definer set search_path to 'public' as $function$
declare v_me bigint; el jsonb; v_nombre text; v_dni text; v_ord int; v_n int := 0;
begin
  v_me := public._ba(p_token);
  if v_me is null then return json_build_object('ok',false,'mensaje','Sesión vencida. Ingresá de nuevo.'); end if;
  select coalesce(max(orden),0) into v_ord from public.listas_noche where fecha=p_fecha and tipo='influencer';
  for el in select * from jsonb_array_elements(coalesce(p_items,'[]'::jsonb)) loop
    v_nombre := btrim(coalesce(el->>'nombre',''));
    v_dni := regexp_replace(coalesce(el->>'dni',''),'[^0-9]','','g');
    if length(v_nombre) >= 2 then
      v_ord := v_ord + 1; v_n := v_n + 1;
      insert into public.listas_noche(fecha, tipo, nombre, dni, orden, embajador_id)
      values (p_fecha, 'influencer', v_nombre, nullif(v_dni,''), v_ord, v_me);
    end if;
  end loop;
  return json_build_object('ok',true,'agregados',v_n);
end $function$;

create or replace function public.ba_quitar_guest(p_token text, p_id bigint)
returns json language plpgsql security definer set search_path to 'public' as $function$
declare v_me bigint;
begin
  v_me := public._ba(p_token);
  if v_me is null then return json_build_object('ok',false,'mensaje','Sesión vencida. Ingresá de nuevo.'); end if;
  delete from public.listas_noche where id=p_id and embajador_id=v_me;
  return json_build_object('ok',true);
end $function$;

-- ---------------------------------------------------------------------
-- 9) PREVIAS del embajador  (titular queda buscable en la puerta)
-- ---------------------------------------------------------------------
create or replace function public.ba_add_previa(
  p_token text, p_fecha date, p_titular text, p_dni text, p_monto numeric, p_pax integer)
returns json language plpgsql security definer set search_path to 'public' as $function$
declare v_me bigint; v_id bigint; v_dni text;
begin
  v_me := public._ba(p_token);
  if v_me is null then return json_build_object('ok',false,'mensaje','Sesión vencida. Ingresá de nuevo.'); end if;
  if length(btrim(coalesce(p_titular,''))) < 2 then return json_build_object('ok',false,'mensaje','Falta el titular.'); end if;
  if coalesce(p_pax,0) < 1 then return json_build_object('ok',false,'mensaje','Indicá la cantidad de personas.'); end if;

  v_dni := nullif(regexp_replace(coalesce(p_dni,''),'[^0-9]','','g'),'');
  insert into public.previas(fecha, titular, titular_dni, monto, descripcion, embajador_id, pax)
  values (p_fecha, btrim(p_titular), v_dni, coalesce(p_monto,0), 'Previa', v_me, p_pax)
  returning id into v_id;

  insert into public.previa_invitados(previa_id, nombre, dni, orden)
  values (v_id, btrim(p_titular), v_dni, 0);

  return json_build_object('ok',true,'id',v_id);
end $function$;

create or replace function public.ba_quitar_previa(p_token text, p_id bigint)
returns json language plpgsql security definer set search_path to 'public' as $function$
declare v_me bigint; v_ok bigint;
begin
  v_me := public._ba(p_token);
  if v_me is null then return json_build_object('ok',false,'mensaje','Sesión vencida. Ingresá de nuevo.'); end if;
  select id into v_ok from public.previas where id=p_id and embajador_id=v_me;
  if v_ok is null then return json_build_object('ok',false,'mensaje','Esa previa no es tuya.'); end if;
  delete from public.previa_invitados where previa_id=p_id;
  delete from public.previas where id=p_id;
  return json_build_object('ok',true);
end $function$;

-- ---------------------------------------------------------------------
-- 10) CLIENTES del embajador (cartera) + notas de contacto
-- ---------------------------------------------------------------------
create or replace function public.ba_set_cliente(
  p_token text, p_dni text, p_tel text, p_ig text, p_nota text)
returns json language plpgsql security definer set search_path to 'public' as $function$
declare v_me bigint; v_dni text;
begin
  v_me := public._ba(p_token);
  if v_me is null then return json_build_object('ok',false,'mensaje','Sesión vencida. Ingresá de nuevo.'); end if;
  v_dni := regexp_replace(coalesce(p_dni,''),'[^0-9]','','g');
  if length(v_dni) < 4 then return json_build_object('ok',false,'mensaje','DNI inválido.'); end if;
  insert into public.embajador_cliente(embajador_id, dni, tel, ig, nota)
  values (v_me, v_dni, nullif(btrim(coalesce(p_tel,'')),''), nullif(btrim(coalesce(p_ig,'')),''), nullif(btrim(coalesce(p_nota,'')),''))
  on conflict (embajador_id, dni) do update set tel=excluded.tel, ig=excluded.ig, nota=excluded.nota;
  return json_build_object('ok',true);
end $function$;

create or replace function public.ba_clientes(p_token text)
returns json language plpgsql security definer set search_path to 'public' as $function$
declare v_me bigint; v json;
begin
  v_me := public._ba(p_token);
  if v_me is null then return json_build_object('ok',false,'mensaje','Sesión vencida. Ingresá de nuevo.'); end if;

  with ev as (
    select coalesce(nullif(regexp_replace(coalesce(n.titular,''),'[^0-9]',''), ''), lower(n.titular)) as key,
           n.titular as nombre, '' as dni_raw, n.fecha, 'Mesa' as tipo, coalesce(n.monto,0) as monto,
           ('Mesa '||c.nombre) as detalle
    from public.mesas_noche n join public.mesas_config c on c.id=n.mesa_id
    where n.embajador_id=v_me and coalesce(n.titular,'')<>''
    union all
    select coalesce(nullif(p.titular_dni,''), lower(p.titular)), p.titular, coalesce(p.titular_dni,''), p.fecha, 'Previa', coalesce(p.monto,0),
           ('Previa · '||coalesce(p.pax,0)||' personas')
    from public.previas p where p.embajador_id=v_me
    union all
    select coalesce(nullif(l.dni,''), lower(l.nombre)), l.nombre, coalesce(l.dni,''), l.fecha, 'Lista', 0, 'Lista de invitados'
    from public.listas_noche l where l.embajador_id=v_me
  ),
  agg as (
    select key,
           max(nombre) as nombre,
           max(dni_raw) filter (where dni_raw<>'') as dni,
           count(*) as visitas,
           count(*) filter (where tipo='Mesa') as mesas,
           count(*) filter (where tipo='Previa') as previas,
           count(*) filter (where tipo='Lista') as listas,
           sum(monto) as total,
           max(fecha) as ultima,
           json_agg(json_build_object('fecha',to_char(fecha,'YYYY-MM-DD'),'tipo',tipo,'detalle',detalle,'monto',monto)
                    order by fecha desc) as historial
    from ev group by key
  )
  select coalesce(json_agg(json_build_object(
    'nombre', a.nombre, 'dni', coalesce(a.dni,''),
    'visitas', a.visitas, 'mesas', a.mesas, 'previas', a.previas, 'listas', a.listas,
    'total', a.total, 'ultima', to_char(a.ultima,'YYYY-MM-DD'),
    'tel', coalesce(c.tel,''), 'ig', coalesce(c.ig,''), 'nota', coalesce(c.nota,''),
    'historial', a.historial
  ) order by a.ultima desc, lower(a.nombre)),'[]'::json) into v
  from agg a
  left join public.embajador_cliente c on c.embajador_id=v_me and c.dni = a.dni;

  return json_build_object('ok',true,'clientes',v);
end $function$;

-- ---------------------------------------------------------------------
-- 11) RESUMEN de ventas del embajador en un rango (comisión incluida)
-- ---------------------------------------------------------------------
create or replace function public.ba_resumen(p_token text, p_desde date, p_hasta date)
returns json language plpgsql security definer set search_path to 'public' as $function$
declare v_me bigint; v_pct numeric; v_mesas json; v_prev json;
        v_tot_m numeric; v_tot_p numeric; v_inv int;
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

  return json_build_object('ok',true,'comision_pct',v_pct,
    'desde',to_char(p_desde,'YYYY-MM-DD'),'hasta',to_char(p_hasta,'YYYY-MM-DD'),
    'mesas',v_mesas,'previas',v_prev,
    'total_mesas',v_tot_m,'total_previas',v_tot_p,'total_vendido',v_tot_m+v_tot_p,
    'comision_total', round((v_tot_m+v_tot_p)*v_pct/100),
    'invitados_previa', v_inv);
end $function$;

-- =====================================================================
--  ADMIN (CRM de Paula)
-- =====================================================================

-- Lista de embajadores con ventas del mes en curso
create or replace function public.ba_admin_list(p_pin text)
returns json language plpgsql security definer set search_path to 'public' as $function$
declare v json; v_d0 date; v_d1 date;
begin
  if not public._is_admin(p_pin) then return json_build_object('ok',false,'mensaje','Necesitás el PIN de admin.'); end if;
  v_d0 := date_trunc('month', (now() at time zone 'America/Argentina/Buenos_Aires'))::date;
  v_d1 := (date_trunc('month', (now() at time zone 'America/Argentina/Buenos_Aires')) + interval '1 month' - interval '1 day')::date;

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
  where coalesce(e.activo,true);

  return json_build_object('ok',true,'embajadores',v,
    'mes', to_char(v_d0,'YYYY-MM'));
end $function$;

-- Perfil completo + ventas en rango
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
      'monto', coalesce(n.monto,0), 'comision', round(coalesce(n.monto,0)*v_pct/100)
    ) order by n.fecha),'[]'::json), coalesce(sum(coalesce(n.monto,0)),0)
    into v_mesas, v_tm
  from public.mesas_noche n join public.mesas_config c on c.id=n.mesa_id
  where n.embajador_id=p_id and coalesce(n.titular,'')<>'' and n.fecha between p_desde and p_hasta;

  select coalesce(json_agg(json_build_object(
      'fecha', to_char(p.fecha,'YYYY-MM-DD'), 'titular', p.titular, 'pax', coalesce(p.pax,0),
      'monto', coalesce(p.monto,0), 'comision', round(coalesce(p.monto,0)*v_pct/100)
    ) order by p.fecha),'[]'::json), coalesce(sum(coalesce(p.monto,0)),0)
    into v_prev, v_tp
  from public.previas p where p.embajador_id=p_id and p.fecha between p_desde and p_hasta;

  return json_build_object('ok',true,'perfil',v_perfil,'mesas',v_mesas,'previas',v_prev,
    'total_vendido', v_tm+v_tp, 'comision_total', round((v_tm+v_tp)*v_pct/100),
    'desde',to_char(p_desde,'YYYY-MM-DD'),'hasta',to_char(p_hasta,'YYYY-MM-DD'));
end $function$;

-- Alta / edición de perfil. Si es alta sin contraseña, se genera y se devuelve 1 vez.
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
      v_gen := upper(substr(replace(gen_random_uuid()::text,'-',''),1,8));  -- contraseña generada
    end if;
    insert into public.embajadores(nombre, apellido, dni, ig, contacto, banco, email, comision_pct, activo, pass_hash)
    values (btrim(p_nombre), nullif(btrim(coalesce(p_apellido,'')),''),
            nullif(regexp_replace(coalesce(p_dni,''),'[^0-9]','','g'),''),
            nullif(public.normalizar_ig(coalesce(p_ig,'')),''),
            nullif(btrim(coalesce(p_contacto,'')),''), nullif(btrim(coalesce(p_banco,'')),''),
            v_email, coalesce(p_comision_pct,20), true,
            crypt(coalesce(nullif(btrim(p_pass,''),''), v_gen, 'cambiar123'), gen_salt('bf')))
    returning id into v_id;
  else
    v_id := p_id;
    update public.embajadores set
      nombre = btrim(p_nombre),
      apellido = nullif(btrim(coalesce(p_apellido,'')),''),
      dni = nullif(regexp_replace(coalesce(p_dni,''),'[^0-9]','','g'),''),
      ig = nullif(public.normalizar_ig(coalesce(p_ig,'')),''),
      contacto = nullif(btrim(coalesce(p_contacto,'')),''),
      banco = nullif(btrim(coalesce(p_banco,'')),''),
      email = v_email,
      comision_pct = coalesce(p_comision_pct,20)
    where id = v_id;
    if nullif(btrim(coalesce(p_pass,'')),'') is not null then
      update public.embajadores set pass_hash = crypt(btrim(p_pass), gen_salt('bf')) where id = v_id;
    end if;
  end if;

  return json_build_object('ok',true,'id',v_id,'pass_generada',v_gen);
end $function$;

-- Resetear contraseña (devuelve la nueva 1 vez)
create or replace function public.ba_admin_reset_pass(p_pin text, p_id bigint)
returns json language plpgsql security definer set search_path to 'public','extensions' as $function$
declare v_gen text;
begin
  if not public._is_admin(p_pin) then return json_build_object('ok',false,'mensaje','Necesitás el PIN de admin.'); end if;
  v_gen := upper(substr(replace(gen_random_uuid()::text,'-',''),1,8));
  update public.embajadores set pass_hash = crypt(v_gen, gen_salt('bf')) where id = p_id;
  delete from public.embajador_sesion where embajador_id = p_id;
  return json_build_object('ok',true,'pass_generada',v_gen);
end $function$;

-- Baja lógica
create or replace function public.ba_admin_baja(p_pin text, p_id bigint)
returns json language plpgsql security definer set search_path to 'public' as $function$
begin
  if not public._is_admin(p_pin) then return json_build_object('ok',false,'mensaje','Necesitás el PIN de admin.'); end if;
  update public.embajadores set activo=false where id=p_id;
  delete from public.embajador_sesion where embajador_id=p_id;
  return json_build_object('ok',true);
end $function$;

-- =====================================================================
--  PAGOS MENSUALES AUTOMÁTICOS (generador; la programación va en Parte 3)
-- =====================================================================
create table if not exists public.ba_pago_mes (
  embajador_id bigint not null references public.embajadores(id) on delete cascade,
  ym           text   not null,         -- 'YYYY-MM' del mes liquidado
  pago_id      bigint,
  creado       timestamptz not null default now(),
  primary key (embajador_id, ym)
);

-- Genera los pagos (pendientes) de comisión del mes anterior al que se pasa.
-- p_ref: cualquier fecha del mes ACTUAL; liquida el mes anterior. Idempotente.
create or replace function public.ba_generar_pagos_mes(p_ref date default null)
returns json language plpgsql security definer set search_path to 'public' as $function$
declare v_ref date; v_d0 date; v_d1 date; v_ym text; v_mesn text; r record; v_com numeric; v_pid bigint; v_n int := 0;
        v_meses text[] := array['enero','febrero','marzo','abril','mayo','junio','julio','agosto','septiembre','octubre','noviembre','diciembre'];
begin
  v_ref := coalesce(p_ref, (now() at time zone 'America/Argentina/Buenos_Aires')::date);
  v_d0  := (date_trunc('month', v_ref) - interval '1 month')::date;          -- 1er día mes anterior
  v_d1  := (date_trunc('month', v_ref) - interval '1 day')::date;            -- último día mes anterior
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
      insert into public.pagos(concepto, monto, destinatario, alias_cbu, contacto)
      values ('Comisión BA · '||r.nombre||' '||r.ape||' · '||v_mesn,
              v_com, btrim(r.nombre||' '||r.ape), nullif(r.banco,''), nullif(r.contacto,''))
      returning id into v_pid;
      insert into public.ba_pago_mes(embajador_id, ym, pago_id) values (r.id, v_ym, v_pid);
      v_n := v_n + 1;
    end if;
  end loop;

  return json_build_object('ok',true,'mes',v_ym,'pagos_creados',v_n);
end $function$;

-- =====================================================================
--  GRANTS (anon ejecuta; las funciones validan por token o PIN adentro)
-- =====================================================================
grant execute on function public.ba_login(text,text)                         to anon;
grant execute on function public.ba_logout(text)                             to anon;
grant execute on function public.ba_bootstrap(text)                          to anon;
grant execute on function public.ba_noche(text,date)                         to anon;
grant execute on function public.ba_vender_mesa(text,date,bigint,text,text,integer,numeric) to anon;
grant execute on function public.ba_liberar_mesa(text,date,bigint)           to anon;
grant execute on function public.ba_set_comprobante(text,date,bigint,text,text) to anon;
grant execute on function public.ba_add_guests(text,date,jsonb)              to anon;
grant execute on function public.ba_quitar_guest(text,bigint)                to anon;
grant execute on function public.ba_add_previa(text,date,text,text,numeric,integer) to anon;
grant execute on function public.ba_quitar_previa(text,bigint)               to anon;
grant execute on function public.ba_set_cliente(text,text,text,text,text)    to anon;
grant execute on function public.ba_clientes(text)                           to anon;
grant execute on function public.ba_resumen(text,date,date)                  to anon;
grant execute on function public.ba_admin_list(text)                         to anon;
grant execute on function public.ba_admin_get(text,bigint,date,date)         to anon;
grant execute on function public.ba_admin_upsert(text,bigint,text,text,text,text,text,text,text,numeric,text) to anon;
grant execute on function public.ba_admin_reset_pass(text,bigint)            to anon;
grant execute on function public.ba_admin_baja(text,bigint)                  to anon;
grant execute on function public.ba_generar_pagos_mes(date)                  to anon;

-- =====================================================================
--  STORAGE: bucket público para comprobantes de transferencia
-- =====================================================================
insert into storage.buckets (id, name, public)
values ('comprobantes','comprobantes', true)
on conflict (id) do nothing;

do $$
begin
  if not exists (select 1 from pg_policies where schemaname='storage' and policyname='ba_comprobantes_read') then
    create policy "ba_comprobantes_read" on storage.objects for select
      using (bucket_id = 'comprobantes');
  end if;
  if not exists (select 1 from pg_policies where schemaname='storage' and policyname='ba_comprobantes_write') then
    create policy "ba_comprobantes_write" on storage.objects for insert to anon
      with check (bucket_id = 'comprobantes');
  end if;
end $$;

-- =====================================================================
notify pgrst, 'reload schema';
