/* ============================================================
   Optiluxen · Edge Function  ·  mp-webhook
   ------------------------------------------------------------
   Recibe los avisos de Mercado Pago y es lo ÚNICO que puede marcar
   plan_status / plan_next_charge (corre con service role; el
   navegador no puede tocar esas columnas).

   verify_jwt = APAGADO (lo fija el despliegue): quien escribe aquí
   es Mercado Pago, que no trae JWT nuestro. Por eso la única
   puerta es la firma HMAC-SHA256 de x-signature.

   Manifesto de Mercado Pago (con punto y coma final):
       id:<data.id>;request-id:<x-request-id>;ts:<ts>;
   (se omite cada par cuyo valor no venga en la petición)
   v1 = HMAC-SHA256(clave_secreta, manifesto) en hexadecimal.

   Si la firma no cuadra → 401. Si falta la clave → 503 (para que
   Mercado Pago reintente hasta que se configure). El resto de
   eventos se acepta con 200 y no hace nada.
   ============================================================ */

import { createClient } from "jsr:@supabase/supabase-js@2";

const MP = "https://api.mercadopago.com";
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8" },
  });

/** Comparación en tiempo constante (no filtra por longitud). */
function igual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

/** Construye el manifesto y verifica x-signature. */
async function firmaValida(xSignature: string | null, xRequestId: string | null, dataId: string | null, secreto: string) {
  if (!xSignature) return false;
  const campos: Record<string, string> = {};
  for (const parte of xSignature.split(",")) {
    const i = parte.indexOf("=");
    if (i < 0) continue;
    campos[parte.slice(0, i).trim()] = parte.slice(i + 1).trim();
  }
  const { ts, v1 } = campos;
  if (!ts || !v1) return false;

  const partes: string[] = [];
  if (dataId) partes.push(`id:${dataId}`);
  if (xRequestId) partes.push(`request-id:${xRequestId}`);
  partes.push(`ts:${ts}`);
  const manifesto = partes.join(";") + ";";

  const clave = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(secreto),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const bruto = await crypto.subtle.sign("HMAC", clave, new TextEncoder().encode(manifesto));
  const hex = [...new Uint8Array(bruto)].map((b) => b.toString(16).padStart(2, "0")).join("");
  return igual(hex, v1);
}

/** +1 mes sobre hoy, en 'YYYY-MM-DD' (formato de la columna date). */
function masUnMes(): string {
  const d = new Date();
  d.setUTCMonth(d.getUTCMonth() + 1);
  return d.toISOString().slice(0, 10);
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "método no permitido" }, 405);

  const SECRETO = Deno.env.get("MP_WEBHOOK_SECRET");
  const TOKEN = Deno.env.get("MP_ACCESS_TOKEN");
  if (!SECRETO) return json({ error: "falta MP_WEBHOOK_SECRET" }, 503);
  if (!TOKEN) return json({ error: "falta MP_ACCESS_TOKEN" }, 503);

  const q = new URL(req.url).searchParams;
  let cuerpo: Record<string, unknown> = {};
  try { cuerpo = await req.json(); } catch { /* puede venir vacío */ }

  const dataId =
    q.get("data.id") ??
    q.get("id") ??
    ((cuerpo?.data as { id?: string } | undefined)?.id ?? null);

  /* 1 ─ FIRMA. Se verifica antes de mirar nada más. */
  const ok = await firmaValida(
    req.headers.get("x-signature"),
    req.headers.get("x-request-id"),
    dataId ? String(dataId) : null,
    SECRETO,
  );
  if (!ok) return json({ error: "firma inválida" }, 401);

  /* 2 ─ ¿es de nuestra suscripción? El resto se acepta y se ignora
         (si devolviéramos error, Mercado Pago reintentaría 24 h). */
  const tipo = String(q.get("type") ?? (cuerpo?.type as string) ?? "");
  const accion = String(cuerpo?.action ?? "");
  const esSuscripcion =
    tipo === "preapproval" || tipo === "subscription_preapproval" ||
    accion.startsWith("preapproval");
  if (!esSuscripcion || !dataId) return json({ ok: true, aviso: "evento ignorado" });

  /* 3 ─ estado REAL, pedido a Mercado Pago. Nunca confiamos en el
         cuerpo del aviso: vamos a la fuente. */
  const r = await fetch(`${MP}/preapproval/${dataId}`, {
    headers: { Authorization: `Bearer ${TOKEN}` },
  });
  if (!r.ok) {
    console.error("mp-webhook: GET /preapproval", r.status, await r.text());
    return json({ error: "no se pudo consultar la suscripción" }, 200); // 200 → MP no martillea
  }
  const sub = await r.json();

  /* 4 ─ external_reference lo pusimos NOSOTROS al crearla: es la
         única referencia fiable de a qué usuario pertenece. */
  const ref = String(sub.external_reference ?? "");
  if (!/^[0-9a-fA-F-]{36}$/.test(ref)) return json({ ok: true, aviso: "sin external_reference" });

  const estado = String(sub.status ?? "");
  let plan: "active" | "overdue" | null = null;
  if (estado === "authorized") plan = "active";
  else if (["cancelled", "rejected", "expired", "paused"].includes(estado)) plan = "overdue";
  else return json({ ok: true, estado, aviso: "sin cambio todavía" }); // pending…

  /* 5 ─ siguiente cobro: el que reporte MP o, si no, hoy + 1 mes */
  const proximo = (sub.auto_recurring?.next_payment_date as string | undefined) || "";
  const fecha = plan === "active" ? (proximo ? proximo.slice(0, 10) : masUnMes()) : null;

  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const cambios: Record<string, unknown> = { plan_status: plan, mp_preapproval_id: sub.id };
  if (fecha) cambios.plan_next_charge = fecha;

  const { data, error } = await admin.from("profiles").update(cambios).eq("id", ref).select("id");
  if (error) {
    console.error("mp-webhook: update", error.message);
    return json({ error: "no se pudo actualizar el plan" }, 500); // 500 → MP reintenta
  }
  if (!data?.length) {
    console.error("mp-webhook: no existe el perfil", ref);
    return json({ ok: true, aviso: "perfil inexistente" });
  }

  return json({ ok: true, plan, estado, ref, fecha });
});
