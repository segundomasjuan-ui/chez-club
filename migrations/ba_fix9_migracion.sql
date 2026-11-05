-- =====================================================================
--  CHEZ CLUB · Fix 9 · Subir comprobantes desde Puerta (PIN)
--  Funciones con PIN de staff para adjuntar comprobante a mesa y previa.
-- =====================================================================

alter table public.mesas_noche add column if not exists comprobante_url text;
alter table public.mesas_noche add column if not exists comprobante_nombre text;
alter table public.previas     add column if not exists comprobante_url text;
alter table public.previas     add column if not exists comprobante_nombre text;

create or replace function public.set_mesa_comprobante(p_pin text, p_fecha date, p_mesa_id bigint, p_url text, p_nombre text)
returns json language plpgsql security definer set search_path to 'public' as $function$
begin
  if not public._is_staff(p_pin) then return json_build_object('ok',false,'mensaje','PIN incorrecto.'); end if;
  insert into public.mesas_noche(fecha, mesa_id, comprobante_url, comprobante_nombre)
  values (p_fecha, p_mesa_id, nullif(btrim(coalesce(p_url,'')),''), nullif(btrim(coalesce(p_nombre,'')),''))
  on conflict (fecha, mesa_id) do update
    set comprobante_url=excluded.comprobante_url, comprobante_nombre=excluded.comprobante_nombre;
  return json_build_object('ok',true);
end $function$;
grant execute on function public.set_mesa_comprobante(text,date,bigint,text,text) to anon;

create or replace function public.set_previa_comprobante(p_pin text, p_previa_id bigint, p_url text, p_nombre text)
returns json language plpgsql security definer set search_path to 'public' as $function$
begin
  if not public._is_staff(p_pin) then return json_build_object('ok',false,'mensaje','PIN incorrecto.'); end if;
  update public.previas
     set comprobante_url=nullif(btrim(coalesce(p_url,'')),''),
         comprobante_nombre=nullif(btrim(coalesce(p_nombre,'')),'')
   where id=p_previa_id;
  if not found then return json_build_object('ok',false,'mensaje','No existe la previa.'); end if;
  return json_build_object('ok',true);
end $function$;
grant execute on function public.set_previa_comprobante(text,bigint,text,text) to anon;

notify pgrst, 'reload schema';
