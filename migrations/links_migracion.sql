-- ============================================================
-- CHEZ CLUB — Config editable de la página de links (chezclub.com.ar)
-- Migración Supabase (numerala en tu secuencia).
--
-- Botones:  Table editor → links  → insertás/editás filas (orden, label, url, activo).
-- Textos/redes: Table editor → links_config → editás la columna "valor".
-- La página lee todo al cargar; si algo falta, usa los valores por defecto del HTML.
-- ============================================================

create table if not exists links (
  id     bigint generated always as identity primary key,
  orden  int not null default 0,
  label  text not null,
  url    text not null,
  activo boolean not null default true
);
alter table links enable row level security;

create table if not exists links_config (
  clave text primary key,
  valor text not null default ''
);
alter table links_config enable row level security;

create or replace function get_links_page()
returns jsonb
language sql stable security definer as $$
  select jsonb_build_object(
    'config', coalesce(
       (select jsonb_object_agg(clave,valor) filter (where valor<>'') from links_config),
       '{}'::jsonb),
    'links', coalesce(
       (select jsonb_agg(jsonb_build_object('label',label,'url',url) order by orden,id)
        from links where activo),
       '[]'::jsonb)
  );
$$;
revoke all on function get_links_page() from public;
grant execute on function get_links_page() to anon;

-- ------------------------------------------------------------
-- Seed botones (solo si la tabla está vacía; no duplica al re-correr)
-- ------------------------------------------------------------
insert into links (orden,label,url)
select * from (values
  (1,'Entradas y mesas','REEMPLAZAR_URL_DOCUMENTO_DEL_MES'),
  (2,'Radio Chez','REEMPLAZAR_URL_PLAYLIST')
) v(orden,label,url)
where not exists (select 1 from links);

-- ------------------------------------------------------------
-- Seed textos / redes
-- ------------------------------------------------------------
insert into links_config (clave,valor) values
 ('titulo',      'Chez Club'),
 ('subtitulo',   'La Casa de Recoleta'),
 ('footer',      'Estás invitado'),
 ('ig_url',      'https://instagram.com/chezclub.ar'),
 ('email_url',   'REEMPLAZAR_EMAIL'),
 ('spotify_url', 'REEMPLAZAR_URL_SPOTIFY')
on conflict (clave) do nothing;

-- Para agregar un botón nuevo en el futuro:
--   insert into links (orden,label,url) values (3,'Reservá tu cumpleaños','https://...');
-- Para ocultar uno sin borrarlo:
--   update links set activo=false where label='Radio Chez';
