-- ============================================================
-- PAULA — Links editables (accesos directos del sitio)
-- Correr en el SQL editor de Supabase.
-- ============================================================

create table if not exists paula_links (
  id      bigint generated always as identity primary key,
  orden   int not null default 0,
  nombre  text not null,
  url     text not null,
  created_at timestamptz not null default now()
);
alter table paula_links enable row level security;

create or replace function get_paula_links(p_pin text)
returns json language plpgsql security definer stable
set search_path to 'public' as $$
begin
  if not (coalesce(p_pin,'')=coalesce(cfg('pin_admin'),'__na__')
       or coalesce(p_pin,'')=coalesce(cfg('pin_puerta'),'__np__')) then
    return json_build_object('ok',false,'mensaje','PIN incorrecto.');
  end if;
  return json_build_object('ok',true,'lista',
    coalesce((select json_agg(json_build_object('id',id,'nombre',nombre,'url',url) order by orden,id)
              from paula_links),'[]'::json));
end $$;

create or replace function crear_paula_link(p_pin text, p_nombre text, p_url text)
returns json language plpgsql security definer
set search_path to 'public' as $$
begin
  if coalesce(p_pin,'') <> coalesce(cfg('pin_admin'),'__na__') then
    return json_build_object('ok',false,'mensaje','Necesitás el PIN de admin.'); end if;
  if length(btrim(coalesce(p_nombre,'')))<1 or length(btrim(coalesce(p_url,'')))<3 then
    return json_build_object('ok',false,'mensaje','Faltan datos.'); end if;
  insert into paula_links(nombre,url,orden)
  values (btrim(p_nombre), btrim(p_url), (select coalesce(max(orden),0)+1 from paula_links));
  return json_build_object('ok',true);
end $$;

create or replace function borrar_paula_link(p_pin text, p_id bigint)
returns json language plpgsql security definer
set search_path to 'public' as $$
begin
  if coalesce(p_pin,'') <> coalesce(cfg('pin_admin'),'__na__') then
    return json_build_object('ok',false,'mensaje','Necesitás el PIN de admin.'); end if;
  delete from paula_links where id = p_id;
  return json_build_object('ok',true);
end $$;

revoke all on function get_paula_links(text)          from public;
revoke all on function crear_paula_link(text,text,text) from public;
revoke all on function borrar_paula_link(text,bigint)  from public;
grant execute on function get_paula_links(text)          to anon;
grant execute on function crear_paula_link(text,text,text) to anon;
grant execute on function borrar_paula_link(text,bigint)  to anon;

-- seed con los accesos actuales (solo si está vacía)
insert into paula_links(orden,nombre,url)
select * from (values
  (1,'Landing','https://www.chezclub.com.ar/'),
  (2,'Paula','https://www.chezclub.com.ar/paula'),
  (3,'Puerta','https://www.chezclub.com.ar/puerta'),
  (4,'House Members','https://www.chezclub.com.ar/housemembers'),
  (5,'Ruleta','https://www.chezclub.com.ar/ruleta')
) v(orden,nombre,url)
where not exists (select 1 from paula_links);

notify pgrst, 'reload schema';
