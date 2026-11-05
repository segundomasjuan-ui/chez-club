# Chez Club — sistema de puerta y gestión

Stack: **Supabase** (Postgres + Storage) · **Cloudflare Pages** (sitio estático) · HTML/JS vanilla con la anon key embebida (seguridad por RLS + funciones SECURITY DEFINER).

## Estructura

```
site/            → lo que deploya Cloudflare Pages (arrastrar esta carpeta, o conectar por git)
  index.html            landing / bio
  housemembers.html     RSVP House Members (público, linkeado desde Instagram)
  ruleta.html           ruleta/sorteo (QR)
  brandambassadors.html portal de Brand Ambassadors (/brandambassadors)
  thephantomgala.html   evento
  paula.html            CRM / gestión (admin)
  puerta.html           sistema de puerta (staff)
  _headers              control de caché (no-store en HM/ruleta/BA)

migrations/      → SQL de Supabase, YA APLICADO a la base en vivo. Es historial.
  diagnostics/          consultas descartables de diagnóstico
```

## Importante

- Las migraciones de `migrations/` **ya están aplicadas** en Supabase. No re-correrlas salvo que montes una base nueva. Un cambio nuevo = un archivo nuevo.
- `paula.html` y `puerta.html` están en el **mismo** proyecto de Cloudflare que el sitio público (son admin, pero accesibles por URL; la seguridad es por PIN + RLS).
- Deploy actual: arrastrar `site/` a Cloudflare Pages. **Objetivo:** conectar este repo a Pages para deploy automático en cada push.

## Orden de deploy cuando hay cambio de SQL

Correr la migración en Supabase **primero**, y subir el HTML **enseguida** (varios cambios cambian firmas de funciones; si el HTML viejo llama a la firma nueva, o al revés, falla en el intervalo).
