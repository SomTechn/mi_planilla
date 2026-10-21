import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

// Registro público de empresas nuevas en Mi Planilla (prueba gratis).
// Crea la cuenta del administrador y la empresa con sus conceptos y reglas por defecto.
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });
const limpio = (v: unknown, max = 120) => String(v ?? "").trim().slice(0, max);

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Método no permitido" }, 405);
  try {
    const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
    const b = await req.json().catch(() => ({}));
    if (b.sitio) return json({ ok: true });   // campo trampa para bots

    const empresa = limpio(b.empresa), nombre = limpio(b.nombre), telefono = limpio(b.telefono, 30), rtn = limpio(b.rtn, 30);
    const correo = limpio(b.correo, 160).toLowerCase(), password = String(b.password ?? "");
    if (empresa.length < 2) return json({ error: "Escribe el nombre de tu empresa" }, 400);
    if (nombre.length < 3) return json({ error: "Escribe tu nombre completo" }, 400);
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(correo)) return json({ error: "Correo inválido" }, 400);
    if (password.length < 8) return json({ error: "La contraseña debe tener al menos 8 caracteres" }, 400);
    if (telefono.replace(/\D/g, "").length < 8) return json({ error: "Escribe un teléfono de contacto" }, 400);

    // freno simple contra abuso
    const hace1h = new Date(Date.now() - 3600_000).toISOString();
    const { count } = await admin.from("pl_empresas").select("id", { count: "exact", head: true }).gte("creado_en", hace1h);
    if ((count ?? 0) >= 20) return json({ error: "Demasiados registros en este momento. Intenta en un rato." }, 429);

    const { data, error } = await admin.auth.admin.createUser({
      email: correo, password, email_confirm: true, user_metadata: { nombre, app: "planilla", empresa },
    });
    if (error) {
      if (/already|registered|exists/i.test(error.message)) return json({ error: "Ese correo ya tiene una cuenta. Ingresa con él o usa otro correo." }, 400);
      return json({ error: error.message }, 400);
    }
    const { data: empId, error: e2 } = await admin.rpc("pl_alta_empresa", {
      p_user: data.user.id, p_empresa: empresa, p_rtn: rtn, p_telefono: telefono, p_nombre: nombre, p_correo: correo,
    });
    if (e2) {
      await admin.auth.admin.deleteUser(data.user.id);
      return json({ error: e2.message }, 400);
    }
    return json({ ok: true, empresa_id: empId });
  } catch (e) {
    return json({ error: (e as Error).message }, 400);
  }
});
