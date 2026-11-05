-- =====================================================================
--  CHEZ CLUB · Parte 3 · Comisiones BA automáticas a fin de mes
--  Agenda ba_generar_pagos_mes() para que corra el día 1 de cada mes
--  a las 09:00 de Buenos Aires (12:00 UTC) y genere los pagos de
--  comisión del mes que acaba de cerrar.
--  La función ya es idempotente (no duplica un mes ya generado).
-- =====================================================================

create extension if not exists pg_cron;

-- Quitar el job si ya existía (para poder re-correr este script sin duplicar)
do $$
begin
  perform cron.unschedule('ba-comisiones-mensual');
exception when others then
  null;
end $$;

-- Día 1 de cada mes, 12:00 UTC = 09:00 Buenos Aires
select cron.schedule(
  'ba-comisiones-mensual',
  '0 12 1 * *',
  $$ select public.ba_generar_pagos_mes(); $$
);

-- Verificación: debe listar el job agendado
select jobid, schedule, command, active
from cron.job
where jobname = 'ba-comisiones-mensual';
