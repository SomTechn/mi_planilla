// Mi Planilla · notificaciones push.
// - POST desde la base (cabecera x-pl-secreto) con { ids, title, body, url, tag }: envía el aviso a los teléfonos de esas cuentas.
// - POST { clave:true }: devuelve la clave pública VAPID (la misma del proyecto).
// - POST { prueba:true } con la sesión del usuario: envía un aviso de prueba a sus teléfonos.
import webpush from 'npm:web-push@3.6.7';
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';

const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
const CORS = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type', 'Access-Control-Allow-Methods': 'POST, OPTIONS' };
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });

let cfg: Record<string, string> | null = null;
async function config() {
  if (cfg) return cfg;
  const { data, error } = await sb.rpc('push_config_get'); if (error) throw error;
  const c = (data || {}) as Record<string, string>;
  if (!c.publica || !c.privada) throw new Error('Faltan las claves VAPID');
  webpush.setVapidDetails('https://edmvfqelxsxevpmxgbav.supabase.co', c.publica, c.privada);
  return (cfg = c);
}

async function enviar(ids: string[], msg: { title: string; body: string; url?: string; tag?: string }) {
  ids = [...new Set(ids.filter(Boolean))];
  if (!ids.length) return 0;
  await config();
  const { data: subs, error } = await sb.from('pl_push_subs').select('*').in('user_id', ids);
  if (error) throw error;
  const payload = JSON.stringify({ title: msg.title, body: msg.body, url: msg.url || '#/', tag: msg.tag || 'pl' });
  let ok = 0;
  await Promise.all((subs || []).map(async (s) => {
    try {
      await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload, { TTL: 86400, urgency: 'high' });
      ok++;
    } catch (e) {
      const st = (e as { statusCode?: number }).statusCode;
      if (st === 404 || st === 410) await sb.from('pl_push_subs').delete().eq('endpoint', s.endpoint);   // teléfono dado de baja
      else console.error('push', st, (e as Error).message);
    }
  }));
  return ok;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  try {
    const body = await req.json().catch(() => ({}));
    const sec = req.headers.get('x-pl-secreto');
    if (sec) {
      const c = await config();
      if (sec !== c.secreto) return json({ error: 'secreto inválido' }, 401);
      return json({ enviados: await enviar(body.ids || [], body) });
    }
    if (body.clave) return json({ publica: (await config()).publica });
    if (body.prueba) {
      const jwt = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '');
      const { data: u, error } = await sb.auth.getUser(jwt);
      if (error || !u?.user) return json({ error: 'Sesión no válida' }, 401);
      const n = await enviar([u.user.id], { title: '🔔 Notificaciones activadas', body: 'Así te avisaremos de tus pagos y solicitudes.', url: '#/', tag: 'prueba' });
      return json({ enviados: n });
    }
    return json({ error: 'Solicitud no reconocida' }, 400);
  } catch (e) {
    console.error(e);
    return json({ error: (e as Error).message }, 500);
  }
});
