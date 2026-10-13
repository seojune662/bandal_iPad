create function public.assert_true(value boolean, message text) returns void language plpgsql as $$
begin if value is distinct from true then raise exception 'Assertion failed: %',message; end if; end;
$$;
create function public.test_operation(op text, rid text, base bigint, kind text default 'note', deleted boolean default false)
returns jsonb language sql immutable as $$
  select jsonb_build_object('id',op,'baseRevision',base,'record',jsonb_build_object(
    'id',rid,'kind',kind,'payload','e30=','revision',base+1,'deleted',deleted,'formatVersion',1))
$$;

set role authenticated;
select set_config('request.jwt.claim.sub','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',false);
select public.assert_true(public.bandal_push(public.test_operation('op1','n',0))->>'status'='accepted','first push');
select public.assert_true(public.bandal_push(public.test_operation('op1','n',0))->>'status'='accepted','idempotent replay');
select public.assert_true((select count(*)=1 from public.bandal_changes),'replay created no second change');
do $$ begin
  perform public.bandal_push(public.test_operation('op1','other',0));
  raise exception 'Reused ID unexpectedly accepted';
exception when invalid_parameter_value then null; end $$;
select public.assert_true(public.bandal_push(public.test_operation('op2','n',1))->>'status'='accepted','second revision');
select public.assert_true(public.bandal_push(public.test_operation('stale','n',1))->>'status'='conflict','stale revision conflict');
select public.assert_true((public.bandal_push(public.test_operation('stale','n',1))->'record'->>'revision')::integer=2,'conflict preserves remote revision');
select public.assert_true(public.bandal_push(public.test_operation('delete','n',2,'note',true))->>'status'='accepted','tombstone push');
select public.assert_true((public.bandal_pull(0,1)->>'hasMore')::boolean,'pull pagination');
select public.assert_true(jsonb_array_length(public.bandal_pull(0,100)->'records')=3,'all accepted changes retained');
select public.assert_true((select (envelope->>'deleted')::boolean from public.bandal_records where record_id='n'),'tombstone retained');
do $$ begin
  perform public.bandal_push(public.test_operation('secret','secret',0,'cookie'));
  raise exception 'Secret kind unexpectedly accepted';
exception when invalid_parameter_value then null; end $$;
do $$ begin
  insert into public.bandal_records values(auth.uid(),'bypass','note',1,'{}');
  raise exception 'Direct mutation unexpectedly allowed';
exception when insufficient_privilege then null; end $$;

insert into storage.objects(bucket_id,name) values('bandal-assets','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/' || repeat('a',64));
do $$ begin
  insert into storage.objects(bucket_id,name) values('bandal-assets','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb/' || repeat('b',64));
  raise exception 'Cross-user asset upload unexpectedly allowed';
exception when insufficient_privilege then null; end $$;
update storage.objects set name='overwritten' where bucket_id='bandal-assets';
select public.assert_true((select count(*)=1 from storage.objects where name like '%/' || repeat('a',64)),'assets cannot overwrite');

select set_config('request.jwt.claim.sub','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',false);
select public.assert_true(jsonb_array_length(public.bandal_pull(0,100)->'records')=0,'other user cannot pull');
select public.assert_true((select count(*)=0 from public.bandal_records),'records RLS');
select public.assert_true((select count(*)=0 from public.bandal_operations),'receipts RLS');
select public.assert_true((select count(*)=0 from storage.objects),'assets RLS');
select public.assert_true(public.bandal_push(public.test_operation('op1','n',0))->>'status'='accepted','IDs scoped per user');

reset role;
set role anon;
select set_config('request.jwt.claim.sub','',false);
do $$ begin
  perform public.bandal_pull(0,100);
  raise exception 'Anonymous pull unexpectedly allowed';
exception when insufficient_privilege then null; end $$;
reset role;
select 'PASS: idempotency, conflicts, tombstones, cursors, owner isolation, asset immutability, auth' as result;
