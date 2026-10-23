# TODO

## App de control

- [ ] Vincular escaneando el QR con la cámara del celular (fuera de la app): que abra la app de control y guarde la pantalla. Hoy solo funciona escaneando desde la app. (Pedido de Osvaldo para el 2026-10-23.)
  - El QR trae `proyector://pair?...` y el `AndroidManifest.xml` de `apps/control` no tiene `intent-filter` para ese esquema.
  - La cámara de Samsung no siempre abre esquemas propios: puede hacer falta un link `https` (App Link) que abra la app.
  - Con `https`, el token va en el QR: ponerlo después de `#` para que no llegue a ningún servidor si la app no está instalada, y que esa página diga cómo instalarla.
  - Al abrirse por el link: la app hace el mismo `/pair` que al escanear adentro, elige esa pantalla y avisa "TheBest agregado". Si ya estaba, solo la elige.
  - TVs sin receptor (DIAL, Roku): no muestran QR. Ver si la app puede generar un QR o link para pasar esas pantallas a otro teléfono.

- [ ] Mejorar "vincular por código" (pedido de Osvaldo para el 2026-10-23). Antes de empezar, preguntarle qué le estorba de lo de hoy.
  - Hoy el "código" es el link completo `proyector://pair?...` (largo, con el token): se copia en un teléfono (menú ⋮ → "Copiar código"), se manda por WhatsApp y en el otro se toca "Pegar código". No se puede escribir a mano.
  - Idea: código corto (6 caracteres) en la pantalla "Vincular teléfono" del proyector, como el de YouTube o Netflix en la TV; en la app "Escribir código": busca los receptores del Wi-Fi (ya existe la búsqueda por IP) y le pregunta a cada uno por ese código; el que coincide entrega el token.
  - El código corto debe caducar (unos 10 min) y cambiar después de usarse, para que no sirva si alguien lo ve.
