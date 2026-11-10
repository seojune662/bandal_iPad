-- Gemini through the ai-proxy (POST /v1/google). This only widens the provider checks; no
-- Gemini model is listed until a row is inserted with its real price, e.g.
--   insert into public.ai_models(id, provider, label, p_in, p_out, p_cache_r, p_cache_w, context_cap, enabled, sort)
--   values ('<model id>', 'google', '<label>', <ucents per 1M in>, <out>, <cache read>, 0, 100000, true, 70);
-- The function also needs the GEMINI_API_KEY secret.
begin;

alter table public.ai_models drop constraint ai_models_provider_check;
alter table public.ai_models add constraint ai_models_provider_check check (provider in ('anthropic','openai','google'));
alter table public.ai_consent drop constraint ai_consent_provider_check;
alter table public.ai_consent add constraint ai_consent_provider_check check (provider in ('anthropic','openai','google'));

create or replace function public.ai_record_consent(actor uuid, provider_id text, consent_version integer) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
begin
  if actor is null then raise exception 'sign_in_required' using errcode = '42501'; end if;
  if provider_id not in ('anthropic','openai','google') or consent_version is null or consent_version < 1 then
    raise exception 'invalid_request' using errcode = '22023';
  end if;
  insert into public.ai_consent(user_id, provider, version) values (actor, provider_id, consent_version)
    on conflict (user_id, provider) do update set version = excluded.version, agreed_at = now();
  return public.ai_status(actor);
end $$;

commit;
