-- 친구 초대 (friend referral, 1.4.1). Every account has one code. An invitee enters a friend's
-- code once (a claim); when the app reports the invitee's first course, both sides get AI credit
-- through ai_grant_credit (source 'referral'): spent after the month's budget, never expiring.
--   referral_code    one code per account, made the first time the account asks for its status
--   referral_claim   one row per invitee: whose code, and when it was completed and paid
-- The rules go by account only: the tables hold user ids, codes and timestamps, and no device
-- is identified.
-- service_role only, like 202611100002_schools: the app goes through the `referral` Edge Function.
begin;

-- The terms, in one place. Each side gets $0.07 (µ¢, the unit of ai_credit_grants). An inviter
-- is paid for the first five invitees who complete; later invitees are still paid themselves.
create function public.referral_reward() returns bigint
language sql immutable parallel safe set search_path = '' as $$ select 7000000::bigint $$;
create function public.referral_cap() returns integer
language sql immutable parallel safe set search_path = '' as $$ select 5 $$;
-- The server cannot see a course: /complete is the app's word for it, and accounts are cheap to
-- make. So what referrals pay out in any 24 hours is bounded for everyone together: 400 grants
-- ($28). Past that a completion is refused, its claim stays open, and the app's next /complete
-- is paid once older grants have aged out.
-- ponytail: one ceiling for all accounts, so a burst of real invites waits with the fake ones;
-- raise the number, or pay only on a signal the server can see, when real use comes near it.
create function public.referral_daily_grants() returns integer
language sql immutable parallel safe set search_path = '' as $$ select 400 $$;

-- `completed` counts the owner's invitees who completed. It is kept here rather than counted
-- from referral_claim because a claim goes when its invitee's account goes: deleting invitee
-- accounts must not hand an inviter the five paid places back.
create table public.referral_code(
  code text primary key check (code ~ '^[A-HJKMNP-Z2-9]{6}$'),
  owner_id uuid not null unique references auth.users(id) on delete cascade,
  completed integer not null default 0 check (completed >= 0),
  created_at timestamptz not null default now()
);

-- `code` is what the invitee entered, kept as text and not as a reference: the code row goes
-- with the inviter's account (referrer_id → null) while the claim stays, so the invitee is
-- still paid on completion and cannot be invited a second time.
create table public.referral_claim(
  id uuid primary key default gen_random_uuid(),
  code text not null check (code ~ '^[A-HJKMNP-Z2-9]{6}$'),
  referrer_id uuid references auth.users(id) on delete set null,
  referee_id uuid not null unique references auth.users(id) on delete cascade,
  claimed_at timestamptz not null default now(),
  completed_at timestamptz,
  rewarded_at timestamptz,
  check (referrer_id is distinct from referee_id)
);
create index referral_claim_referrer on public.referral_claim(referrer_id);
-- referral_status sums an account's referral grants; the ledger had no index by account.
create index ai_credit_grants_user on public.ai_credit_grants(user_id);

do $$ declare t text; begin
  foreach t in array array['referral_code','referral_claim'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from public, anon, authenticated', t);
    execute format('grant all on public.%I to service_role', t);
  end loop;
end $$;

-- Six characters from an alphabet without 0/O and 1/I/L, each drawn from 32 bits of a random
-- (version 4) UUID: gen_random_uuid() is the server's CSPRNG and needs no extension. 2^32 is not
-- a multiple of 31, which favours four of the characters by 7 parts in a billion.
create function public.referral_new_code() returns text
language sql volatile set search_path = '' as $$
  select string_agg(substr('ABCDEFGHJKMNPQRSTUVWXYZ23456789', 1 + (('x' || left(gen_random_uuid()::text, 8))::bit(32)::bigint % 31)::integer, 1), '')
  from generate_series(1, 6)
$$;

-- The account's own code and numbers, the Status object of the Edge Function's API. The code is
-- made here the first time. `on conflict do nothing` covers both ways the insert can lose: the
-- code is taken (the loop draws another) or a parallel request made this account's code (the
-- loop reads it). Twenty taken codes in a row do not happen by chance among 31^6, so the loop
-- stops there rather than spin. creditMicrocents is what the account got from referrals in
-- either role.
create function public.referral_status(actor uuid) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare own public.referral_code; draws integer := 0;
begin
  if actor is null then raise exception 'sign_in_required' using errcode = '42501'; end if;
  loop
    select * into own from public.referral_code c where c.owner_id = actor;
    exit when found;
    if draws = 20 then raise exception 'referral_code_unavailable' using errcode = '54000'; end if;
    draws := draws + 1;
    insert into public.referral_code(code, owner_id) values (public.referral_new_code(), actor) on conflict do nothing;
  end loop;
  return jsonb_build_object(
    'code', own.code, 'completed', own.completed, 'limit', public.referral_cap(),
    'creditMicrocents', (select coalesce(sum(g.amount_ucents), 0) from public.ai_credit_grants g
      where g.user_id = actor and g.source = 'referral' and g.revoked_at is null),
    'claim', (select jsonb_build_object('code', c.code, 'completed', c.completed_at is not null)
      from public.referral_claim c where c.referee_id = actor));
end $$;

-- Whether a code exists, and nothing else about it. Compared as stored: the Edge Function has
-- trimmed and upper-cased what was typed.
create function public.referral_check(entered text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.referral_code c where c.code = entered)
$$;

-- An invitee enters a code. Returns {status: claimed | own_code | invalid_code | already_claimed}.
-- One claim per account, for good. Entering the same code again is `claimed` again, also once
-- the code itself is gone with its inviter; any other code is then `already_claimed`.
create function public.referral_claim_code(actor uuid, entered text) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare owner uuid; mine text;
begin
  if actor is null then raise exception 'sign_in_required' using errcode = '42501'; end if;
  select c.owner_id into owner from public.referral_code c where c.code = entered;
  if owner = actor then return jsonb_build_object('status', 'own_code'); end if;
  if owner is not null then
    insert into public.referral_claim(code, referrer_id, referee_id) values (entered, owner, actor) on conflict (referee_id) do nothing;
  end if;
  select c.code into mine from public.referral_claim c where c.referee_id = actor;
  return jsonb_build_object('status', case when mine = entered then 'claimed' when owner is null then 'invalid_code' else 'already_claimed' end);
end $$;

-- The invitee's first course, reported by the app. Returns
--   {status: none}      this account entered no code
--   {status: already}   its claim was completed before; nothing is paid again
--   {status: rewarded, creditMicrocents, referrerRewarded}
--                       the invitee is paid; the inviter too while it has had fewer than five
--                       (referral_cap) and its account still exists
-- or raises referral_paused (53400) while the day's ceiling (referral_daily_grants) is reached:
-- nothing is written, and the Edge Function answers 503 so the app tries again later.
-- All in one transaction. The locks, in the order they are taken:
--   1. the claim row. A repeat by the same invitee waits here, then finds the claim completed.
--   2. both accounts' `ai:` advisory locks, the lower user id first. They are the locks
--      ai_grant_credit takes, and it would take them invitee first: two accounts that invited
--      each other and completed at the same moment would then deadlock. Holding the inviter's
--      also puts invitees of one inviter who complete at the same moment one after the other.
--   3. the rows written under those: the inviter's code row, whose counter decides who is among
--      the five, and what ai_grant_credit writes.
-- Each payment is its own (source, ref) in ai_credit_grants, which pays a ref once whatever
-- happens here.
-- ponytail: deleting one of the two accounts in the same instant takes its locks the other way
-- round (the auth.users row, then these rows through the cascades) and can deadlock with this.
-- Postgres then aborts one of the two with nothing half done, and the app's next /complete or
-- a second delete goes through; ai_settle has the same edge. If it ever shows in the logs, lock
-- both auth.users rows `for key share` before the claim row.
create function public.referral_complete(actor uuid) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare c public.referral_claim; pay_referrer boolean;
begin
  if actor is null then raise exception 'sign_in_required' using errcode = '42501'; end if;
  select * into c from public.referral_claim x where x.referee_id = actor for update;
  if not found then return jsonb_build_object('status', 'none'); end if;
  if c.completed_at is not null then return jsonb_build_object('status', 'already'); end if;
  -- Read without a lock: a few completions at the same moment may pass together, which a ceiling can afford.
  if (select count(*) from public.ai_credit_grants g where g.source = 'referral' and g.granted_at > now() - interval '1 day') >= public.referral_daily_grants() then
    raise exception 'referral_paused' using errcode = '53400';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('ai:' || least(actor, c.referrer_id)::text, 0));
  perform pg_advisory_xact_lock(hashtextextended('ai:' || greatest(actor, c.referrer_id)::text, 0));
  -- No row when the inviter's account is gone: pay_referrer stays null.
  update public.referral_code set completed = completed + 1 where owner_id = c.referrer_id
    returning completed <= public.referral_cap() into pay_referrer;
  update public.referral_claim set completed_at = now(), rewarded_at = now() where id = c.id;
  perform public.ai_grant_credit(actor, 'referral', 'claim:' || c.id || ':referee', public.referral_reward());
  if pay_referrer then
    perform public.ai_grant_credit(c.referrer_id, 'referral', 'claim:' || c.id || ':referrer', public.referral_reward());
  end if;
  return jsonb_build_object('status', 'rewarded', 'creditMicrocents', public.referral_reward(), 'referrerRewarded', coalesce(pay_referrer, false));
end $$;

do $$ declare f text; begin
  foreach f in array array['referral_reward()','referral_cap()','referral_daily_grants()','referral_new_code()','referral_status(uuid)',
    'referral_check(text)','referral_claim_code(uuid,text)','referral_complete(uuid)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;

commit;
