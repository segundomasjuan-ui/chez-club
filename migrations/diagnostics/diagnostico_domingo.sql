-- Diagnóstico: por qué no se ve la noche de hoy (domingo)
-- Corré todo y pegá los tres resultados.

-- 1) Fecha/hora que ve el servidor en horario de Buenos Aires
select
  (now() at time zone 'America/Argentina/Buenos_Aires')        as ahora_ba,
  (now() at time zone 'America/Argentina/Buenos_Aires')::date  as hoy_ba;

-- 2) Noches alrededor de hoy: fecha, nombre y si está abierta
select fecha, nombre, abierto,
       (fecha = (now() at time zone 'America/Argentina/Buenos_Aires')::date) as es_hoy
from public.noches
where fecha between (now() at time zone 'America/Argentina/Buenos_Aires')::date - 3
                and (now() at time zone 'America/Argentina/Buenos_Aires')::date + 3
order by fecha;

-- 3) Lo que devuelve House Members / Puerta
select public.get_noches_abiertas() as lo_que_devuelve_el_servidor;
