# phone-queue (fork)

A tiny task queue between an outside agent and the Phone Agent app's Remote tasks setting, plus incoming
texts from an iOS Shortcuts Message automation. Supabase (free tier): `schema.sql` + the `phone-queue`
Edge Function, deployed with JWT verification off (it checks its own bearer tokens).

- Tokens: two random tokens (role `phone`, role `agent`), stored only as SHA-256 hex in `queue_tokens`.
  `insert into queue_tokens values ('phone', '<sha256 hex>'), ('agent', '<sha256 hex>');`
- RLS on, no policies, no grants to anon/authenticated: only the function (service role) reads the tables.
- Lease: a task handed out with no result in 15 min is offered once more; after 2 tries, or past its
  deadline (default 45 min, `timeout_minutes` 2–180 on enqueue), it is marked `failed` ("timed out").
- A result that arrives after that (or a second one) doesn't change the status: it is kept in `late_outcome`,
  `late_answer`, `late_at`. Existing databases: run `migrations/2026-11-24-late-results.sql`.
- Routes and bodies: see the top of `index.ts`. The app side: `docs/remote-debug-log.md` › Remote tasks.
