-- phone-agent-queue: a tiny task queue between an outside agent and the Phone Agent app fork,
-- plus incoming texts from the iOS Shortcuts Message automation.
-- Every table has RLS on with no policies and no grants for anon/authenticated: only the phone-queue
-- Edge Function (service role) touches them. Tokens are stored only as SHA-256 hashes.

create extension if not exists pgcrypto;

create table if not exists phone_tasks (
  id          text primary key default substr(md5(gen_random_uuid()::text), 1, 12),
  text        text not null,
  status      text not null default 'queued',   -- queued | taken | done | failed | stopped | not_started | unknown
  answer      text,
  steps       int,
  seconds     int,
  run         text,
  attempts    int not null default 0,           -- times handed to the phone
  lease_until timestamptz,                      -- taken but no result by then: offered again (once)
  deadline    timestamptz not null default now() + interval '45 minutes',  -- overall: then marked failed
  created_at  timestamptz not null default now(),
  taken_at    timestamptz,
  finished_at timestamptz
);

create table if not exists phone_messages (
  id          bigint generated always as identity primary key,
  sender      text,
  text        text,
  received_at timestamptz not null default now(),
  seen        boolean not null default false
);

-- role: 'phone' (the app and the Shortcut) or 'agent' (the outside agent). sha256 hex of the bearer token.
create table if not exists queue_tokens (
  role         text primary key check (role in ('phone', 'agent')),
  token_sha256 text not null
);

alter table phone_tasks    enable row level security;
alter table phone_messages enable row level security;
alter table queue_tokens   enable row level security;
revoke all on phone_tasks, phone_messages, queue_tokens from anon, authenticated;

-- Times out what's overdue, then hands out the oldest queued task, or one whose lease ran out (2 tries max).
create or replace function claim_task(lease_seconds int default 900)
returns table (task_id text, task_text text)
language plpgsql security definer set search_path = public as $$
begin
  update phone_tasks t set status = 'failed', answer = coalesce(t.answer, 'timed out: no result from the phone'),
         finished_at = now()
   where t.status in ('queued', 'taken')
     and (t.deadline < now() or (t.status = 'taken' and t.lease_until < now() and t.attempts >= 2));
  return query
  update phone_tasks t set status = 'taken', attempts = t.attempts + 1, taken_at = now(),
         lease_until = now() + make_interval(secs => lease_seconds)
   where t.id = (select q.id from phone_tasks q
                  where q.status = 'queued' or (q.status = 'taken' and q.lease_until < now())
                  order by q.created_at limit 1 for update skip locked)
  returning t.id, t.text;
end $$;

-- A result from the phone. Accepted even after a timeout (a late answer beats none).
create or replace function finish_task(p_id text, p_outcome text, p_answer text, p_steps int, p_seconds int, p_run text)
returns boolean
language sql security definer set search_path = public as $$
  update phone_tasks set status = left(coalesce(p_outcome, 'unknown'), 20), answer = left(coalesce(p_answer, ''), 20000),
         steps = p_steps, seconds = p_seconds, run = left(p_run, 100), lease_until = null, finished_at = now()
   where id = p_id
  returning true;
$$;

-- The agent reads a task; overdue ones are marked failed first so the status is current.
create or replace function get_task(p_id text)
returns setof phone_tasks
language plpgsql security definer set search_path = public as $$
begin
  update phone_tasks t set status = 'failed', answer = coalesce(t.answer, 'timed out: no result from the phone'),
         finished_at = now()
   where t.id = p_id and t.status in ('queued', 'taken') and t.deadline < now();
  return query select * from phone_tasks where phone_tasks.id = p_id;
end $$;

revoke all on function claim_task(int), finish_task(text, text, text, int, int, text), get_task(text) from public, anon, authenticated;
grant execute on function claim_task(int), finish_task(text, text, text, int, int, text), get_task(text) to service_role;
