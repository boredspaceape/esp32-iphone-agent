// phone-queue: a tiny task queue between an outside agent and the Phone Agent app fork.
// URL: https://<ref>.supabase.co/functions/v1/phone-queue  (deployed with verify_jwt off: it checks its own tokens)
// Tokens: two bearer tokens, stored only as SHA-256 hashes in the queue_tokens table (role phone / agent).
//
// Phone (the app's Remote tasks setting, and the Shortcuts Message automation):
//   POST /task    {}                       -> {"task": {"id", "text"}} or {}
//   POST /result  {"id","outcome","answer","steps","seconds","run"} -> {"ok": true}
//   POST /message {"sender","text"}        -> {"ok": true}
//   POST /poll {} -> {} and POST /upload -> ok   (the app's remote debug log, if pointed here)
// Agent:
//   POST /enqueue  {"text", "timeout_minutes"?} -> {"id"}
//   POST /get      {"id"}                       -> the task row (status, answer, ...)
//   POST /messages {}                           -> {"messages": [...]} unseen texts, then marked seen
import { createClient } from "npm:@supabase/supabase-js@2";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { persistSession: false } });
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { "content-type": "application/json" } });

async function sha256(text: string) {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
function same(a: string, b: string) {  // constant-time compare of equal-length hex
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

let hashes: { role: string; token_sha256: string }[] | null = null;
let loadedAt = 0;
async function roleOf(token: string): Promise<string | null> {
  if (token.length < 32) return null;
  if (!hashes || Date.now() - loadedAt > 60_000) {
    const { data } = await db.from("queue_tokens").select("role,token_sha256");
    hashes = data ?? [];
    loadedAt = Date.now();
  }
  const h = await sha256(token);
  let role: string | null = null;
  for (const r of hashes) if (same(h, r.token_sha256)) role = r.role;
  return role;
}

async function body(req: Request) {
  try { return await req.json(); } catch { return {}; }
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  const route = new URL(req.url).pathname.split("/").pop();
  const token = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  const role = await roleOf(token);
  if (!role) return json({ error: "unauthorized" }, 401);

  if (role === "phone") {
    switch (route) {
      case "poll": return json({});
      case "upload": return json({ ok: true });
      case "task": {
        const { data, error } = await db.rpc("claim_task", { lease_seconds: 900 });
        if (error) return json({ error: "queue error" }, 500);
        const t = Array.isArray(data) ? data[0] : null;
        return t ? json({ task: { id: t.task_id, text: t.task_text } }) : json({});
      }
      case "result": {
        const r = await body(req);
        if (typeof r.id !== "string") return json({ error: "id required" }, 400);
        const { data, error } = await db.rpc("finish_task", {
          p_id: r.id, p_outcome: String(r.outcome ?? "unknown"), p_answer: String(r.answer ?? ""),
          p_steps: Number.isFinite(r.steps) ? r.steps : null, p_seconds: Number.isFinite(r.seconds) ? r.seconds : null,
          p_run: String(r.run ?? ""),
        });
        if (error) return json({ error: "queue error" }, 500);
        return data ? json({ ok: true }) : json({ ok: true, note: "unknown id" });  // 200 so the app stops retrying
      }
      case "message": {
        const r = await body(req);
        const { error } = await db.from("phone_messages").insert({
          sender: String(r.sender ?? "").slice(0, 200), text: String(r.text ?? "").slice(0, 5000),
        });
        return error ? json({ error: "store error" }, 500) : json({ ok: true });
      }
    }
  }

  if (role === "agent") {
    switch (route) {
      case "enqueue": {
        const r = await body(req);
        const text = String(r.text ?? "").trim();
        if (!text || text.length > 2000) return json({ error: "text required, max 2000 chars" }, 400);
        const minutes = Math.min(Math.max(Number(r.timeout_minutes) || 45, 2), 180);
        const deadline = new Date(Date.now() + minutes * 60_000).toISOString();
        const { data, error } = await db.from("phone_tasks").insert({ text, deadline }).select("id").single();
        return error ? json({ error: "queue error" }, 500) : json({ id: data.id });
      }
      case "get": {
        const r = await body(req);
        const { data, error } = await db.rpc("get_task", { p_id: String(r.id ?? "") });
        if (error) return json({ error: "queue error" }, 500);
        const row = Array.isArray(data) ? data[0] : null;
        return row ? json(row) : json({ error: "not found" }, 404);
      }
      case "messages": {
        const { data } = await db.from("phone_messages").select("*").eq("seen", false).order("received_at").limit(200);
        if (data?.length) await db.from("phone_messages").update({ seen: true }).in("id", data.map((m) => m.id));
        return json({ messages: data ?? [] });
      }
    }
  }
  return json({ error: "not found" }, 404);
});
