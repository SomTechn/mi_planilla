import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

// Cuentas de acceso de empleados para la app de Planilla.
// La autenticación se valida aquí mismo (token del usuario + rol admin de planilla de SU empresa).
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });
const DOMINIO = "planilla.maspisto.hn";
const aEmail = (u: string) => {
  const t = (u || "").trim().toLowerCase();
  return t.includes("@") ? t : `${t}@${DOMINIO}`;
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
    const token = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    const { data: u } = await admin.auth.getUser(token);
    if (!u?.user) return json({ error: "No autenticado" }, 401);
    const uid = u.user.id;

    // empresa de una cuenta (miembro explícito o, si es del ecosistema, la principal)
    const empresaDe = async (id: string): Promise<string | null> => {
      const { data, error } = await admin.rpc("pl_empresa_de", { p_uid: id });
      if (error) throw new Error(error.message);
      return (data as string) || null;
    };
    const { data: principal } = await admin.rpc("pl_empresa_principal");
    const miEmpresa = await empresaDe(uid);
    if (!miEmpresa) return json({ error: "Tu cuenta no pertenece a ninguna empresa" }, 403);

    const { data: perf } = await admin.from("perfiles").select("rol, activo").eq("id", uid).maybeSingle();
    const { data: pla } = await admin.from("pl_admins").select("user_id").eq("user_id", uid).eq("empresa_id", miEmpresa).maybeSingle();
    const esAdminCred = !!perf && perf.rol === "admin" && perf.activo && miEmpresa === principal;
    if (!esAdminCred && !pla) return json({ error: "Solo administradores de planilla" }, 403);

    const body = await req.json().catch(() => ({}));
    const accion = body.accion;
    const empId = body.empleado_id;
    if (!empId) return json({ error: "Falta empleado" }, 400);
    const { data: emp, error: eErr } = await admin.from("pl_empleados").select("id, nombre, user_id, usuario, empresa_id").eq("id", empId).single();
    if (eErr || !emp || emp.empresa_id !== miEmpresa) return json({ error: "Empleado no encontrado" }, 404);

    const buscarPorEmail = async (email: string) => {
      for (let page = 1; page <= 20; page++) {
        const { data, error } = await admin.auth.admin.listUsers({ page, perPage: 200 });
        if (error) throw new Error(error.message);
        const f = data.users.find((x) => (x.email || "").toLowerCase() === email);
        if (f) return f;
        if (data.users.length < 200) break;
      }
      return null;
    };
    const unirAEmpresa = async (userId: string) => {
      const { error } = await admin.from("pl_miembros").upsert({ user_id: userId, empresa_id: miEmpresa }, { onConflict: "user_id" });
      if (error) throw new Error(error.message);
    };

    if (accion === "crear") {
      if (emp.user_id) return json({ error: "El empleado ya tiene usuario" }, 400);
      const usuario = (body.usuario || "").trim().toLowerCase();
      if (!/^[a-z0-9._@-]{3,}$/.test(usuario)) return json({ error: "Usuario inválido (mín. 3; letras, números, punto, guion)" }, 400);
      if (!body.password || body.password.length < 6) return json({ error: "Contraseña mínima de 6 caracteres" }, 400);
      const email = aEmail(usuario);
      const { data, error } = await admin.auth.admin.createUser({ email, password: body.password, email_confirm: true, user_metadata: { nombre: emp.nombre, app: "planilla" } });
      if (error) {
        if (/already|registered|exists/i.test(error.message)) return json({ error: "Ese usuario ya está en uso. Prueba agregando una parte del nombre de tu empresa (ej. juan.miempresa)." }, 400);
        return json({ error: error.message }, 400);
      }
      try {
        await unirAEmpresa(data.user.id);
        const { error: e2 } = await admin.from("pl_empleados").update({ user_id: data.user.id, usuario }).eq("id", emp.id);
        if (e2) throw new Error(e2.message);
      } catch (e) {
        await admin.auth.admin.deleteUser(data.user.id);
        return json({ error: (e as Error).message }, 400);
      }
      return json({ ok: true, usuario });
    }

    if (accion === "vincular") {
      const email = aEmail(body.email || "");
      const f = await buscarPorEmail(email);
      if (!f) return json({ error: "No existe una cuenta con ese correo" }, 404);
      const suya = await empresaDe(f.id);
      if (suya && suya !== miEmpresa) return json({ error: "Esa cuenta pertenece a otra empresa" }, 400);
      const { data: otro } = await admin.from("pl_empleados").select("nombre").eq("user_id", f.id).neq("id", emp.id).maybeSingle();
      if (otro) return json({ error: `Esa cuenta ya está vinculada a ${otro.nombre}` }, 400);
      if (!suya) await unirAEmpresa(f.id);
      const { error } = await admin.from("pl_empleados").update({ user_id: f.id, usuario: email.endsWith("@" + DOMINIO) ? email.split("@")[0] : email }).eq("id", emp.id);
      if (error) return json({ error: error.message }, 400);
      return json({ ok: true });
    }

    if (accion === "password") {
      if (!emp.user_id) return json({ error: "El empleado no tiene usuario" }, 400);
      if (!body.password || body.password.length < 6) return json({ error: "Contraseña mínima de 6 caracteres" }, 400);
      const { data: p2 } = await admin.from("perfiles").select("rol").eq("id", emp.user_id).maybeSingle();
      if (p2 && !esAdminCred) return json({ error: "Esa cuenta es de VerifiCrédito; solo el administrador general puede cambiarla" }, 403);
      const { error } = await admin.auth.admin.updateUserById(emp.user_id, { password: body.password });
      if (error) return json({ error: error.message }, 400);
      return json({ ok: true });
    }

    if (accion === "desvincular") {
      if (!emp.user_id) return json({ ok: true });
      const userId = emp.user_id;
      await admin.from("pl_empleados").update({ user_id: null, usuario: null }).eq("id", emp.id);
      // Si la cuenta fue creada solo para planilla, se elimina (y con ella su membresía)
      const { data: p2 } = await admin.from("perfiles").select("id").eq("id", userId).maybeSingle();
      const { data: au } = await admin.auth.admin.getUserById(userId);
      const { data: esAdm } = await admin.from("pl_admins").select("user_id").eq("user_id", userId).maybeSingle();
      if (!p2 && !esAdm && (au?.user?.email || "").endsWith("@" + DOMINIO)) await admin.auth.admin.deleteUser(userId);
      return json({ ok: true });
    }

    return json({ error: "Acción desconocida" }, 400);
  } catch (e) {
    return json({ error: (e as Error).message }, 400);
  }
});
