-- App Store entitlements, grace, ownership, event dedupe, pack redeem. Runs as service_role.
\set a '''aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'''
\set b '''bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'''
set role service_role;
select public.ipad_apply_entitlement(:a, 'production', '9001', '10', 'app.bandal.ipad.plus.monthly', 'plus', true, now() + interval '7 days', null, now() - interval '1 hour', 'keep', null);
select public.assert_true(public.ai_status(:a)->>'plan' = 'plus' and (public.ai_status(:a)->>'trial')::boolean, 'trial plus');
-- Upgrade to Pro: same original transaction, newer signature.
select public.ipad_apply_entitlement(:a, 'production', '9001', '11', 'app.bandal.ipad.pro.monthly', 'pro', false, now() + interval '30 days', null, now(), 'keep', null);
select public.assert_true(public.ai_status(:a)->>'plan' = 'pro' and not (public.ai_status(:a)->>'trial')::boolean, 'upgraded to paid pro');
-- An older signature does not roll it back.
select public.ipad_apply_entitlement(:a, 'production', '9001', '10', 'app.bandal.ipad.plus.monthly', 'plus', true, now() + interval '7 days', null, now() - interval '2 hours', 'keep', null);
select public.assert_true(public.ai_status(:a)->>'plan' = 'pro', 'stale signature ignored');
-- Another account cannot take it.
do $$ begin
  perform public.ipad_apply_entitlement('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'production', '9001', '10', 'app.bandal.ipad.pro.monthly', 'pro', false, now() + interval '30 days', null, now() + interval '1 hour', 'keep', null);
  raise exception 'transaction moved to another account';
exception when insufficient_privilege then null; end $$;
select public.assert_true(public.ipad_entitlement_owner('production', '9001') = :a, 'owner lookup');
-- Expired but in grace: plan lasts to the grace end, even when a client sync sends the old expiry later.
select public.ipad_apply_entitlement(:a, 'production', '9001', '12', 'app.bandal.ipad.pro.monthly', 'pro', false, now() - interval '1 day', null, now() + interval '2 hours', 'set', now() + interval '16 days');
select public.assert_true(public.ai_status(:a)->>'plan' = 'pro', 'grace keeps pro');
select public.ipad_apply_entitlement(:a, 'production', '9001', '13', 'app.bandal.ipad.pro.monthly', 'pro', false, now() - interval '1 day', null, now() + interval '3 hours', 'keep', null);
select public.assert_true(public.ai_status(:a)->>'plan' = 'pro', 'client sync keeps grace');
select public.ipad_apply_entitlement(:a, 'production', '9001', '14', 'app.bandal.ipad.pro.monthly', 'pro', false, now() - interval '1 day', null, now() + interval '4 hours', 'clear', null);
select public.assert_true(public.ai_status(:a)->>'plan' = 'none', 'grace expired');
-- A refund of an earlier period (tx 11, older signature) does not end the current one.
select public.ipad_apply_entitlement(:a, 'production', '9001', '11', 'app.bandal.ipad.pro.monthly', 'pro', false, now() + interval '20 days', now(), now() - interval '1 day', 'keep', null);
select public.assert_true((select revoked_at is null from public.ipad_entitlements where original_transaction_id = '9001'), 'old-period refund ignored');
-- An unknown (deleted) account is ignored.
select public.ipad_apply_entitlement('dddddddd-dddd-4ddd-8ddd-dddddddddddd', 'production', '9100', '1', 'app.bandal.ipad.plus.monthly', 'plus', false, now() + interval '1 day', null, now(), 'keep', null);
select public.assert_true(not exists (select 1 from public.ipad_entitlements where original_transaction_id = '9100'), 'unknown account ignored');
-- Revoked (refund) ends it at once.
select public.ipad_apply_entitlement(:a, 'production', '9002', '20', 'app.bandal.ipad.plus.yearly', 'plus', false, now() + interval '300 days', now(), now(), 'keep', null);
select public.assert_true(public.ai_status(:a)->>'plan' = 'none', 'refunded plus ignored');
-- Notification dedupe.
select public.assert_true(public.ipad_claim_event('production', '0e0e0e0e-0000-4000-8000-000000000001', 'DID_RENEW'), 'first claim');
select public.assert_true(not public.ipad_claim_event('production', '0e0e0e0e-0000-4000-8000-000000000001', 'DID_RENEW'), 'repeat ignored');
-- Pack redeem pays ai_settings.pack_ucents once per transaction.
select public.ipad_redeem_pack(:b, 'sandbox', '7001');
select public.ipad_redeem_pack(:b, 'sandbox', '7001');
select public.assert_true((select balance_ucents from public.ai_credit where user_id = :b) = 200000000 + 200000000 - 1000000 - 200000000, 'pack paid once on top of earlier credit');
do $$ begin
  perform public.ipad_redeem_pack('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'sandbox', '7001');
  raise exception 'pack redeemed by another account';
exception when insufficient_privilege then null; end $$;
-- A pack refunded before redeem never pays; one refunded after is taken back.
select public.ipad_revoke_pack('sandbox', '7002');
do $$ begin
  perform public.ipad_redeem_pack('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'sandbox', '7002');
  raise exception 'refunded pack redeemed';
exception when insufficient_privilege then null; end $$;
select public.ipad_revoke_pack('sandbox', '7001');
select public.assert_true((select balance_ucents from public.ai_credit where user_id = :b) = 199000000 - 200000000, 'pack refund after redeem');
reset role;
select 'PASS: store entitlements, grace, ownership, events, packs' as result;
