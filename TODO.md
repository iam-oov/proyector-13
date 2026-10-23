# TODO

## App de control

- [ ] Vincular escaneando el QR con la cámara del celular (fuera de la app): que abra la app de control y guarde la pantalla. Hoy solo funciona escaneando desde la app.
  - El QR trae `proyector://pair?...` y el `AndroidManifest.xml` de `apps/control` no tiene `intent-filter` para ese esquema.
  - La cámara de Samsung no siempre abre esquemas propios: puede hacer falta un link `https` (App Link) que abra la app.
