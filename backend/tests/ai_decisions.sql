-- Decisions (202611140001): input-only reservations and the 'decide' kind; text steps sized as before.
\set d '''dddddddd-dddd-4ddd-8ddd-dddddddddddd'''
insert into auth.users values ('dddddddd-dddd-4ddd-8ddd-dddddddddddd');
set role authenticated;
do $$ begin
  perform public.ai_begin('dddddddd-dddd-4ddd-8ddd-dddddddddddd', 'd1111111-1111-4111-8111-111111111111', 'd0000000-0000-4000-8000-000000000001', 'gpt-6-luna', 400, 0);
  raise exception 'authenticated unexpectedly called ai_begin';
exception when insufficient_privilege then null; end $$;
reset role;

set role service_role;
-- Free account, $0.02 = 2,000,000 µ¢. gpt-6-luna input 400 × 10 = 4,000 µ¢, no output reserved.
select public.assert_true((public.ai_begin(:d, 'd1111111-1111-4111-8111-111111111111', 'd0000000-0000-4000-8000-000000000001', 'gpt-6-luna', 400, 0)->>'ok')::boolean, 'decision begins');
select public.assert_true((public.ai_begin(:d, 'd1111111-1111-4111-8111-111111111111', 'd0000000-0000-4000-8000-000000000002', 'gpt-6-luna', 400, 0)->>'maxOutput')::bigint = 0, 'no output for a decision');
select public.assert_true((public.ai_status(:d)->>'reservedUcents')::bigint = 8000, 'input alone is reserved');
select public.ai_release(:d, 'd0000000-0000-4000-8000-000000000002');
-- Settled from usage.input_tokens with no output: 412 × 10.
select public.assert_true((public.ai_settle(:d, 'd1111111-1111-4111-8111-111111111111', 'd0000000-0000-4000-8000-000000000001', 'gpt-6-luna', null, 'decide', 412, 0, 0, 0, true)->>'costUcents')::bigint = 4120, 'decision cost');
select public.assert_true((public.ai_status(:d)->>'reservedUcents')::bigint = 0, 'settle releases the reservation');
select public.assert_true((public.ai_status(:d)->>'spentUcents')::bigint = 4120, 'spent recorded');
select public.assert_true((select kind = 'decide' and tokens_in = 412 and tokens_out = 0 and cost_ucents = 4120 and effort is null and complete
  from public.ai_usage_ledger where user_id = :d), 'ledger row of kind decide');

-- 5,000 µ¢ left: a text step cannot fit min_output_tokens (256 × 50 = 12,800), a 400-token decision (4,000) can.
reset role;
update public.ai_budget set spent_ucents = 1995000 where user_id = :d;
set role service_role;
select public.assert_true(public.ai_begin(:d, 'd2222222-2222-4222-8222-222222222222', 'd0000000-0000-4000-8000-000000000003', 'gpt-6-luna', 400, 8192)->>'code' = 'BUDGET_EXHAUSTED', 'text step refused under min output');
select public.assert_true((public.ai_begin(:d, 'd2222222-2222-4222-8222-222222222222', 'd0000000-0000-4000-8000-000000000004', 'gpt-6-luna', 400, 0)->>'ok')::boolean, 'decision still fits');
-- Its reservation counts: 1,000 µ¢ left, so a 200-token decision (2,000) does not fit.
select public.assert_true(public.ai_begin(:d, 'd2222222-2222-4222-8222-222222222222', 'd0000000-0000-4000-8000-000000000005', 'gpt-6-luna', 200, 0)->>'code' = 'BUDGET_EXHAUSTED', 'input over what is left');
select public.ai_release(:d, 'd0000000-0000-4000-8000-000000000004');
select public.assert_true((public.ai_begin(:d, 'd2222222-2222-4222-8222-222222222222', 'd0000000-0000-4000-8000-000000000006', 'gpt-6-luna', 500, 0)->>'ok')::boolean, 'exactly what is left fits');
select public.ai_release(:d, 'd0000000-0000-4000-8000-000000000006');

-- Text steps after the replacement, as before: output sized to what is left, refused below min output.
reset role;
update public.ai_budget set spent_ucents = 1000000 where user_id = :d;
set role service_role;
-- 1,000,000 left; Haiku 1000 in × 12.5 = 12,500 → floor(987,500 / 50) = 19,750, capped at the 8192 asked.
select public.assert_true((public.ai_begin(:d, 'd3333333-3333-4333-8333-333333333333', 'd0000000-0000-4000-8000-000000000007', 'claude-haiku-5-5', 1000, 8192)->>'maxOutput')::bigint = 8192, 'text output capped at the request');
select public.ai_release(:d, 'd0000000-0000-4000-8000-000000000007');
-- Sonnet 1000 in × 250 = 250,000 → floor(750,000 / 1000) = 750.
select public.assert_true((public.ai_begin(:d, 'd3333333-3333-4333-8333-333333333333', 'd0000000-0000-4000-8000-000000000008', 'claude-sonnet-5-5', 1000, 8192)->>'maxOutput')::bigint = 750, 'text output sized to budget');
select public.ai_release(:d, 'd0000000-0000-4000-8000-000000000008');
-- Sonnet 3000 in × 250 = 750,000 → 250 output tokens < 256: refused.
select public.assert_true(public.ai_begin(:d, 'd3333333-3333-4333-8333-333333333333', 'd0000000-0000-4000-8000-000000000009', 'claude-sonnet-5-5', 3000, 8192)->>'code' = 'BUDGET_EXHAUSTED', 'text step under min output refused');
do $$ begin
  perform public.ai_begin('dddddddd-dddd-4ddd-8ddd-dddddddddddd', 'd3333333-3333-4333-8333-333333333333', 'd0000000-0000-4000-8000-000000000010', 'gpt-6-luna', 10, -1);
  raise exception 'negative output accepted';
exception when invalid_parameter_value then null; end $$;
do $$ begin
  perform public.ai_settle('dddddddd-dddd-4ddd-8ddd-dddddddddddd', 'd3333333-3333-4333-8333-333333333333', 'd0000000-0000-4000-8000-000000000011', 'gpt-6-luna', null, 'chat', 1, 0, 0, 0, true);
  raise exception 'unknown kind accepted';
exception when invalid_parameter_value then null; end $$;
select public.assert_true((public.ai_settle(:d, 'd3333333-3333-4333-8333-333333333333', 'd0000000-0000-4000-8000-000000000012', 'claude-haiku-5-5', 'low', 'explain', 100, 10, 0, 0, true)->>'costUcents')::bigint = 1500, 'existing kinds still settle');
reset role;
select 'PASS: ai decisions, input-only reservations, decide kind' as result;
