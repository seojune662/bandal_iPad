-- Decisions through the ai-proxy (POST /v1/openai/decisions, 찾아보기 1.4.x). A decision model returns
-- probabilities and choices, never text, and OpenAI bills its input tokens only. Two functions change:
--   ai_begin   max_output = 0 reserves the input alone and refuses only when that does not fit what is left
--              (month budget + credit − other open reservations, and the task cap). min_output_tokens is not
--              asked of such a step: a free account with $0.001 left can still be asked a 300-token decision.
--              Every max_output ≥ 1 behaves exactly as before.
--   ai_settle  takes the kind 'decide' (the ledger row has tokens_out = 0).
-- Prices are unchanged: the step is charged at the model's p_in (gpt-6-luna, $0.10/MTok).
begin;

create or replace function public.ai_begin(actor uuid, task uuid, step uuid, model_id text, input_tokens bigint, max_output integer) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare st jsonb; m public.ai_models; s public.ai_settings; owner uuid; task_used bigint; input_cost bigint;
  budget_left bigint; task_left bigint; available bigint; output bigint;
begin
  if task is null or step is null or input_tokens is null or input_tokens < 0 or max_output is null or max_output < 0 then
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
  output := case when max_output = 0 or m.p_out = 0 then max_output else least(max_output, floor(greatest(available, 0) / m.p_out))::bigint end;
  if available < 0 or (max_output > 0 and output < s.min_output_tokens) then
    return jsonb_build_object('ok', false, 'code', case when task_left < budget_left then 'TASK_CAP_REACHED' else 'BUDGET_EXHAUSTED' end, 'status', st);
  end if;
  insert into public.ai_reservation(id, user_id, task_id, amount_ucents) values (step, actor, task, input_cost + ceil(output * m.p_out)::bigint);
  return jsonb_build_object('ok', true, 'maxOutput', output, 'status', public.ai_status(actor));
end $$;

create or replace function public.ai_settle(actor uuid, task uuid, step uuid, model_id text, effort text, kind text,
  t_in bigint, t_out bigint, t_cache_r bigint, t_cache_w bigint, complete boolean) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare m public.ai_models; st jsonb; cost bigint; budget_left bigint; from_credit bigint := 0;
begin
  if t_in < 0 or t_out < 0 or t_cache_r < 0 or t_cache_w < 0 then raise exception 'invalid_request' using errcode = '22023'; end if;
  if kind not in ('question','summary','quiz','translate','routine','explain','decide') then raise exception 'invalid_request' using errcode = '22023'; end if;
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

-- `create or replace` keeps the grants; stated again so this file is right on its own.
revoke all on function public.ai_begin(uuid,uuid,uuid,text,bigint,integer) from public, anon, authenticated;
grant execute on function public.ai_begin(uuid,uuid,uuid,text,bigint,integer) to service_role;
revoke all on function public.ai_settle(uuid,uuid,uuid,text,text,text,bigint,bigint,bigint,bigint,boolean) from public, anon, authenticated;
grant execute on function public.ai_settle(uuid,uuid,uuid,text,text,text,bigint,bigint,bigint,bigint,boolean) to service_role;

commit;
