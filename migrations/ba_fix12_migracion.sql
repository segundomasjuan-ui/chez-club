-- =====================================================================
--  CHEZ CLUB · Fix 12 · crear_previa / editar_previa (Puerta)
--  Estas funciones NO existían → por eso Puerta tiraba "Error de conexión"
--  al crear o editar una previa. Las creamos con la firma exacta que
--  puerta.html ya llama: (..., p_monto, p_descripcion, p_items json).
--  p_items = lista de invitados [{nombre, dni}, ...].
--  Dropeamos cualquier versión previa (cualquier firma) para no duplicar.
-- =====================================================================

do $$ declare r record; begin
  for r in select oid::regprocedure sig from pg_proc
           where proname in ('crear_previa','editar_previa') and pronamespace='public'::regnamespace
  loop execute 'drop function '||r.sig::text; end loop;
end $$;

-- ---------------------------------------------------------------------
create function public.crear_previa(
  p_pin text, p_fecha date, p_titular text, p_dni text,
  p_monto numeric, p_descripcion text, p_items json)
returns json language plpgsql security definer set search_path to 'public' as $function$
declare v_id bigint; v_dni text; it json; v_nom text; v_idni text;
begin
  if not public._is_staff(p_pin) then return json_build_object('ok',false,'mensaje','PIN incorrecto.'); end if;
  if length(btrim(coalesce(p_titular,''))) < 2 then return json_build_object('ok',false,'mensaje','Falta el titular.'); end if;
  v_dni := nullif(regexp_replace(coalesce(p_dni,''),'[^0-9]','','g'),'');
  insert into public.previas(fecha, titular, titular_dni, monto, descripcion, entradas_monto)
  values (p_fecha, btrim(p_titular), v_dni, coalesce(p_monto,0),
          nullif(btrim(coalesce(p_descripcion,'')),''), coalesce(p_monto,0))
  returning id into v_id;
  insert into public.previa_invitados(previa_id, nombre, dni, orden) values (v_id, btrim(p_titular), v_dni, 0);
  for it in select * from json_array_elements(coalesce(p_items,'[]'::json)) loop
    v_nom := btrim(coalesce(it->>'nombre','')); if length(v_nom) < 2 then continue; end if;
    v_idni := nullif(regexp_replace(coalesce(it->>'dni',''),'[^0-9]','','g'),'');
    insert into public.previa_invitados(previa_id, nombre, dni, orden) values (v_id, v_nom, v_idni, 1);
  end loop;
  return json_build_object('ok',true,'id',v_id);
end $function$;
grant execute on function public.crear_previa(text,date,text,text,numeric,text,json) to anon;

-- ---------------------------------------------------------------------
create function public.editar_previa(
  p_pin text, p_previa_id bigint, p_titular text, p_dni text,
  p_monto numeric, p_descripcion text, p_items json)
returns json language plpgsql security definer set search_path to 'public' as $function$
declare v_dni text; it json; v_nom text; v_idni text;
begin
  if not public._is_staff(p_pin) then return json_build_object('ok',false,'mensaje','PIN incorrecto.'); end if;
  if not exists(select 1 from public.previas where id=p_previa_id) then return json_build_object('ok',false,'mensaje','No existe la previa.'); end if;
  if length(btrim(coalesce(p_titular,''))) < 2 then return json_build_object('ok',false,'mensaje','Falta el titular.'); end if;
  v_dni := nullif(regexp_replace(coalesce(p_dni,''),'[^0-9]','','g'),'');
  update public.previas set
     titular=btrim(p_titular), titular_dni=v_dni, monto=coalesce(p_monto,0),
     descripcion=nullif(btrim(coalesce(p_descripcion,'')),''), entradas_monto=coalesce(p_monto,0)
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
grant execute on function public.editar_previa(text,bigint,text,text,numeric,text,json) to anon;

notify pgrst, 'reload schema';

-- Verificación: deben aparecer las dos
select p.oid::regprocedure as firma
from pg_proc p
where p.pronamespace='public'::regnamespace and p.proname in ('crear_previa','editar_previa')
order by p.proname;
