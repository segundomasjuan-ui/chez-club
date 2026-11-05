-- ============================================================
-- CHEZ CLUB — Config editable de la página House Members
-- Migración Supabase (numerala en tu secuencia; Portero iba por 14)
-- Correr en el SQL editor de Supabase, de una sola vez.
--
-- Editás los textos desde: Table editor → hm_config → tocás la columna "valor".
-- La página los lee al cargar; si una fila falta o está vacía, usa el texto por defecto.
-- Tokens: en hint_l1 usá {max} y en hint_l3 usá {hora} (se reemplazan solos).
-- ============================================================

create table if not exists hm_config (
  clave text primary key,
  valor text not null default ''
);

alter table hm_config enable row level security;  -- solo se lee por la función

create or replace function get_hm_config()
returns jsonb
language sql stable security definer as $$
  select coalesce(jsonb_object_agg(clave, valor) filter (where valor <> ''), '{}'::jsonb)
  from hm_config;
$$;

revoke all on function get_hm_config() from public;
grant execute on function get_hm_config() to anon;

-- ------------------------------------------------------------
-- Seed: textos actuales (hora ya en 02:00)
-- ------------------------------------------------------------
insert into hm_config (clave, valor) values
 ('hora_limite',      '02:00'),
 ('titulo',           'House Members'),
 ('importante_cap',   'Importante'),
 ('importante_texto', 'El cupo para House Members es limitado. Si te anotás y no venís dos veces seguidas, serás eliminado de House Members.'),
 ('label_fecha',      'Fecha'),
 ('label_nombre',     'Nombre y apellido'),
 ('label_dni',        'DNI'),
 ('label_email',      'Email'),
 ('label_ig',         'Tu Instagram'),
 ('label_invitados',  '¿Venís con invitados?'),
 ('ph_nombre',        'Como figura en tu DNI'),
 ('ph_dni',           'Sin puntos'),
 ('ph_email',         'tu@email.com'),
 ('ph_ig',            '@usuario'),
 ('hint_l1',          'Cada House Member puede sumar hasta {max} invitados.'),
 ('hint_l2',          'Tenés que estar presente vos para que ellos ingresen.'),
 ('hint_l3',          'Ingreso válido hasta la {hora}.'),
 ('boton',            'Anotarme'),
 ('done_titulo',      'Estás en la lista'),
 ('cerrado',          E'No hay ninguna noche abierta por ahora.\nEstate atento al close friends.'),
 ('footer',           'Estás invitado a la casa de Recoleta')
on conflict (clave) do nothing;   -- no pisa lo que ya hayas editado

-- Para cambiar la hora en el futuro:
--   update hm_config set valor = '02:30' where clave = 'hora_limite';
