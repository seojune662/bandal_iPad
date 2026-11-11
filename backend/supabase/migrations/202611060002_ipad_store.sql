-- App Store verification for the iPad app (1.4.0): entitlements written from verified
-- transactions (app sync) and App Store Server Notifications V2, credit packs redeemed once,
-- notifications applied once. service_role only, like 202611060001_ai_metering.
begin;

-- Billing grace (16 days): set from DID_FAIL_TO_RENEW/GRACE_PERIOD, cleared by renewal or expiry.
-- expires_at (what ai_status reads) = greatest(paid_expires_at, grace_expires_at).
-- transaction_id = the latest transaction, so a refund of an older period does not end the current one.
alter table public.ipad_entitlements
  add column grace_expires_at timestamptz,
  add column paid_expires_at timestamptz,
  add column transaction_id text;
update public.ipad_entitlements set paid_expires_at = expires_at;

-- A pack refunded before the app redeemed it must never pay.
create table public.ipad_pack_revocations(
  environment text not null check (environment in ('production','sandbox')),
  transaction_id text not null check (transaction_id ~ '^[0-9]{1,32}$'),
  revoked_at timestamptz not null default now(),
  primary key (environment, transaction_id)
);
alter table public.ipad_pack_revocations enable row level security;
revoke all on public.ipad_pack_revocations from public, anon, authenticated;
grant all on public.ipad_pack_revocations to service_role;

create table public.ipad_store_events(
  environment text not null check (environment in ('production','sandbox')),
  event_id text not null check (event_id ~ '^[0-9a-fA-F-]{36}$'),
  notification_type text not null,
  received_at timestamptz not null default now(),
  primary key (environment, event_id)
);
alter table public.ipad_store_events enable row level security;
revoke all on public.ipad_store_events from public, anon, authenticated;
grant all on public.ipad_store_events to service_role;

-- Writes one verified subscription transaction. The first account to claim an original
-- transaction owns it; another account gets purchase_owned_by_another_account. Older
-- signatures never overwrite newer ones, and a revocation is not undone by an equally old
-- state. A revocation of an earlier transaction than the stored one is ignored.
-- An unknown account (deleted) is ignored.
create function public.ipad_apply_entitlement(actor uuid, env text, otid text, tx text, product text, entitlement_plan text,
  trial boolean, expires timestamptz, revoked timestamptz, signed timestamptz, grace_mode text, grace timestamptz)
returns void language plpgsql volatile security definer set search_path = '' as $$
declare existing public.ipad_entitlements; next_grace timestamptz;
begin
  if actor is null or env not in ('production','sandbox') or entitlement_plan not in ('plus','pro') or tx !~ '^[0-9]{1,32}$'
    or grace_mode not in ('keep','set','clear') or expires is null or signed is null then
    raise exception 'invalid_request' using errcode = '22023';
  end if;
  if not exists (select 1 from auth.users u where u.id = actor) then return; end if;
  perform pg_advisory_xact_lock(hashtextextended('ipad-store:' || env || ':' || otid, 0));
  select * into existing from public.ipad_entitlements where environment = env and original_transaction_id = otid;
  if found and existing.user_id <> actor then
    raise exception 'purchase_owned_by_another_account' using errcode = '42501';
  end if;
  if found and revoked is not null and existing.transaction_id is distinct from tx and existing.signed_at > signed then
    return;
  end if;
  next_grace := case grace_mode when 'set' then grace when 'clear' then null else existing.grace_expires_at end;
  if found and (existing.signed_at > signed or (existing.signed_at = signed and existing.revoked_at is not null and revoked is null)) then
    -- A newer state is already stored; only a grace change from a notification still applies.
    if grace_mode <> 'keep' then
      update public.ipad_entitlements set grace_expires_at = next_grace,
          expires_at = greatest(paid_expires_at, next_grace), updated_at = now()
        where environment = env and original_transaction_id = otid;
    end if;
    return;
  end if;
  insert into public.ipad_entitlements(environment, original_transaction_id, user_id, transaction_id, product_id, plan, is_trial,
      paid_expires_at, grace_expires_at, expires_at, revoked_at, signed_at)
    values (env, otid, actor, tx, product, entitlement_plan, trial, expires, next_grace, greatest(expires, next_grace), revoked, signed)
    on conflict (environment, original_transaction_id) do update set
      transaction_id = excluded.transaction_id, product_id = excluded.product_id, plan = excluded.plan, is_trial = excluded.is_trial,
      paid_expires_at = excluded.paid_expires_at, grace_expires_at = excluded.grace_expires_at, expires_at = excluded.expires_at,
      revoked_at = excluded.revoked_at, signed_at = excluded.signed_at, updated_at = now();
end $$;

-- The owner of an original transaction, for notifications without an appAccountToken.
create function public.ipad_entitlement_owner(env text, otid text) returns uuid
language sql stable security definer set search_path = '' as $$
  select user_id from public.ipad_entitlements where environment = env and original_transaction_id = otid
$$;

-- True the first time a notification is seen.
create function public.ipad_claim_event(env text, event text, kind text) returns boolean
language plpgsql volatile security definer set search_path = '' as $$
declare inserted integer;
begin
  insert into public.ipad_store_events(environment, event_id, notification_type) values (env, event, kind) on conflict do nothing;
  get diagnostics inserted = row_count;
  return inserted = 1;
end $$;

-- A verified credit pack transaction pays ai_settings.pack_ucents once.
create function public.ipad_redeem_pack(actor uuid, env text, transaction_id text) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare amount bigint;
begin
  if env not in ('production','sandbox') or transaction_id !~ '^[0-9]{1,32}$' then raise exception 'invalid_request' using errcode = '22023'; end if;
  if exists (select 1 from public.ipad_pack_revocations r where r.environment = env and r.transaction_id = ipad_redeem_pack.transaction_id) then
    raise exception 'purchase_revoked' using errcode = '42501';
  end if;
  select pack_ucents into strict amount from public.ai_settings;
  return public.ai_grant_credit(actor, 'pack', env || ':' || transaction_id, amount);
end $$;

-- Records a pack refund (also before redeem) and takes back credit already paid.
create function public.ipad_revoke_pack(env text, transaction_id text) returns void
language plpgsql volatile security definer set search_path = '' as $$
begin
  insert into public.ipad_pack_revocations(environment, transaction_id) values (env, transaction_id) on conflict do nothing;
  perform public.ai_revoke_credit('pack', env || ':' || transaction_id);
end $$;

do $$ declare f text; begin
  foreach f in array array['ipad_apply_entitlement(uuid,text,text,text,text,text,boolean,timestamptz,timestamptz,timestamptz,text,timestamptz)',
    'ipad_revoke_pack(text,text)',
    'ipad_entitlement_owner(text,text)','ipad_claim_event(text,text,text)','ipad_redeem_pack(uuid,text,text)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;

commit;
