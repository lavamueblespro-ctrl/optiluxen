# Optiluxen — CRM para ópticas

CRM completo para ópticas: clientes, historial de fórmulas, facturación con PDF,
recordatorios multicanal y control de suscripción.

En esta versión **todo se guarda en Supabase** (reemplazando el `localStorage`
del prototipo), con autenticación real y aislamiento de datos por usuario.

---

## Archivos

| Archivo | Qué hace |
|---|---|
| `index.html` | La aplicación completa (HTML + CSS + JS) |
| `config.js` | **Único archivo que debes editar**: URL y anon key de tu proyecto |
| `supabase-schema.sql` | Tablas, políticas RLS, bucket de fotos y contador de facturas |
| `README.md` | Este archivo |

---

## 1. Pega tu anon key

Abre `config.js` y reemplaza el valor:

```js
window.OPTILUXEN_CONFIG = {
  SUPABASE_URL: "https://kvfwnojveythxwhztugw.supabase.co",
  SUPABASE_ANON_KEY: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9..."  // ← aquí
};
```

**¿Dónde la encuentras?**
Dashboard de Supabase → tu proyecto → **Project Settings → API** →
sección *Project API keys* → copia la clave **`anon` `public`**.

> La anon key es pública por diseño (viaja en el navegador). Lo que protege los
> datos son las políticas de Row Level Security incluidas en el SQL.

---

## 2. Crea las tablas

En el dashboard: **SQL Editor → New query**, pega todo el contenido de
`supabase-schema.sql` y pulsa **Run**.

Crea:

- `profiles` — estado de la suscripción (se auto-crea al registrarse cada usuario)
- `clients` — clientes
- `prescriptions` — historial de fórmulas (OD/OI, DP, observaciones, foto)
- `sales` + `sale_items` — cobros e ítems
- `reminder_settings` / `reminder_log` — plantillas, canales e historial de envíos
- `counters` + función `next_invoice_no()` — numeración `FAC-00001`, `FAC-00002`…
- bucket privado **`rx`** para las fotos de fórmulas
- políticas **RLS**: cada usuario solo ve/edita sus propias filas

---

## 3. Activa el login

**Authentication → Providers**:

- **Email** → habilitado por defecto. Si quieres entrar sin confirmar correo,
  desactiva *Confirm email*.
- **Google** → habilita el proveedor y pega el *Client ID* y *Client Secret*
  de Google Cloud Console (OAuth 2.0, redirect:
  `https://<tu-proyecto>.supabase.co/auth/v1/callback`).

---

## 4. Ejecutar la app

Necesita servirse por HTTP (los inicios de sesión con Google no funcionan desde
`file://`):

```bash
# opción A
npx serve .

# opción B
python -m http.server 8000
```

Abre `http://localhost:3000` (o `:8000`), crea tu cuenta y ya está operativa.

Para producción: sube la carpeta a Vercel, Netlify, Cloudflare Pages o cualquier
estático. No hay backend propio que desplegar.

---

## Funcionalidades

- **Panel** — clientes registrados, revisiones en 30 días, vendido del mes,
  canales activos, alertas de renovación anual (1 año desde la última compra)
- **Clientes** — tabla o tablero Kanban, búsqueda, alta/edición/borrado,
  importación masiva desde **Excel / Google Sheets** (`.xlsx`, `.xls`, `.csv`, o pegando la
  lista con columnas separadas por tabulación) y exportación CSV
- **Fórmulas** — OD/OI (esfera, cilindro, eje, adición), DP, tipo de lente,
  observaciones y foto de la receta (sube al bucket privado `rx`)
- **Facturación** — ítems con lente/tratamiento/precio (cada producto con su propia fila
  y botón rojo **✕ Quitar**), descuento en **% o valor fijo en $**, total,
  factura PDF (jsPDF) y tres acciones: **compartir** (hoja nativa del celular),
  **compartir por WhatsApp** (el PDF viaja **adjunto**, con el mensaje ya redactado)
  y **descargar**. No hay visor embebido: el PDF siempre sale al navegador/app del sistema.
- **Alta de cliente con compra** — varios productos en la misma venta (varias gafas con
  especificaciones distintas) con **+ Agregar otro producto**, total en vivo y descuento
  aplicado al conjunto; al guardar se emite una sola factura con todos los ítems
- **Recordatorios** — WhatsApp / correo / SMS con plantillas `{{nombre}}`,
  ventana configurable (0/7/15/30 días) e historial de envíos guardado en BD
- **Suscripción** — estado del plan; si está vencido bloquea Clientes y
  Recordatorios
- **Respaldo** — descarga CSV y JSON completos (ya no dependen de
  `window.claude.use('downloads')`)
- Modo noche, diseño responsive

---

## Notas

- El botón **"Cargar datos de ejemplo"** (pestaña Suscripción) añade 3 clientes
  de prueba a tu base; no se inserta nada automáticamente.
- Las fotos de fórmulas se sirven con URLs firmadas de 7 días, así que nunca
  quedan expuestas públicamente.
- Para enviar correos y SMS de verdad hace falta añadir un servicio de envío
  (Resend, Twilio…); hoy los enlaces abren el cliente de correo / SMS del
  usuario y WhatsApp con el mensaje ya redactado, igual que el prototipo.
