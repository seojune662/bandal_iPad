-- Runs against the real Supabase schema; all fixtures and helpers roll back.
-- No existing accounts, content, buckets, policies or files are modified.
begin;
insert into auth.users(id) values ('69cd2ea9-a30e-489d-8728-c59b9443c993'), ('35de9da4-c893-41f0-a7e6-afdf77bf90c1');
create function public.bandal_probe_assert(ok boolean) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'Bandal validation failed'; end if; end $$;
create function public.bandal_probe_operation(op text, base bigint) returns jsonb language sql as $$
 select jsonb_build_object('id',op,'baseRevision',base,'record',jsonb_build_object(
  'id','__validation__','kind','note','payload','e30=','revision',base+1,'deleted',false,'formatVersion',1))
$$;
set local role authenticated;
select set_config('request.jwt.claim.sub','69cd2ea9-a30e-489d-8728-c59b9443c993',true);
select public.bandal_probe_assert(public.bandal_push(public.bandal_probe_operation('validation-1',0))->>'status'='accepted');
select public.bandal_probe_assert(public.bandal_push(public.bandal_probe_operation('validation-1',0))->>'status'='accepted');
select public.bandal_probe_assert(jsonb_array_length(public.bandal_pull(0,100)->'records')=1);
select public.bandal_probe_assert(public.bandal_push(public.bandal_probe_operation('validation-stale',0))->>'status'='conflict');
insert into storage.objects(bucket_id,name) values('bandal-assets','69cd2ea9-a30e-489d-8728-c59b9443c993/' || repeat('a',64));
do $$ begin
 insert into storage.objects(bucket_id,name) values('bandal-assets','35de9da4-c893-41f0-a7e6-afdf77bf90c1/' || repeat('b',64));
 raise exception 'Cross-account storage accepted';
exception when insufficient_privilege then null; end $$;
select set_config('request.jwt.claim.sub','35de9da4-c893-41f0-a7e6-afdf77bf90c1',true);
select public.bandal_probe_assert(jsonb_array_length(public.bandal_pull(0,100)->'records')=0);
select public.bandal_probe_assert((select count(*)=0 from public.bandal_records));
select public.bandal_probe_assert((select count(*)=0 from storage.objects where bucket_id='bandal-assets'));
reset role;
select public.bandal_probe_assert(not has_function_privilege('anon','public.bandal_pull(bigint,integer)','execute'));
select 'PASS: live RLS, replay, conflict and storage access; fixtures rolled back' as result;
rollback;
