-- 친구 초대: privileges, codes, check, claim, complete (exact amounts, once, the inviter's five),
-- status, account deletion. Runs as service_role. run-local.sh then completes the claims left
-- open at the end from several sessions at once and checks the outcome with referral_race.sql.
create function public.test_user(n integer) returns uuid language sql immutable as $$
  select ('00000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid
$$;
insert into auth.users select public.test_user(n) from generate_series(1, 31) n;
\set paid '{"status":"rewarded","creditMicrocents":7000000,"referrerRewarded":true}'
\set unpaid '{"status":"rewarded","creditMicrocents":7000000,"referrerRewarded":false}'

-- Nothing is reachable with the app's keys.
select public.assert_true(not exists (select 1 from unnest(array['anon','authenticated']) r,
  unnest(array['referral_reward()','referral_cap()','referral_daily_grants()','referral_new_code()','referral_check(text)',
    'referral_claim_code(uuid,text)','referral_complete(uuid)','referral_status(uuid)']) f
  where has_function_privilege(r, 'public.' || f, 'execute')), 'no function for anon or authenticated');
select public.assert_true(not exists (select 1 from unnest(array['anon','authenticated']) r, unnest(array['referral_code','referral_claim']) t
  where has_table_privilege(r, 'public.' || t, 'select,insert,update,delete')), 'no table for anon or authenticated');
select public.assert_true((select count(*) = 2 and bool_and(relrowsecurity) from pg_class where relname in ('referral_code','referral_claim'))
  and not exists (select 1 from pg_policies where tablename in ('referral_code','referral_claim')), 'row level security on, no policy');
set role authenticated;
do $$ begin
  perform public.referral_complete(public.test_user(1));
  raise exception 'authenticated unexpectedly called referral_complete';
exception when insufficient_privilege then null; end $$;
do $$ begin
  perform * from public.referral_claim;
  raise exception 'authenticated unexpectedly read referral_claim';
exception when insufficient_privilege then null; end $$;
reset role;
set role anon;
do $$ begin
  perform public.referral_check('ABCDEF');
  raise exception 'anon unexpectedly called referral_check';
exception when insufficient_privilege then null; end $$;
do $$ begin
  perform * from public.referral_code;
  raise exception 'anon unexpectedly read referral_code';
exception when insufficient_privilege then null; end $$;
reset role;

set role service_role;
-- The terms.
select public.assert_true(public.referral_reward() = 7000000 and public.referral_cap() = 5, '$0.07 each, five invitees');

-- An account's code is made the first time it asks, and stays.
select public.referral_status(public.test_user(1)) as status1 \gset
select (:'status1'::jsonb)->>'code' as code1 \gset
select public.assert_true((select array_agg(k order by k) from jsonb_object_keys(:'status1'::jsonb) k)
  = array['claim','code','completed','creditMicrocents','limit'], 'status keys');
select public.assert_true(:'code1' ~ '^[A-HJKMNP-Z2-9]{6}$', 'six characters of the alphabet');
select public.assert_true(:'status1'::jsonb = jsonb_build_object('code', :'code1', 'completed', 0, 'limit', 5, 'creditMicrocents', 0, 'claim', null), 'a new account');
select public.assert_true(public.referral_status(public.test_user(1)) = :'status1'::jsonb, 'the same code every time');
select public.assert_true((select count(*) = 1 and bool_and(code = :'code1') from public.referral_code where owner_id = public.test_user(1)), 'one row per account');
select public.referral_status(public.test_user(4))->>'code' as code4 \gset
select public.assert_true(:'code4' <> :'code1', 'another account, another code');
do $$ begin
  insert into public.referral_code(code, owner_id) values ('ABCDEF', public.test_user(1));
  raise exception 'second code for one account accepted';
exception when unique_violation then null; end $$;
do $$ begin
  insert into public.referral_code(code, owner_id) values ('ABCDE0', public.test_user(3));
  raise exception 'code outside the alphabet accepted';
exception when check_violation then null; end $$;

-- The generator: 2,000 codes are all well formed, all but never the same, and between them use
-- every character of the alphabet and no other.
select public.assert_true((select bool_and(code ~ '^[A-HJKMNP-Z2-9]{6}$') and count(distinct code) > 1990
  from (select public.referral_new_code() as code from generate_series(1, 2000)) drawn), 'codes are well formed and differ');
select public.assert_true((select count(distinct ch) = 31 and bool_and(strpos('ABCDEFGHJKMNPQRSTUVWXYZ23456789', ch) > 0)
  from (select regexp_split_to_table(public.referral_new_code(), '') as ch from generate_series(1, 2000)) drawn), 'the whole alphabet, nothing else');

-- A code that is taken is drawn again: here the generator repeats the first account's code once.
reset role;
begin;
create sequence public.referral_test_draws;
create or replace function public.referral_new_code() returns text language sql volatile as $$
  select case nextval('public.referral_test_draws') when 1 then (select code from public.referral_code where owner_id = public.test_user(1)) else 'ZZZZZ2' end
$$;
select public.referral_status(public.test_user(3))->>'code' as code3 \gset
select public.assert_true(:'code3' = 'ZZZZZ2' and currval('public.referral_test_draws') = 2, 'a taken code is drawn again');
-- A generator that only ever repeats it is given up on after twenty draws.
create or replace function public.referral_new_code() returns text language sql volatile as $$
  select code from public.referral_code where owner_id = public.test_user(1) and nextval('public.referral_test_draws') > 0
$$;
do $$ begin
  perform public.referral_status(public.test_user(9));
  raise exception 'a code out of nowhere';
exception when program_limit_exceeded then null; end $$;
select public.assert_true(currval('public.referral_test_draws') = 22, 'twenty draws, then an error');
rollback;
set role service_role;

-- Check says whether a code exists, exactly as stored (the Edge Function trims and upper-cases).
select public.assert_true(public.referral_check(:'code1') and public.referral_check(:'code4'), 'known codes');
select public.assert_true(not public.referral_check('000000') and not public.referral_check(lower(:'code1'))
  and not public.referral_check('') and not public.referral_check(null), 'unknown, lower case, empty, null');

-- Claim: once per invitee.
select public.assert_true(public.referral_claim_code(public.test_user(2), :'code1') = '{"status":"claimed"}'::jsonb, 'claimed');
select public.assert_true(public.referral_claim_code(public.test_user(2), :'code1') = '{"status":"claimed"}'::jsonb, 'the same code again is the same answer');
select id as claim2 from public.referral_claim where referee_id = public.test_user(2) \gset
select public.assert_true((select count(*) = 1 and bool_and(code = :'code1' and referrer_id = public.test_user(1) and completed_at is null and rewarded_at is null)
  from public.referral_claim where referee_id = public.test_user(2)), 'one open claim');
select public.assert_true(public.referral_claim_code(public.test_user(2), :'code4') = '{"status":"already_claimed"}'::jsonb, 'a second, different code is refused');
select public.assert_true(public.referral_claim_code(public.test_user(2), '000000') = '{"status":"invalid_code"}'::jsonb, 'as is a code nobody has');
select public.assert_true((select count(*) = 1 and bool_and(code = :'code1') from public.referral_claim where referee_id = public.test_user(2)), 'and neither changes anything');
select public.assert_true(public.referral_claim_code(public.test_user(1), :'code1') = '{"status":"own_code"}'::jsonb, 'own code');
select public.assert_true(public.referral_claim_code(public.test_user(4), '000000') = '{"status":"invalid_code"}'::jsonb
  and public.referral_claim_code(public.test_user(4), lower(:'code1')) = '{"status":"invalid_code"}'::jsonb, 'unknown code');
select public.assert_true((select count(*) = 1 from public.referral_claim), 'refusals leave no claim');
do $$ begin
  insert into public.referral_claim(code, referrer_id, referee_id) values ('ABCDEF', public.test_user(4), public.test_user(4));
  raise exception 'self-referral row accepted';
exception when check_violation then null; end $$;
select public.assert_true(public.referral_status(public.test_user(2))->'claim' = jsonb_build_object('code', :'code1', 'completed', false), 'the invitee sees its claim');

-- Complete: both sides get exactly 7,000,000 µ¢, once.
select public.assert_true(public.referral_complete(public.test_user(4)) = '{"status":"none"}'::jsonb, 'no claim, nothing to complete');
select public.assert_true(not exists (select 1 from public.ai_credit_grants where source = 'referral'), 'nothing paid so far');
select public.assert_true(public.referral_complete(public.test_user(2)) = :'paid'::jsonb, 'rewarded');
select public.assert_true((select count(*) = 2 and bool_and(balance_ucents = 7000000) from public.ai_credit where user_id in (public.test_user(1), public.test_user(2))), '7,000,000 µ¢ each');
select public.assert_true((select count(*) = 2 and bool_and(amount_ucents = 7000000 and revoked_at is null)
    and bool_or(user_id = public.test_user(2) and ref = 'claim:' || :'claim2' || ':referee')
    and bool_or(user_id = public.test_user(1) and ref = 'claim:' || :'claim2' || ':referrer')
  from public.ai_credit_grants where source = 'referral'), 'one grant each, named after the claim');
select public.assert_true((select completed_at is not null and rewarded_at is not null from public.referral_claim where id = :'claim2'), 'completed_at and rewarded_at set');
select public.assert_true((public.ai_status(public.test_user(2))->>'creditUcents')::bigint = 7000000, 'it is AI credit');
select public.assert_true(public.referral_complete(public.test_user(2)) = '{"status":"already"}'::jsonb, 'a second complete');
select public.assert_true((select count(*) = 2 and bool_and(balance_ucents = 7000000) from public.ai_credit where user_id in (public.test_user(1), public.test_user(2)))
  and (select count(*) = 2 from public.ai_credit_grants where source = 'referral')
  and (select completed = 1 from public.referral_code where owner_id = public.test_user(1)), 'pays nothing and counts nothing');
select public.assert_true(public.referral_status(public.test_user(2))->'claim' = jsonb_build_object('code', :'code1', 'completed', true)
  and (public.referral_status(public.test_user(2))->>'creditMicrocents')::bigint = 7000000, 'the invitee''s status');
select public.assert_true(public.referral_status(public.test_user(1)) = jsonb_build_object('code', :'code1', 'completed', 1, 'limit', 5, 'creditMicrocents', 7000000, 'claim', null), 'the inviter''s status');

-- The inviter is paid for five invitees. The sixth is paid, the inviter is not.
select public.assert_true((select bool_and(public.referral_claim_code(public.test_user(n), :'code1') = '{"status":"claimed"}'::jsonb) from generate_series(5, 9) n), 'five more invitees');
select public.assert_true((select bool_and(public.referral_complete(public.test_user(n)) = :'paid'::jsonb) from generate_series(5, 8) n), 'the second to the fifth pay both sides');
select public.assert_true((select balance_ucents = 35000000 from public.ai_credit where user_id = public.test_user(1)), '$0.35 for five');
select id as claim9 from public.referral_claim where referee_id = public.test_user(9) \gset
select public.assert_true(public.referral_complete(public.test_user(9)) = :'unpaid'::jsonb, 'the sixth: the inviter is not paid');
select public.assert_true((select balance_ucents = 7000000 from public.ai_credit where user_id = public.test_user(9))
  and (select balance_ucents = 35000000 from public.ai_credit where user_id = public.test_user(1)), 'the sixth invitee is paid, the inviter stays at $0.35');
select public.assert_true((select count(*) = 1 and bool_and(user_id = public.test_user(9) and ref = 'claim:' || :'claim9' || ':referee')
  from public.ai_credit_grants where ref like 'claim:' || :'claim9' || ':%'), 'no grant to the inviter for the sixth');
select public.assert_true(public.referral_status(public.test_user(1)) = jsonb_build_object('code', :'code1', 'completed', 6, 'limit', 5, 'creditMicrocents', 35000000, 'claim', null), 'six completed, five paid');

-- An account can be both: 2 was invited by 1 and now invites 1 back. Credit counts both roles,
-- and a revoked grant is left out.
select public.referral_status(public.test_user(2))->>'code' as code2 \gset
select public.assert_true(public.referral_claim_code(public.test_user(1), :'code2') = '{"status":"claimed"}'::jsonb, 'the invitee invites its inviter');
select public.assert_true(public.referral_complete(public.test_user(1)) = :'paid'::jsonb, 'and both are paid again');
select id as claim1 from public.referral_claim where referee_id = public.test_user(1) \gset
select public.assert_true(public.referral_status(public.test_user(1)) = jsonb_build_object('code', :'code1', 'completed', 6, 'limit', 5, 'creditMicrocents', 42000000,
  'claim', jsonb_build_object('code', :'code2', 'completed', true)), 'inviter and invitee: 5 + 1 rewards');
select public.assert_true(public.referral_status(public.test_user(2)) = jsonb_build_object('code', :'code2', 'completed', 1, 'limit', 5, 'creditMicrocents', 14000000,
  'claim', jsonb_build_object('code', :'code1', 'completed', true)), 'invitee and inviter: 1 + 1 rewards');
select public.ai_revoke_credit('referral', 'claim:' || :'claim1' || ':referrer');
select public.assert_true((public.referral_status(public.test_user(2))->>'creditMicrocents')::bigint = 7000000, 'a revoked grant does not count');
select public.assert_true(public.referral_complete(public.test_user(1)) = '{"status":"already"}'::jsonb, 'and another complete');
select public.assert_true((select balance_ucents = 7000000 from public.ai_credit where user_id = public.test_user(2))
  and (select completed = 1 from public.referral_code where owner_id = public.test_user(2)), 'does not pay it back');
select public.ai_grant_credit(public.test_user(4), 'manual', 'not-a-referral', 1000000);
select public.assert_true((public.referral_status(public.test_user(4))->>'creditMicrocents')::bigint = 0, 'nor does credit from anything else');

-- Signed-out callers are refused by the functions too.
do $$ begin
  begin
    perform public.referral_status(null);
    raise exception 'status without an account';
  exception when insufficient_privilege then null; end;
  begin
    perform public.referral_claim_code(null, 'ABCDEF');
    raise exception 'claim without an account';
  exception when insufficient_privilege then null; end;
  begin
    perform public.referral_complete(null);
    raise exception 'complete without an account';
  exception when insufficient_privilege then null; end;
end $$;

-- Account deletion. The inviter goes before the invitee completes: the code is gone, the claim
-- stays, the invitee is still paid and still cannot enter another code.
select public.referral_status(public.test_user(10))->>'code' as code10 \gset
select public.referral_claim_code(public.test_user(11), :'code10');
reset role;
delete from auth.users where id = public.test_user(10);
set role service_role;
select public.assert_true(not public.referral_check(:'code10') and not exists (select 1 from public.referral_code where owner_id = public.test_user(10)), 'the code goes with its account');
select public.assert_true((select count(*) = 1 and bool_and(referrer_id is null and code = :'code10') from public.referral_claim where referee_id = public.test_user(11)), 'the claim stays, without an inviter');
select public.assert_true(public.referral_status(public.test_user(11))->'claim' = jsonb_build_object('code', :'code10', 'completed', false), 'and the invitee still sees it');
select public.assert_true(public.referral_claim_code(public.test_user(11), :'code1') = '{"status":"already_claimed"}'::jsonb, 'no second invitation');
select public.assert_true(public.referral_claim_code(public.test_user(11), :'code10') = '{"status":"claimed"}'::jsonb
  and (select count(*) = 1 from public.referral_claim where referee_id = public.test_user(11)), 'the same code again is still claimed');
select public.assert_true(public.referral_complete(public.test_user(11)) = :'unpaid'::jsonb, 'completing pays nobody else');
select public.assert_true((select balance_ucents = 7000000 from public.ai_credit where user_id = public.test_user(11)), 'the invitee is paid all the same');
-- A paid invitee goes: the inviter keeps the credit, and the place is not given back.
reset role;
delete from auth.users where id = public.test_user(5);
set role service_role;
select public.assert_true(not exists (select 1 from public.referral_claim where referee_id = public.test_user(5))
  and not exists (select 1 from public.ai_credit_grants where user_id = public.test_user(5)), 'the invitee''s rows go with the account');
select public.assert_true((select balance_ucents = 42000000 from public.ai_credit where user_id = public.test_user(1))
  and (select count(*) = 5 from public.ai_credit_grants where user_id = public.test_user(1) and ref like 'claim:%:referrer')
  and (select completed = 6 from public.referral_code where owner_id = public.test_user(1)), 'the inviter keeps credit, grants and count');
select public.referral_claim_code(public.test_user(12), :'code1');
select public.assert_true(public.referral_complete(public.test_user(12)) = :'unpaid'::jsonb, 'deleting an invitee does not free a paid place');
select public.assert_true((select balance_ucents = 42000000 from public.ai_credit where user_id = public.test_user(1)), 'the inviter stays at six rewards');
-- A paid inviter goes: every invitee keeps the credit and the claim; nothing is left of the inviter.
reset role;
delete from auth.users where id = public.test_user(1);
set role service_role;
select public.assert_true((select count(*) = 6 and bool_and(referrer_id is null and completed_at is not null) from public.referral_claim where code = :'code1'), 'six claims outlive their inviter');
select public.assert_true((select count(*) = 6 and bool_and(balance_ucents = 7000000) from public.ai_credit
  where user_id in (select referee_id from public.referral_claim where code = :'code1')), 'and every invitee keeps the credit');
select public.assert_true(not public.referral_check(:'code1') and not exists (select 1 from public.referral_claim where referee_id = public.test_user(1))
  and not exists (select 1 from public.ai_credit_grants where user_id = public.test_user(1)), 'the inviter''s code, own claim and grants are gone');
select public.assert_true((select completed = 1 from public.referral_code where owner_id = public.test_user(2)), 'whoever invited the deleted account keeps the count');
-- With both sides gone no row is left.
reset role;
delete from auth.users where id = public.test_user(11);
set role service_role;
select public.assert_true(not exists (select 1 from public.referral_claim where code = :'code10'), 'a claim with nobody left is gone');
reset role;
select public.assert_true(not exists (select 1 from public.referral_claim c where not exists (select 1 from auth.users u where u.id = c.referee_id)
    or (c.referrer_id is not null and not exists (select 1 from auth.users u where u.id = c.referrer_id)))
  and not exists (select 1 from public.referral_code c where not exists (select 1 from auth.users u where u.id = c.owner_id)), 'every row belongs to a live account');
set role service_role;

-- The day's ceiling: with that many referral grants in the last 24 hours nothing more is paid,
-- the claim stays open, and it is paid once the older grants have aged out.
select public.referral_status(public.test_user(30))->>'code' as code30 \gset
select public.assert_true(public.referral_claim_code(public.test_user(31), :'code30') = '{"status":"claimed"}'::jsonb, 'a claim for the ceiling');
reset role;
insert into public.ai_credit_grants(source, ref, user_id, amount_ucents)
  select 'referral', 'ceiling:' || n, public.test_user(30), 1 from generate_series(1, public.referral_daily_grants()) n;
set role service_role;
do $$ begin
  perform public.referral_complete(public.test_user(31));
  raise exception 'a completion was paid past the daily ceiling';
exception when configuration_limit_exceeded then null; end $$;
select public.assert_true((select completed_at is null and rewarded_at is null from public.referral_claim where referee_id = public.test_user(31))
  and not exists (select 1 from public.ai_credit_grants where user_id = public.test_user(31)), 'past the ceiling the claim stays open and unpaid');
reset role;
update public.ai_credit_grants set granted_at = now() - interval '25 hours' where ref like 'ceiling:%';
set role service_role;
select public.assert_true(public.referral_complete(public.test_user(31)) = :'paid'::jsonb, 'and it is paid once the day has rolled over');
reset role;
delete from public.ai_credit_grants where ref like 'ceiling:%';
set role service_role;

-- Left for run-local.sh: inviter 20 is one invitee short of the five and 25 and 26 have entered
-- its code; 27 and 28 have entered each other's; 29 has not asked for its code yet.
select public.referral_status(public.test_user(20))->>'code' as code20 \gset
select public.assert_true((select bool_and(public.referral_claim_code(public.test_user(n), :'code20') = '{"status":"claimed"}'::jsonb) from generate_series(21, 26) n), 'six invitees');
select public.assert_true((select bool_and(public.referral_complete(public.test_user(n)) = :'paid'::jsonb) from generate_series(21, 24) n), 'four completed');
select public.referral_status(public.test_user(27))->>'code' as code27 \gset
select public.referral_status(public.test_user(28))->>'code' as code28 \gset
select public.assert_true(public.referral_claim_code(public.test_user(27), :'code28') = '{"status":"claimed"}'::jsonb
  and public.referral_claim_code(public.test_user(28), :'code27') = '{"status":"claimed"}'::jsonb, 'two accounts invite each other');
reset role;
select 'PASS: referral privileges, codes, claim, complete once, cap of five, status, account deletion' as result;
