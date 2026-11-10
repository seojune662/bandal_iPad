-- After run-local.sh, from six sessions at once, completed invitee 25 twice and invitee 26 with
-- their inviter 20 one invitee short of the five, completed 27 and 28, who invited each other,
-- and asked for account 29's status twice (set up at the end of referral.sql).
select public.assert_true((select completed = 6 from public.referral_code where owner_id = public.test_user(20)), 'each invitee is counted once');
select public.assert_true((select balance_ucents = 35000000 from public.ai_credit where user_id = public.test_user(20))
  and (select count(*) = 5 from public.ai_credit_grants where user_id = public.test_user(20) and source = 'referral'), 'the inviter is paid for five, not six');
select public.assert_true((select count(*) = 2 and bool_and(balance_ucents = 7000000) from public.ai_credit where user_id in (public.test_user(25), public.test_user(26)))
  and (select count(*) = 2 from public.ai_credit_grants where user_id in (public.test_user(25), public.test_user(26))), 'each invitee is paid once');
select public.assert_true((select count(*) = 2 and bool_and(grants = 2 and total = 14000000) from (select count(*) as grants, sum(amount_ucents) as total
    from public.ai_credit_grants where source = 'referral' and user_id in (public.test_user(27), public.test_user(28)) group by user_id) paid)
  and (select count(*) = 2 and bool_and(completed = 1) from public.referral_code where owner_id in (public.test_user(27), public.test_user(28))), 'two accounts that invited each other are both paid twice');
select public.assert_true((select count(*) = 4 and bool_and(completed_at is not null and rewarded_at is not null) from public.referral_claim
  where referee_id in (public.test_user(25), public.test_user(26), public.test_user(27), public.test_user(28))), 'all four claims are completed');
select public.assert_true((select count(*) = 1 from public.referral_code where owner_id = public.test_user(29)), 'one code for an account that asked twice at once');
select 'PASS: referral from several sessions at once' as result;
