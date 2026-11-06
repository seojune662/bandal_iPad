-- AI metering: plans, budgets, credit order, task caps, consent, grants. Runs as service_role.
\set a '''aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'''
\set b '''bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'''
set role authenticated;
select set_config('request.jwt.claim.sub','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',false);
do $$ begin
  perform public.ai_status(auth.uid());
  raise exception 'authenticated unexpectedly called ai_status';
exception when insufficient_privilege then null; end $$;
do $$ begin
  perform * from public.ai_budget;
  raise exception 'authenticated unexpectedly read ai_budget';
exception when insufficient_privilege then null; end $$;
reset role;

set role service_role;
-- Free plan: $0.02 cap, Plus-free task cap = whole budget.
select public.assert_true(public.ai_status(:a)->>'plan' = 'none', 'free plan');
select public.assert_true((public.ai_status(:a)->>'capUcents')::bigint = 2000000, 'free cap');
select public.assert_true((public.ai_status(:a)->>'autoQuestionsLeft')::bigint = 28, 'free ≈ 30 Auto questions');
-- Haiku: 1000 in + 100 out = 10000 + 5000 = 15000 µ¢.
select public.assert_true((public.ai_begin(:a, '11111111-1111-4111-8111-111111111111', 'a0000000-0000-4000-8000-000000000001', 'claude-haiku-5-5', 1000, 8192)->>'ok')::boolean, 'begin within budget');
-- Free $0.02 = 2,000,000 µ¢; input 1000 × 12.5 (cache-write price) = 12,500 reserved, output fills the rest.
select public.assert_true((public.ai_status(:a)->>'reservedUcents')::bigint = 12500 + 8192 * 50, 'reservation held');
select public.assert_true((public.ai_settle(:a, '11111111-1111-4111-8111-111111111111', 'a0000000-0000-4000-8000-000000000001', 'claude-haiku-5-5', 'low', 'question', 1000, 100, 0, 0, true)->>'costUcents')::bigint = 15000, 'haiku cost');
select public.assert_true((public.ai_status(:a)->>'reservedUcents')::bigint = 0, 'settle releases reservation');
select public.assert_true((public.ai_status(:a)->>'spentUcents')::bigint = 15000, 'spent recorded');
select public.assert_true((select steps = 1 and cost_ucents = 15000 from public.ai_task where id = '11111111-1111-4111-8111-111111111111'), 'task accumulates');
select public.assert_true((select count(*) = 1 from public.ai_usage_ledger where user_id = :a), 'ledger row');
-- Cache tokens priced separately (Sonnet: 1000 cache read × 20 + 1000 write × 250).
select public.assert_true((public.ai_settle(:a, '11111111-1111-4111-8111-111111111111', 'a0000000-0000-4000-8000-000000000002', 'claude-sonnet-5-5', 'medium', 'question', 0, 0, 1000, 1000, true)->>'costUcents')::bigint = 270000, 'cache prices');
-- Output is sized to what is left: remaining 1,715,000; Sonnet input 1000 × 250 = 250,000 → 1,465 output tokens.
select public.assert_true((public.ai_begin(:a, '22222222-2222-4222-8222-222222222222', 'a0000000-0000-4000-8000-000000000003', 'claude-sonnet-5-5', 1000, 8192)->>'maxOutput')::bigint = 1465, 'output sized to budget');
-- Parallel step sees the first one's reservation: nothing fits → refused.
select public.assert_true(public.ai_begin(:a, '22222222-2222-4222-8222-222222222222', 'a0000000-0000-4000-8000-000000000004', 'claude-sonnet-5-5', 1000, 8192)->>'code' = 'BUDGET_EXHAUSTED', 'parallel step refused');
select public.ai_release(:a, 'a0000000-0000-4000-8000-000000000003');
select public.assert_true((public.ai_status(:a)->>'reservedUcents')::bigint = 0, 'release frees it');
-- Expired reservations stop counting.
select public.ai_begin(:a, '22222222-2222-4222-8222-222222222222', 'a0000000-0000-4000-8000-000000000005', 'claude-haiku-5-5', 10, 100);
reset role;
update public.ai_reservation set created_at = now() - interval '6 minutes';
set role service_role;
select public.assert_true((public.ai_status(:a)->>'reservedUcents')::bigint = 0, 'stale reservation ignored');
-- Input alone over what is left → refused; disabled model → invalid.
select public.assert_true(public.ai_begin(:a, '22222222-2222-4222-8222-222222222222', 'a0000000-0000-4000-8000-000000000006', 'claude-sonnet-5-5', 100000, 8192)->>'code' = 'BUDGET_EXHAUSTED', 'input over remaining');
do $$ begin
  perform public.ai_begin('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', '22222222-2222-4222-8222-222222222222', 'a0000000-0000-4000-8000-000000000007', 'claude-opus-5-5', 1, 100);
  raise exception 'disabled model accepted';
exception when invalid_parameter_value then null; end $$;

-- Plus, paid.
insert into public.ipad_entitlements values ('production','1001',:a,'app.bandal.ipad.plus.monthly','plus',false,now()+interval '20 days',null,now(),now());
select public.assert_true(public.ai_status(:a)->>'plan' = 'plus', 'plus plan');
select public.assert_true((public.ai_status(:a)->>'capUcents')::bigint = 30000000, 'plus cap');
select public.assert_true((public.ai_status(:a)->>'taskCapUcents')::bigint = 10000000, 'plus task cap');
-- Plus task cap $0.10 = 10,000,000; task 1 has used 285,000. Sonnet: 40,000 input × 250 = 10,000,000 → over the task's rest.
select public.assert_true(public.ai_begin(:a, '11111111-1111-4111-8111-111111111111', 'a0000000-0000-4000-8000-000000000010', 'claude-sonnet-5-5', 40000, 8192)->>'code' = 'TASK_CAP_REACHED', 'plus task cap reached');
select public.assert_true((public.ai_begin(:a, '33333333-3333-4333-8333-333333333333', 'a0000000-0000-4000-8000-000000000011', 'claude-haiku-5-5', 1000, 8192)->>'ok')::boolean, 'new task ok');
-- Another user's task id is refused.
reset role;
insert into auth.users values ('cccccccc-cccc-4ccc-8ccc-cccccccccccc');
set role service_role;
do $$ begin
  perform public.ai_begin('cccccccc-cccc-4ccc-8ccc-cccccccccccc', '33333333-3333-4333-8333-333333333333', 'a0000000-0000-4000-8000-000000000012', 'claude-haiku-5-5', 1, 100);
  raise exception 'foreign task accepted';
exception when invalid_parameter_value then null; end $$;

-- Pro trial: Pro plan wins, but the budget is the trial's $0.30 and the task cap Plus's.
insert into public.ipad_entitlements values ('sandbox','2001',:a,'app.bandal.ipad.pro.monthly','pro',true,now()+interval '7 days',null,now(),now());
select public.assert_true(public.ai_status(:a)->>'plan' = 'pro' and (public.ai_status(:a)->>'trial')::boolean, 'pro trial');
select public.assert_true((public.ai_status(:a)->>'capUcents')::bigint = 30000000, 'trial cap = plus');
select public.assert_true((public.ai_status(:a)->>'taskCapUcents')::bigint = 10000000, 'trial task cap = plus');
update public.ipad_entitlements set is_trial = false where original_transaction_id = '2001';
select public.assert_true((public.ai_status(:a)->>'capUcents')::bigint = 120000000, 'pro cap after conversion');
select public.assert_true((public.ai_status(:a)->>'taskCapUcents')::bigint = 50000000, 'pro task cap');
-- Revoked / expired entitlements don't count.
update public.ipad_entitlements set revoked_at = now() where original_transaction_id = '2001';
select public.assert_true(public.ai_status(:a)->>'plan' = 'plus', 'revoked pro ignored');
update public.ipad_entitlements set expires_at = now() - interval '1 second' where original_transaction_id = '1001';
select public.assert_true(public.ai_status(:a)->>'plan' = 'none', 'expired plus ignored');

-- Credit: budget pays first, credit covers the overflow, grants are idempotent and owned.
select public.ai_grant_credit(:b, 'pack', 'tx-1', 200000000);
select public.ai_grant_credit(:b, 'pack', 'tx-1', 200000000);
select public.assert_true((public.ai_status(:b)->>'creditUcents')::bigint = 200000000, 'grant paid once');
do $$ begin
  perform public.ai_grant_credit('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'pack', 'tx-1', 200000000);
  raise exception 'grant reused by another account';
exception when insufficient_privilege then null; end $$;
-- b is free ($0.02). 3,000,000 µ¢ cost: 2,000,000 from budget, 1,000,000 from credit.
select public.ai_settle(:b, '44444444-4444-4444-8444-444444444444', 'a0000000-0000-4000-8000-000000000020', 'claude-sonnet-5-5', 'high', 'question', 15000, 0, 0, 0, false);
select public.assert_true((public.ai_status(:b)->>'spentUcents')::bigint = 2000000, 'budget used first');
select public.assert_true((public.ai_status(:b)->>'creditUcents')::bigint = 199000000, 'credit covers overflow');
select public.assert_true((select not complete from public.ai_usage_ledger where user_id = :b), 'partial step recorded');
select public.ai_revoke_credit('pack', 'tx-1');
select public.ai_revoke_credit('pack', 'tx-1');
select public.assert_true((public.ai_status(:b)->>'creditUcents')::bigint = -1000000, 'refund takes credit back once');
select public.assert_true(public.ai_begin(:b, '55555555-5555-4555-8555-555555555555', 'a0000000-0000-4000-8000-000000000021', 'claude-haiku-5-5', 0, 8192)->>'code' = 'BUDGET_EXHAUSTED', 'nothing left');

-- Consent.
select public.assert_true(public.ai_status(:b)->'consents' = '{}'::jsonb, 'no consent yet');
select public.ai_record_consent(:b, 'anthropic', 1);
select public.assert_true((public.ai_status(:b)->'consents'->>'anthropic')::integer = 1, 'consent recorded');
do $$ begin
  perform public.ai_record_consent('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'gemini', 1);
  raise exception 'unknown provider accepted';
exception when invalid_parameter_value then null; end $$;
do $$ begin
  perform public.ai_settle('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', '44444444-4444-4444-8444-444444444444', 'a0000000-0000-4000-8000-000000000022', 'gpt-4o', null, 'question', 1, 1, 0, 0, true);
  raise exception 'unknown model accepted';
exception when invalid_parameter_value then null; end $$;

-- Month boundary: a budget row from last month does not count.
reset role;
update public.ai_budget set period = '2000-01' where user_id = :a;
set role service_role;
select public.assert_true((public.ai_status(:a)->>'spentUcents')::bigint = 0, 'new month starts empty');
reset role;
select 'PASS: ai metering, budgets, credit, task caps, consent' as result;
