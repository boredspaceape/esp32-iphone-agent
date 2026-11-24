-- 2026-11-24: a late /result no longer overwrites a timed-out or stopped task (it is kept in late_*).
-- For a database made from an older schema.sql. Safe to run twice. Run in the Supabase SQL editor.

alter table phone_tasks add column if not exists late_outcome text;
alter table phone_tasks add column if not exists late_answer  text;
alter table phone_tasks add column if not exists late_at      timestamptz;

create or replace function finish_task(p_id text, p_outcome text, p_answer text, p_steps int, p_seconds int, p_run text)
returns boolean
language sql security definer set search_path = public as $$
  update phone_tasks t set
         status      = case when t.status in ('queued', 'taken') then left(coalesce(p_outcome, 'unknown'), 20) else t.status end,
         answer      = case when t.status in ('queued', 'taken') then left(coalesce(p_answer, ''), 20000) else t.answer end,
         steps       = case when t.status in ('queued', 'taken') then p_steps else t.steps end,
         seconds     = case when t.status in ('queued', 'taken') then p_seconds else t.seconds end,
         run         = case when t.status in ('queued', 'taken') then left(p_run, 100) else t.run end,
         finished_at = case when t.status in ('queued', 'taken') then now() else t.finished_at end,
         late_outcome = case when t.status in ('queued', 'taken') then t.late_outcome else left(coalesce(p_outcome, 'unknown'), 20) end,
         late_answer  = case when t.status in ('queued', 'taken') then t.late_answer else left(coalesce(p_answer, ''), 20000) end,
         late_at      = case when t.status in ('queued', 'taken') then t.late_at else now() end,
         lease_until = null
   where t.id = p_id
  returning true;
$$;

revoke all on function finish_task(text, text, text, int, int, text) from public, anon, authenticated;
grant execute on function finish_task(text, text, text, int, int, text) to service_role;
