-- AI metering for the iPad app (1.4.0). The app sends provider requests through the
-- ai-proxy Edge Function; this schema holds model prices, per-user monthly budgets,
-- credits, task caps, consent records and the App Store entitlements that pick the plan.
-- Units: µ¢ (1 µ¢ = $1e-8). Prices are µ¢ per token (= $/MTok × 100).
-- Only service_role (the Edge Functions) reads or writes; the app never touches these tables.
begin;

create table public.ai_models(
  id text primary key check (id ~ '^[a-z0-9][a-z0-9.-]{0,63}$'),
  provider text not null check (provider in ('anthropic','openai')),
  label text not null check (length(label) between 1 and 40),
  p_in numeric not null check (p_in >= 0),
  p_out numeric not null check (p_out >= 0),
  p_cache_r numeric not null check (p_cache_r >= 0),
  p_cache_w numeric not null default 0 check (p_cache_w >= 0),
  context_cap integer not null check (context_cap between 1000 and 1000000),
  enabled boolean not null default true,
  sort integer not null default 0
);

create table public.ai_settings(
  id boolean primary key default true check (id),
  auto_model text not null references public.ai_models(id),
  auto_context integer not null check (auto_context > 0),
  free_cap bigint not null check (free_cap >= 0),
  plus_cap bigint not null check (plus_cap >= 0),
  pro_cap bigint not null check (pro_cap >= 0),
  trial_cap bigint not null check (trial_cap >= 0),
  plus_task_cap bigint not null check (plus_task_cap > 0),
  pro_task_cap bigint not null check (pro_task_cap > 0),
  pack_ucents bigint not null check (pack_ucents > 0),
  auto_question_ucents bigint not null check (auto_question_ucents > 0),
  max_output_tokens integer not null check (max_output_tokens between 256 and 128000),
  min_output_tokens integer not null check (min_output_tokens between 1 and 4096),
  consent_version integer not null check (consent_version > 0)
);

create table public.ipad_entitlements(
  environment text not null check (environment in ('production','sandbox')),
  original_transaction_id text not null check (original_transaction_id ~ '^[0-9]{1,32}$'),
  user_id uuid not null references auth.users(id) on delete cascade,
  product_id text not null,
  plan text not null check (plan in ('plus','pro')),
  is_trial boolean not null default false,
  expires_at timestamptz not null,
  revoked_at timestamptz,
  signed_at timestamptz not null,
  updated_at timestamptz not null default now(),
  primary key (environment, original_transaction_id)
);
create index ipad_entitlements_user on public.ipad_entitlements(user_id);

create table public.ai_budget(
  user_id uuid not null references auth.users(id) on delete cascade,
  period text not null check (period ~ '^[0-9]{4}-[0-9]{2}$'),
  spent_ucents bigint not null default 0,
  primary key (user_id, period)
);

create table public.ai_credit(
  user_id uuid primary key references auth.users(id) on delete cascade,
  balance_ucents bigint not null default 0
);

-- One row per grant so a pack transaction or a referral is never paid twice.
create table public.ai_credit_grants(
  source text not null check (source in ('pack','referral','manual')),
  ref text not null check (length(ref) between 1 and 128),
  user_id uuid not null references auth.users(id) on delete cascade,
  amount_ucents bigint not null check (amount_ucents > 0),
  granted_at timestamptz not null default now(),
  revoked_at timestamptz,
  primary key (source, ref)
);

create table public.ai_task(
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  cost_ucents bigint not null default 0,
  steps integer not null default 0,
  started_at timestamptz not null default now()
);

-- Held between ai_begin and ai_settle so parallel steps cannot overspend; a step that
-- never settles stops counting after RESERVATION_TTL (5 minutes, longer than any step).
create table public.ai_reservation(
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  task_id uuid not null references public.ai_task(id) on delete cascade,
  amount_ucents bigint not null check (amount_ucents >= 0),
  created_at timestamptz not null default now()
);
create index ai_reservation_user on public.ai_reservation(user_id, created_at);

create table public.ai_usage_ledger(
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  ts timestamptz not null default now(),
  task_id uuid,
  model text not null,
  effort text,
  kind text not null,
  tokens_in bigint not null default 0,
  tokens_out bigint not null default 0,
  tokens_cache_r bigint not null default 0,
  tokens_cache_w bigint not null default 0,
  cost_ucents bigint not null,
  complete boolean not null
);
create index ai_usage_ledger_user_ts on public.ai_usage_ledger(user_id, ts);

create table public.ai_consent(
  user_id uuid not null references auth.users(id) on delete cascade,
  provider text not null check (provider in ('anthropic','openai')),
  version integer not null check (version > 0),
  agreed_at timestamptz not null default now(),
  primary key (user_id, provider)
);

do $$ declare t text; begin
  foreach t in array array['ai_models','ai_settings','ipad_entitlements','ai_budget','ai_credit','ai_credit_grants','ai_task','ai_reservation','ai_usage_ledger','ai_consent'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from public, anon, authenticated', t);
    execute format('grant all on public.%I to service_role', t);
  end loop;
end $$;

-- Prices: Anthropic and OpenAI list prices on 2026-11-06. Cache writes = 1.25× input
-- (Anthropic 5-minute TTL); OpenAI has no write charge. Opus 5.5 stays off until chosen.
insert into public.ai_models(id, provider, label, p_in, p_out, p_cache_r, p_cache_w, context_cap, enabled, sort) values
  ('claude-haiku-5-5',  'anthropic', 'Claude Haiku 5.5',  10,   50,   1,   12.5, 100000, true,  10),
  ('claude-sonnet-5-5', 'anthropic', 'Claude Sonnet 5.5', 200,  1000, 20,  250,  100000, true,  20),
  ('claude-opus-5-5',   'anthropic', 'Claude Opus 5.5',   400,  2000, 20,  500,  100000, false, 30),
  ('gpt-6-luna',        'openai',    'GPT-6 Luna',        10,   50,   1,   0,    100000, true,  40),
  ('gpt-6-sol',         'openai',    'GPT-6 Sol',         200,  1000, 20,  0,    100000, true,  50),
  ('gpt-6-astra',       'openai',    'GPT-6 Astra',       1000, 5000, 100, 0,    100000, true,  60);

-- Budgets: free $0.02, Plus $0.30, Pro $1.20, any trial $0.30; task caps Plus $0.10 / Pro $0.50;
-- a pack grants $2.00 (spec open item, recommended value); one Auto question ≈ $0.0007.
insert into public.ai_settings values
  (true, 'claude-haiku-5-5', 30000, 2000000, 30000000, 120000000, 30000000, 10000000, 50000000, 200000000, 70000, 8192, 256, 1);

create function public.ai_period() returns text language sql stable set search_path = '' as $$
  select to_char(now() at time zone 'Asia/Seoul', 'YYYY-MM')
$$;

create function public.ai_status(actor uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare s public.ai_settings; e record; plan text := 'none'; trial boolean := false;
  cap bigint; task_cap bigint; spent bigint; credit bigint; reserved bigint; remaining bigint; consents jsonb;
begin
  if actor is null then raise exception 'sign_in_required' using errcode = '42501'; end if;
  select * into strict s from public.ai_settings;
  -- Pro > Plus. Sandbox rows come only from TestFlight/dev builds, which only invited testers run.
  select x.plan, x.is_trial into e from public.ipad_entitlements x
    where x.user_id = actor and x.revoked_at is null and x.expires_at > now()
    order by (x.plan = 'pro') desc, x.is_trial asc limit 1;
  if found then plan := e.plan; trial := e.is_trial; end if;
  cap := case when trial then s.trial_cap when plan = 'pro' then s.pro_cap when plan = 'plus' then s.plus_cap else s.free_cap end;
  task_cap := case when plan = 'pro' and not trial then s.pro_task_cap when plan = 'none' then s.free_cap else s.plus_task_cap end;
  select coalesce((select b.spent_ucents from public.ai_budget b where b.user_id = actor and b.period = public.ai_period()), 0) into spent;
  select coalesce((select c.balance_ucents from public.ai_credit c where c.user_id = actor), 0) into credit;
  select coalesce(sum(r.amount_ucents), 0) into reserved from public.ai_reservation r
    where r.user_id = actor and r.created_at > now() - interval '5 minutes';
  remaining := greatest(greatest(cap - spent, 0) + greatest(credit, 0) - reserved, 0);
  select coalesce(jsonb_object_agg(c.provider, c.version), '{}'::jsonb) into consents from public.ai_consent c where c.user_id = actor;
  return jsonb_build_object(
    'plan', plan, 'trial', trial, 'period', public.ai_period(),
    'capUcents', cap, 'spentUcents', spent, 'creditUcents', credit, 'reservedUcents', reserved, 'remainingUcents', remaining,
    'taskCapUcents', task_cap,
    'percent', case when cap = 0 then 100 else least(100, (spent * 100) / cap) end,
    'autoQuestionsLeft', remaining / s.auto_question_ucents,
    'consents', consents, 'consentVersion', s.consent_version);
end $$;

-- Called before every upstream step. Under the user's lock it sizes the step's output
-- to what is left (month budget + credit − other open reservations, and the task cap),
-- reserves input + that output at list price, and returns the output limit to send.
-- Refuses when less than min_output_tokens would fit.
create function public.ai_begin(actor uuid, task uuid, step uuid, model_id text, input_tokens bigint, max_output integer) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare st jsonb; m public.ai_models; s public.ai_settings; owner uuid; task_used bigint; input_cost bigint;
  budget_left bigint; task_left bigint; available bigint; output bigint;
begin
  if task is null or step is null or input_tokens is null or input_tokens < 0 or max_output is null or max_output < 1 then
    raise exception 'invalid_request' using errcode = '22023';
  end if;
  select * into m from public.ai_models where id = model_id and enabled;
  if not found then raise exception 'invalid_request' using errcode = '22023'; end if;
  select * into strict s from public.ai_settings;
  perform pg_advisory_xact_lock(hashtextextended('ai:' || actor::text, 0));
  st := public.ai_status(actor);
  insert into public.ai_task(id, user_id) values (task, actor) on conflict (id) do nothing;
  select t.user_id, t.cost_ucents + coalesce((select sum(r.amount_ucents) from public.ai_reservation r
      where r.task_id = t.id and r.created_at > now() - interval '5 minutes'), 0)
    into owner, task_used from public.ai_task t where t.id = task;
  if owner <> actor then raise exception 'invalid_request' using errcode = '22023'; end if;
  -- A step may write the whole input to the cache, so the input is reserved at the higher of the two prices.
  input_cost := ceil(input_tokens * greatest(m.p_in, m.p_cache_w))::bigint;
  budget_left := (st->>'remainingUcents')::bigint;
  task_left := greatest((st->>'taskCapUcents')::bigint - task_used, 0);
  available := least(budget_left, task_left) - input_cost;
  output := case when m.p_out = 0 then max_output else least(max_output, floor(greatest(available, 0) / m.p_out))::bigint end;
  if available < 0 or output < s.min_output_tokens then
    return jsonb_build_object('ok', false, 'code', case when task_left < budget_left then 'TASK_CAP_REACHED' else 'BUDGET_EXHAUSTED' end, 'status', st);
  end if;
  insert into public.ai_reservation(id, user_id, task_id, amount_ucents) values (step, actor, task, input_cost + ceil(output * m.p_out)::bigint);
  return jsonb_build_object('ok', true, 'maxOutput', output, 'status', public.ai_status(actor));
end $$;

-- Drops a reservation whose step never reached the provider (upstream refused it).
create function public.ai_release(actor uuid, step uuid) returns void
language sql volatile security definer set search_path = '' as $$
  delete from public.ai_reservation where id = step and user_id = actor
$$;

-- Charges one finished (or cut-off) upstream step at the model's list price. The month's
-- budget pays first, credit covers the rest; whatever neither covers stays on the month.
-- An overrun is impossible while the provider honours the output limit from ai_begin;
-- ponytail: one that still happens is not carried into next month (the spec says it
-- should); the ledger records it. Carry it over if the ledger ever shows any.
create function public.ai_settle(actor uuid, task uuid, step uuid, model_id text, effort text, kind text,
  t_in bigint, t_out bigint, t_cache_r bigint, t_cache_w bigint, complete boolean) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare m public.ai_models; st jsonb; cost bigint; budget_left bigint; from_credit bigint := 0;
begin
  if t_in < 0 or t_out < 0 or t_cache_r < 0 or t_cache_w < 0 then raise exception 'invalid_request' using errcode = '22023'; end if;
  if kind not in ('question','summary','quiz','translate','routine','explain') then raise exception 'invalid_request' using errcode = '22023'; end if;
  select * into m from public.ai_models where id = model_id;
  if not found then raise exception 'invalid_request' using errcode = '22023'; end if;
  perform pg_advisory_xact_lock(hashtextextended('ai:' || actor::text, 0));
  delete from public.ai_reservation where id = step and user_id = actor;
  cost := ceil(t_in * m.p_in + t_out * m.p_out + t_cache_r * m.p_cache_r + t_cache_w * m.p_cache_w)::bigint;
  st := public.ai_status(actor);
  budget_left := greatest((st->>'capUcents')::bigint - (st->>'spentUcents')::bigint, 0);
  if cost > budget_left then from_credit := least(cost - budget_left, greatest((st->>'creditUcents')::bigint, 0)); end if;
  insert into public.ai_budget(user_id, period, spent_ucents) values (actor, public.ai_period(), cost - from_credit)
    on conflict (user_id, period) do update set spent_ucents = public.ai_budget.spent_ucents + excluded.spent_ucents;
  if from_credit > 0 then update public.ai_credit set balance_ucents = balance_ucents - from_credit where user_id = actor; end if;
  update public.ai_task set cost_ucents = cost_ucents + cost, steps = steps + 1 where id = task and user_id = actor;
  insert into public.ai_usage_ledger(user_id, task_id, model, effort, kind, tokens_in, tokens_out, tokens_cache_r, tokens_cache_w, cost_ucents, complete)
    values (actor, task, model_id, effort, kind, t_in, t_out, t_cache_r, t_cache_w, cost, complete);
  return jsonb_build_object('costUcents', cost, 'status', public.ai_status(actor));
end $$;

create function public.ai_record_consent(actor uuid, provider_id text, consent_version integer) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
begin
  if actor is null then raise exception 'sign_in_required' using errcode = '42501'; end if;
  if provider_id not in ('anthropic','openai') or consent_version is null or consent_version < 1 then
    raise exception 'invalid_request' using errcode = '22023';
  end if;
  insert into public.ai_consent(user_id, provider, version) values (actor, provider_id, consent_version)
    on conflict (user_id, provider) do update set version = excluded.version, agreed_at = now();
  return public.ai_status(actor);
end $$;

-- Grants credit once per (source, ref); a repeat returns the status without paying again.
create function public.ai_grant_credit(actor uuid, grant_source text, grant_ref text, amount bigint) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare inserted integer;
begin
  if actor is null or amount is null or amount <= 0 then raise exception 'invalid_request' using errcode = '22023'; end if;
  perform pg_advisory_xact_lock(hashtextextended('ai:' || actor::text, 0));
  insert into public.ai_credit_grants(source, ref, user_id, amount_ucents) values (grant_source, grant_ref, actor, amount)
    on conflict (source, ref) do nothing;
  get diagnostics inserted = row_count;
  if inserted = 0 and not exists (select 1 from public.ai_credit_grants g where g.source = grant_source and g.ref = grant_ref and g.user_id = actor) then
    raise exception 'purchase_owned_by_another_account' using errcode = '42501';
  end if;
  if inserted = 1 then
    insert into public.ai_credit(user_id, balance_ucents) values (actor, amount)
      on conflict (user_id) do update set balance_ucents = public.ai_credit.balance_ucents + excluded.balance_ucents;
  end if;
  return public.ai_status(actor);
end $$;

-- A refunded pack takes its credit back; the balance may go below zero if it was spent.
create function public.ai_revoke_credit(grant_source text, grant_ref text) returns void
language plpgsql volatile security definer set search_path = '' as $$
declare g public.ai_credit_grants;
begin
  update public.ai_credit_grants set revoked_at = now()
    where source = grant_source and ref = grant_ref and revoked_at is null returning * into g;
  if found then
    update public.ai_credit set balance_ucents = balance_ucents - g.amount_ucents where user_id = g.user_id;
  end if;
end $$;

do $$ declare f text; begin
  foreach f in array array['ai_period()','ai_status(uuid)','ai_begin(uuid,uuid,uuid,text,bigint,integer)','ai_release(uuid,uuid)',
    'ai_settle(uuid,uuid,uuid,text,text,text,bigint,bigint,bigint,bigint,boolean)',
    'ai_record_consent(uuid,text,integer)','ai_grant_credit(uuid,text,text,bigint)','ai_revoke_credit(text,text)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;

commit;
