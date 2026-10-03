/* ============================================================
   Optiluxen · Edge Function  ·  mp-billing
   ------------------------------------------------------------
   Crea la suscripción de Mercado Pago y devuelve la URL de pago.

   verify_jwt = ENCENDIDO (lo fija el despliegue): solo quien trae
   una sesión válida puede llamarla. El Access Token de Mercado Pago
   vive en los secretos de Supabase y NO sale nunca de aquí.

   Flujo:
     navegador ─POST {action:"checkout"}─▶ esta función
                                             │ crea /preapproval
                                             ▼
                    { url: "https://www.mercadopago.com.co/checkout/…" }
     navegador ────────── redirige ─────────▶ paga allí
     Mercado Pago ──webhook firmado──▶ mp-webhook ─▶ plan_status
   ============================================================ */

import { createClient } from "jsr:@supabase/supabase-js@2";

const MP = "https://api.mercadopago.com";

function cabeceras(req: Request): Record<string, string> {
  return {
    // se ecoa el origen que pide: el navegador valida la respuesta
    "Access-Control-Allow-Origin": req.headers.get("origin") ?? "*",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Content-Type": "application/json; charset=utf-8",
    "Cache-Control": "no-store",
  };
}
const json = (req: Request, body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: cabeceras(req) });

/** Llamada a la API de Mercado Pago. Devuelve null si algo falla. */
async function mp(token: string, path: string, init: RequestInit = {}) {
  const r = await fetch(MP + path, {
    ...init,
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
      ...(init.headers ?? {}),
    },
  });
  if (!r.ok) {
    console.error("MP", path, r.status, (await r.text()).slice(0, 400));
    return null;
  }
  return await r.json();
}

/** +1 mes sobre hoy, en 'YYYY-MM-DD' (formato de la columna date). */
function masUnMes(): string {
  const d = new Date();
  d.setUTCMonth(d.getUTCMonth() + 1);
  return d.toISOString().slice(0, 10);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cabeceras(req) });
  if (req.method !== "POST") return json(req, { error: "Método no permitido." }, 405);

  const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
  const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
  const TOKEN = Deno.env.get("MP_ACCESS_TOKEN");
  const MONTO = Number(Deno.env.get("MP_PLAN_AMOUNT") || "129000");
  const ORIGEN = Deno.env.get("APP_ORIGIN") || req.headers.get("origin") || SUPABASE_URL;

  /* 1 ─ quién es. verify_jwt ya firmó el token; esto lo confirma y
         da el id. El cliente solo puede leer su propia fila (RLS). */
  const auth = req.headers.get("Authorization") ?? "";
  const comoUsuario = createClient(SUPABASE_URL, ANON, {
    global: { headers: { Authorization: auth } },
  });
  const { data: { user }, error: uErr } = await comoUsuario.auth.getUser();
  if (uErr || !user) return json(req, { error: "Sesión inválida. Vuelve a entrar." }, 401);

  /* Mercado Pago exige siempre el email del pagador. En producción es el
     del propio cliente (lo deja en blanco MP y MP crea invitado); en
     pruebas se fija con MP_PAYER_EMAIL porque el cobrador de esta cuenta
     es un usuario de prueba y entonces el pagador también debe serlo.
     ⚠️ QUITAR MP_PAYER_EMAIL al pasar a credenciales reales. */
  const PAGADOR = Deno.env.get("MP_PAYER_EMAIL") || user.email || "";

  if (!TOKEN)
    return json(req, { error: "Los pagos aún no están configurados en el servidor.", codigo: "sin_configurar" }, 503);
  if (!(MONTO > 0))
    return json(req, { error: "Monto del plan mal configurado (MP_PLAN_AMOUNT).", codigo: "monto_invalido" }, 503);

  let accion = "checkout";
  try {
    const b = await req.json();
    if (b && typeof b.action === "string") accion = b.action;
  } catch { /* sin cuerpo: por defecto checkout */ }
  if (accion !== "checkout" && accion !== "sync")
    return json(req, { error: "Acción no reconocida: " + accion }, 400);

  try {
    /* ── SINCRONIZACIÓN ──────────────────────────────────────────────
       Se usa cuando el cliente vuelve del checkout con ?pago=ok, y
       también como red de seguridad si el webhook no llega. Pregunta a
       Mercado Pago el estado REAL de la suscripción y actualiza el plan
       con service role. El navegador no manda nada: no puede elegir id
       ni estado, el id sale del token y el estado lo dicta MP. */
    if (accion === "sync") {
      const admin = createClient(SUPABASE_URL, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
      const { data: prof } = await admin
        .from("profiles").select("mp_preapproval_id, plan_status, plan_next_charge").eq("id", user.id).maybeSingle();
      if (!prof?.mp_preapproval_id)
        return json(req, { ok: true, aviso: "sin_suscripcion" });

      const sub = await mp(TOKEN, `/preapproval/${prof.mp_preapproval_id}`);
      if (!sub)
        return json(req, { ok: false, error: "No se pudo consultar tu suscripción en Mercado Pago." }, 502);
      if (sub.external_reference !== user.id)
        return json(req, { ok: true, aviso: "referencia_no_coincide" });

      const estado = String(sub.status ?? "");
      let plan: "active" | "overdue" | null = null;
      if (estado === "authorized") plan = "active";
      else if (["cancelled", "rejected", "expired", "paused"].includes(estado)) plan = "overdue";

      if (!plan)
        return json(req, { ok: true, estado_mp: estado, aviso: "aun_pendiente",
                           plan_status: prof.plan_status, plan_next_charge: prof.plan_next_charge });

      const proximo = (sub.auto_recurring?.next_payment_date as string | undefined) || "";
      const cambios: Record<string, unknown> = { plan_status: plan, mp_preapproval_id: sub.id };
      if (plan === "active") cambios.plan_next_charge = proximo ? proximo.slice(0, 10) : masUnMes();

      const { error: sErr } = await admin.from("profiles").update(cambios).eq("id", user.id);
      if (sErr) return json(req, { ok: false, error: "No se pudo actualizar tu plan." }, 500);

      return json(req, { ok: true, estado_mp: estado, plan_status: plan,
                         plan_next_charge: cambios.plan_next_charge ?? prof.plan_next_charge });
    }

    /* 2 ─ ¿ya tiene una suscripción? Si la de MP sigue viva, se
           reutiliza en vez de crear una duplicada. */
    const { data: perfil, error: pErr } = await comoUsuario
      .from("profiles")
      .select("mp_preapproval_id")
      .eq("id", user.id)
      .maybeSingle();
    if (pErr) return json(req, { error: "No se pudo leer tu perfil." }, 500);

    if (perfil?.mp_preapproval_id) {
      const sub = await mp(TOKEN, `/preapproval/${perfil.mp_preapproval_id}`);
      // el external_reference debe ser SIEMPRE el propio usuario: si no
      // coincide, ese id no nos pertenece y se ignora.
      if (sub && sub.external_reference === user.id) {
        if (sub.status === "authorized")
          return json(req, { estado: "activo", detalle: "Tu suscripción ya está activa." });
        // MP ya no tiene entorno sandbox: siempre init_point (LOCK 3 oficiales)
        if (sub.init_point) return json(req, { url: sub.init_point, estado: sub.status, reutilizada: true });
      }
    }

    /* 3 ─ crear la suscripción en Mercado Pago */
    const creado = await mp(TOKEN, "/preapproval", {
      method: "POST",
      body: JSON.stringify({
        reason: "Optiluxen · Plan Pro mensual",
        external_reference: user.id,
        payer_email: PAGADOR,
        back_url: `${ORIGEN}/?pago=ok`,
        notification_url: `${SUPABASE_URL}/functions/v1/mp-webhook`,
        auto_recurring: {
          frequency: 1,
          frequency_type: "months",
          transaction_amount: MONTO,
          currency_id: "COP",
          billing_day_proportional: false,
        },
      }),
    });
    if (!creado)
      return json(req, { error: "Mercado Pago rechazó la solicitud. Revisa las credenciales.", codigo: "mp_error" }, 502);

    // MP ya no tiene entorno sandbox: siempre init_point
    const enlace = creado.init_point;
    if (!enlace)
      return json(req, { error: "Mercado Pago no devolvió un enlace de pago.", codigo: "sin_enlace" }, 502);

    /* 4 ─ guarda el id de la suscripción (columna concedida). Si el
         guardado falla, el pago igualmente sigue: el webhook activa
         el plan leyendo external_reference, no esta columna. */
    const { error: gErr } = await comoUsuario
      .from("profiles").update({ mp_preapproval_id: creado.id }).eq("id", user.id);
    if (gErr) console.error("no se guardó mp_preapproval_id:", gErr.message);

    return json(req, { url: enlace, estado: creado.status, id: creado.id });
  } catch (e) {
    console.error("mp-billing:", e);
    return json(req, { error: "No se pudo iniciar el pago." }, 500);
  }
});
