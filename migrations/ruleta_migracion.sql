-- ============================================================
-- CHEZ CLUB — Ruleta de Retos
-- Migración Supabase (numerá según tu secuencia; Portero iba por 14)
-- v2: SIN dependencia de la tabla `noches`. Se llavea por fecha de noche.
-- ============================================================

-- ------------------------------------------------------------
-- 1) TABLAS
-- ------------------------------------------------------------

create table if not exists retos (
  id     int primary key,                         -- 1..50
  texto  text not null,
  tipo   text not null check (tipo in ('golden','social')),
  activo boolean not null default true
);

create table if not exists ruleta_tiradas (
  id           bigint generated always as identity primary key,
  noche_fecha  date   not null,                   -- fecha de la noche (corte 02:00)
  device_token text   not null,
  reto_id      int    not null references retos(id),
  es_golden    boolean not null default false,
  created_at   timestamptz not null default now()
);

-- Una tirada por dispositivo por noche (idempotencia / anti-regiro)
create unique index if not exists uq_tirada_device
  on ruleta_tiradas (noche_fecha, device_token);

-- Cada golden se entrega UNA sola vez por noche (cupo = 1, a prueba de carreras)
create unique index if not exists uq_golden_una_vez
  on ruleta_tiradas (noche_fecha, reto_id) where es_golden;

-- ------------------------------------------------------------
-- 2) RLS: acceso directo denegado. Solo se entra por las funciones.
-- ------------------------------------------------------------

alter table retos          enable row level security;
alter table ruleta_tiradas enable row level security;
-- (sin policies a propósito: anon no lee ni escribe las tablas directo)

-- ------------------------------------------------------------
-- 3) NOCHE ACTIVA — calculada, sin tocar `noches`.
--    Corte 02:00 (misma lógica HM del Portero): un escaneo a la 01:30
--    cuenta para la noche que abrió la tarde anterior.
--    Gatea a jue/vie/sáb (dow 4/5/6): un QR viejo escaneado un martes
--    devuelve "no hay noche activa" en vez de repartir golden.
--    >>> Si algún día abrís otro día, agregá su dow a la lista. <<<
-- ------------------------------------------------------------

create or replace function _noche_activa()
returns date
language sql stable as $$
  select f from (
    select (now() at time zone 'America/Argentina/Buenos_Aires'
            - interval '2 hours')::date as f
  ) x
  where extract(dow from x.f) in (4,5,6);   -- 4=jue, 5=vie, 6=sáb
$$;

-- ------------------------------------------------------------
-- 4) LEER MI RETO (sin asignar) — para el re-escaneo
-- ------------------------------------------------------------

create or replace function mi_reto_actual(p_device_token text)
returns table(reto_id int, texto text, tipo text)
language plpgsql security definer stable as $$
declare v_fecha date;
begin
  v_fecha := _noche_activa();
  if v_fecha is null then return; end if;

  return query
    select r.id, r.texto, r.tipo
    from ruleta_tiradas t
    join retos r on r.id = t.reto_id
    where t.noche_fecha = v_fecha
      and t.device_token = p_device_token
    limit 1;
end; $$;

-- ------------------------------------------------------------
-- 5) TIRAR LA RULETA (asignación atómica)
--    - Idempotente: si ya tiró, devuelve lo mismo.
--    - Golden solo si sigue disponible; social siempre (repite libre).
--    - Reintenta si un golden se lo lleva otro en el mismo instante.
-- ------------------------------------------------------------

create or replace function tirar_ruleta(p_device_token text)
returns table(reto_id int, texto text, tipo text)
language plpgsql security definer as $$
declare
  v_fecha date;
  v_id    int;
  v_tipo  text;
  v_texto text;
  v_exist int;
begin
  v_fecha := _noche_activa();
  if v_fecha is null then return; end if;

  -- ya tiró esta noche?
  select t.reto_id into v_exist
  from ruleta_tiradas t
  where t.noche_fecha = v_fecha and t.device_token = p_device_token
  limit 1;
  if found then
    return query select r.id, r.texto, r.tipo from retos r where r.id = v_exist;
    return;
  end if;

  for i in 1..12 loop
    select r.id, r.tipo, r.texto
    into v_id, v_tipo, v_texto
    from retos r
    where r.activo
      and (
        r.tipo = 'social'
        or (
          r.tipo = 'golden'
          and not exists (
            select 1 from ruleta_tiradas t
            where t.noche_fecha = v_fecha and t.reto_id = r.id
          )
        )
      )
    order by random()
    limit 1;

    if v_id is null then return; end if;

    begin
      insert into ruleta_tiradas (noche_fecha, device_token, reto_id, es_golden)
      values (v_fecha, p_device_token, v_id, v_tipo = 'golden');
      return query select v_id, v_texto, v_tipo;
      return;
    exception when unique_violation then
      select t.reto_id into v_exist
      from ruleta_tiradas t
      where t.noche_fecha = v_fecha and t.device_token = p_device_token
      limit 1;
      if found then
        return query select r.id, r.texto, r.tipo from retos r where r.id = v_exist;
        return;
      end if;
      -- golden tomado: el loop reintenta y ya lo va a ver ocupado
    end;
  end loop;
end; $$;

-- ------------------------------------------------------------
-- 6) PERMISOS: el navegador (anon) solo puede llamar estas dos funciones.
-- ------------------------------------------------------------

revoke all on function tirar_ruleta(text)   from public;
revoke all on function mi_reto_actual(text) from public;
grant execute on function tirar_ruleta(text)   to anon;
grant execute on function mi_reto_actual(text) to anon;

-- ------------------------------------------------------------
-- 7) SEED — los 50 retos (1..5 golden, 6..50 social)
-- ------------------------------------------------------------

insert into retos (id, texto, tipo) values
 (1 , 'Te ganaste un trago gratis para regalárselo a alguien. Reclamalo en boletería.', 'golden'),
 (2 , 'Te ganaste una canción a elección. Entregar al DJ.', 'golden'),
 (3 , 'Te ganaste 3 entradas gratis para el próximo jueves. Reclamalas en boletería después de las 00:00.', 'golden'),
 (4 , 'Si jugás al beerpong, el equipo contrario arranca con un vaso menos.', 'golden'),
 (5 , 'Te ganaste una tirada de dados con dos desconocidos a tu elección. Reclamalo en barra después de las 00:00.', 'golden'),
 (6 , 'Invitale un trago a alguien que no conozcas.', 'social'),
 (7 , 'Sacá a bailar a alguien que no conozcas.', 'social'),
 (8 , 'Sacate una foto con alguien que no conozcas.', 'social'),
 (9 , 'Pedile a alguien que te muestre la última foto de su galería.', 'social'),
 (10, 'Pedile a alguien que te muestre el último mensaje que envió.', 'social'),
 (11, 'Terminá la noche con un plan para otro día.', 'social'),
 (12, 'Jugá un partido de beerpong con alguien que no conozcas.', 'social'),
 (13, 'Hacé una tirada de dados con alguien que no conozcas.', 'social'),
 (14, 'Sacate una foto con dos personas con bigote.', 'social'),
 (15, 'El primer desconocido que te hable, se tiene que sacar una foto con vos.', 'social'),
 (16, 'Preguntale a alguien con el pelo rubio: “¿Cómo se llaman tus papás?”.', 'social'),
 (17, 'Robale una cerveza a alguien.', 'social'),
 (18, 'Lográ que copien tu paso de baile.', 'social'),
 (19, 'Conseguí una date (para vos o para otro).', 'social'),
 (20, 'Presentate a alguien como si fueras de una provincia que no sos.', 'social'),
 (21, 'Pedí la camarita que está en boletería y volvete el fotógrafo de la noche.', 'social'),
 (22, 'Regalale un shot a un desconocido.', 'social'),
 (23, 'Ganá un partido de beerpong.', 'social'),
 (24, 'Bailá como Michael Jackson.', 'social'),
 (25, 'Tenés que actuar como si fueses extranjero.', 'social'),
 (26, 'Embocá a un vaso de beerpong con tu mano mala.', 'social'),
 (27, 'Embocá a un vaso de beerpong con los ojos cerrados.', 'social'),
 (28, 'Encontrá a alguien que sea del mismo signo que vos.', 'social'),
 (29, 'Conseguí que un desconocido te enseñe un paso de baile y hacelo con él.', 'social'),
 (30, 'Hacé un brindis con 3 personas que no conozcas.', 'social'),
 (31, 'Hacé una foto grupal con al menos 5 personas que no conozcas.', 'social'),
 (32, 'Conseguí que un desconocido te ponga un apodo.', 'social'),
 (33, 'Pedile a alguien que elija tu próximo trago.', 'social'),
 (34, 'Conseguí que alguien te invite un trago.', 'social'),
 (35, 'Intercambiá un accesorio con un desconocido por 10 minutos.', 'social'),
 (36, 'Inventá un saludo secreto con alguien que acabás de conocer.', 'social'),
 (37, 'Decile algo lindo a tres desconocidos.', 'social'),
 (38, 'Conseguí que 3 desconocidos hagan un brindis gritando tu nombre.', 'social'),
 (39, 'Inventate una profesión completamente falsa y mantené la historia durante 1 minuto.', 'social'),
 (40, 'Pedile a alguien que te califique el outfit del 1 al 10.', 'social'),
 (41, 'Convencé a un desconocido para que haga una foto “de pareja” con vos.', 'social'),
 (42, 'Conseguí que alguien te enseñe una palabra o frase de su provincia/país.', 'social'),
 (43, 'Terminá la noche con tres recomendaciones de películas.', 'social'),
 (44, 'Hacé una entrevista a un desconocido como si fueras periodista.', 'social'),
 (45, 'Preguntale a un desconocido cuál fue su peor cita y lográ que te cuente la historia.', 'social'),
 (46, 'Diseñale una cita ideal a alguien que no conozcas.', 'social'),
 (47, 'Leele la mano de alguien que acabás de conocer.', 'social'),
 (48, 'Brindá con 3 desconocidos, cada uno dice su motivo.', 'social'),
 (49, 'Convencé a un desconocido de que te conoce desde la infancia.', 'social'),
 (50, 'Formá un trencito en la pista de baile.', 'social')
on conflict (id) do update
  set texto = excluded.texto,
      tipo  = excluded.tipo,
      activo = true;

-- ============================================================
-- FIN. Consultas útiles para la noche (usan _noche_activa()):
--   Escaneos:              select count(*) from ruleta_tiradas where noche_fecha = _noche_activa();
--   Distribución de retos: select reto_id, count(*) from ruleta_tiradas where noche_fecha=_noche_activa() group by 1 order by 2 desc;
--   Golden entregados:     select r.id, r.texto from ruleta_tiradas t join retos r on r.id=t.reto_id where t.noche_fecha=_noche_activa() and t.es_golden;
-- ============================================================
