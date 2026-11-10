-- Gemini as a third provider: consent and a model row are accepted; anything else is still refused.
\set b '''bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'''
set role service_role;
select public.ai_record_consent(:b, 'google', 1);
select public.assert_true((public.ai_status(:b)->'consents'->>'google')::integer = 1, 'google consent recorded');
insert into public.ai_models(id, provider, label, p_in, p_out, p_cache_r, p_cache_w, context_cap, enabled, sort)
  values ('gemini-fixture', 'google', 'Gemini fixture', 10, 50, 1, 0, 100000, false, 70);
do $$ begin
  perform public.ai_record_consent('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'mistral', 1);
  raise exception 'unknown provider unexpectedly accepted';
exception when invalid_parameter_value then null; end $$;
delete from public.ai_models where id = 'gemini-fixture';
reset role;
