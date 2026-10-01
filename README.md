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
| `security-hardening.sql` | Endurecimiento: privilegios mínimos y bloqueo de TRUNCATE |
| `_headers` | Cabeceras de seguridad que Netlify añade a cada respuesta |
| `serve.js` | Servidor local (`node serve.js` → `http://localhost:3000`) |
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
  factura PDF (jsPDF) y tres acciones: **compartir** (hoja nativa con el PDF adjunto),
  **compartir por WhatsApp** (abre **el chat directo del cliente con su número** —se completa
  el prefijo 57 si el móvil se guardó sin él—, con el mensaje ya redactado y el PDF descargado
  para adjuntarlo) y **descargar**. No hay visor embebido: el PDF siempre sale al navegador/app del sistema.
- **Alta de cliente con compra** — varios productos en la misma venta (varias gafas con
  especificaciones distintas) con **+ Agregar otro producto**, total en vivo y descuento
  aplicado al conjunto; al guardar se emite una sola factura con todos los ítems
- **Recordatorios** — WhatsApp / correo / SMS con plantillas `{{nombre}}` y `{{optica}}`;
  si el texto guardado no menciona la óptica se le añade el nombre al final, así que
  **ningún recordatorio sale sin el nombre de la óptica registrada**. Ventana configurable
  (0/7/15/30 días) e historial de envíos guardado en BD
- **Suscripción** — estado del plan; si está vencido bloquea Clientes y
  Recordatorios
- **Respaldo** — descarga CSV y JSON completos (ya no dependen de
  `window.claude.use('downloads')`)
- **Barra superior derecha** — logo de la aplicación y, al lado, el logo de la óptica
  con desplegable (nombre, correo y **Cerrar sesión**). Como está en la cabecera,
  el cierre de sesión también funciona en móvil, donde el lateral se oculta
- Modo noche, diseño responsive

---

## Seguridad

Auditoría hecha contra la base **en producción** (no contra el archivo del disco),
con comprobación antes/después de cada cambio.

### Qué se verificó

| Área | Estado |
|---|---|
| Tokens, claves privadas y secretos en el repo y en los 9 commits del historial | ✅ **cero** (ni `sbp_`, ni `GOCSPX`, ni `service_role`, ni claves privadas) |
| RLS activo en las 8 tablas | ✅ verificado en producción |
| Políticas solo para `authenticated` (nada para `anon`) | ✅ |
| Buckets `rx` y `branding` privados con carpeta por usuario | ✅ |
| Inyección XSS (17 puntos de `innerHTML`) | ✅ todos escapan con `esc()` / `attr()` |
| Inyección de fórmulas al exportar CSV | ✅ blindado (valores `= + - @` llevan `'`) |
| Apertura de enlaces externos (`target="_blank"`) | ✅ `rel="noopener noreferrer"` |
| CDN con versión flotante (`supabase-js@2`) | ✅ fijado a `2.117.2` |
| Servidor local: path traversal y respuestas 500 | ✅ corregido (`400`/`403` sin filtrar errores) |
| `script-src` sin `'self'`: solo `/config.js` (con dominio) y los 3 CDN | ✅ el script que Netlify inyecta queda bloqueado |

### Qué se endureció (`security-hardening.sql`, ya aplicado)

1. **El rol `anon` perdió todo privilegio** sobre las 8 tablas y sobre
   `next_invoice_no()`. La anon key es pública por diseño, así que ya no
   sirve para nada. `handle_new_user()` conserva el EXECUTE vía `PUBLIC`,
   pero no es invocable: PostgreSQL responde *"trigger functions can only
   be called as triggers"* y PostgREST ni la publica (404) — comprobado
   contra producción.
2. **TRUNCATE/REFERENCES/TRIGGER revocados** en `anon` y `authenticated`.
   Hallazgo verificado: con una política que negaba todo, un `TRUNCATE`
   ejecutado como `anon` **igual vació la tabla** (RLS no cubre TRUNCATE).
3. **`counters.invoice_seq` ya no es editable** desde la web: los números de
   factura solo salen por `next_invoice_no()`.
4. **Longitud de contraseña mínima: 6 → 12** (verificado con un registro real:
   GoTrue responde `weak_password`).
5. **`profiles.plan_status` ya no lo puede tocar el usuario**: se revocó el
   UPDATE de la tabla entera y solo quedan concedidos por columna
   `full_name` (nombre de la óptica) y `logo_path` (su logo). Antes cualquier
   cuenta podía marcarse a sí misma como pagada con
   `update profiles set plan_status='active'`. Como efecto deliberado se
   retiraron los botones *Simular pago exitoso*, *Simular pago vencido* y
   *Pagar ahora*: el backend ya devolvía 403 y habrían mentido en pantalla.
   El estado del plan se cambia desde el Dashboard de Supabase.
6. **La CSP ya no permite `script-src 'self'`.** Netlify inyecta en los `.html`
   publicados un `<script async src="/.netlify/scripts/hud">` (el badge
   *Powered by Netlify*) que se ejecuta **en el mismo origen que la app**, con
   acceso a `localStorage`, donde vive la sesión. Ahora solo puede ejecutarse
   `config.js` —indicando el dominio, porque Chrome ignora las rutas
   relativas como `/config.js`— y los 3 CDN; ese script queda bloqueado y el
   badge desaparece. Comprobado en el navegador: `config.js` carga, otro
   archivo del propio dominio no, el CDN sí, el script `inline` sí y los
   `onclick=` siguen activos. Si algún día se añade un dominio propio hay que
   añadir su `/config.js` al `script-src` de `_headers`.

### Comprobación integral (24/24)

Con un usuario de prueba real (insert + login + JWT) se comprobó que sigue
funcionando todo: lectura de las 7 tablas, altas de clientes, `UPSERT` de
recordatorios, edición del nombre y del logo, emisión de facturas
(`next_invoice_no`), storage privado, y que **anon recibe 401**, que **un
usuario no ve los datos de otro**, que **el contador no se puede manipular
(403)**, que **una contraseña de 6 caracteres ya no se acepta (422)** y que
**`plan_status`/`plan_next_charge` responden 403**.

### Pendiente / decisión

- La clave `anon` **no se puede ocultar**: viaja al navegador por definición.
  Lo que la hace inofensiva es que ya no abre nada.
- `config.js` vive en el repositorio porque Netlify lo despliega desde ahí;
  su contenido es público, no un secreto.
- Netlify añade además, en el borde y fuera del repositorio, un **comentario
  publicitario** en la cabecera del HTML y el script del badge. El script ya
  no se ejecuta (punto 6); el comentario no se puede quitar desde aquí.
- Residual: la sesión se guarda en `localStorage`, así que cualquier XSS futuro
  podría robarla. Por eso se mantienen el escape estricto y la CSP.

---

## Notas

- **Para activar o vencer una suscripción** hay que cambiar `profiles.plan_status`
  (`active` u `overdue`) desde el Dashboard de Supabase: la app no puede
  tocarlo a propósito (bloque 6 de `security-hardening.sql`).
- El botón **"Cargar datos de ejemplo"** (pestaña Suscripción) añade 3 clientes
  de prueba a tu base; no se inserta nada automáticamente.
- Las fotos de fórmulas se sirven con URLs firmadas de 7 días, así que nunca
  quedan expuestas públicamente.
- Para enviar correos y SMS de verdad hace falta añadir un servicio de envío
  (Resend, Twilio…); hoy los enlaces abren el cliente de correo / SMS del
  usuario y WhatsApp con el mensaje ya redactado, igual que el prototipo.
