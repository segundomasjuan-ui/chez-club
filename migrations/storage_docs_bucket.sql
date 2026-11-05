-- ============================================================
-- CHEZ CLUB — Bucket público para documentos (PDFs, info del mes)
-- Correr una sola vez en el SQL editor de Supabase.
-- (Alternativa por UI: Storage → New bucket → nombre "docs" → Public → Create)
-- ============================================================

insert into storage.buckets (id, name, public)
values ('docs', 'docs', true)
on conflict (id) do update set public = true;

-- Bucket público = lectura abierta automática (cualquiera con la URL ve el archivo).
-- La subida la hacés vos desde el dashboard (logueado), no hace falta policy de escritura anónima.
