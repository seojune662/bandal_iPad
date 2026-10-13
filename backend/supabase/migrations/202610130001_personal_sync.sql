-- Personal content sync. Requires Supabase auth/storage. Deploy separately;
-- this migration does not modify the desktop app's existing tables.
begin;

create table public.bandal_records (
  user_id uuid not null references auth.users(id) on delete cascade,
  record_id text not null,
  kind text not null check (kind in (
    'course','material','note','drawing','annotation','board','task',
    'calendarEvent','recording','favorite','chat','learningEvent',
    'vocabulary','flashcard','quiz','artifact')),
  revision bigint not null check (revision > 0),
  envelope jsonb not null,
  primary key (user_id, record_id)
);
create table public.bandal_operations (
  user_id uuid not null references auth.users(id) on delete cascade,
  operation_id text not null,
  request jsonb not null,
  result jsonb not null,
  primary key (user_id, operation_id)
);
create table public.bandal_changes (
  sequence bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  envelope jsonb not null
);
create index bandal_changes_user_sequence on public.bandal_changes(user_id, sequence);

alter table public.bandal_records enable row level security;
alter table public.bandal_operations enable row level security;
alter table public.bandal_changes enable row level security;
revoke all on public.bandal_records, public.bandal_operations, public.bandal_changes from anon, authenticated;
grant select on public.bandal_records, public.bandal_operations, public.bandal_changes to authenticated;
create policy records_owner on public.bandal_records for select to authenticated using (user_id = (select auth.uid()));
create policy operations_owner on public.bandal_operations for select to authenticated using (user_id = (select auth.uid()));
create policy changes_owner on public.bandal_changes for select to authenticated using (user_id = (select auth.uid()));

create function public.bandal_push(p_operation jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := auth.uid();
  op_id text := p_operation->>'id';
  incoming jsonb := p_operation->'record';
  rid text := incoming->>'id';
  record_kind text := incoming->>'kind';
  base_revision bigint;
  next_revision bigint;
  existing public.bandal_records%rowtype;
  replay public.bandal_operations%rowtype;
  answer jsonb;
  payload_bytes bytea;
begin
  if actor is null then raise exception 'Authentication required' using errcode = '42501'; end if;
  if jsonb_typeof(p_operation) is distinct from 'object' or
     jsonb_typeof(incoming) is distinct from 'object' or
     op_id is null or length(op_id) not between 1 and 128 or
     rid is null or octet_length(rid) not between 1 and 512 or
     record_kind is null or record_kind not in (
       'course','material','note','drawing','annotation','board','task',
       'calendarEvent','recording','favorite','chat','learningEvent',
       'vocabulary','flashcard','quiz','artifact') or
     incoming->>'formatVersion' is distinct from '1' or
     jsonb_typeof(incoming->'deleted') is distinct from 'boolean' or
     jsonb_typeof(incoming->'payload') is distinct from 'string' then
    raise exception 'Invalid operation envelope' using errcode = '22023';
  end if;
  base_revision := (p_operation->>'baseRevision')::bigint;
  next_revision := (incoming->>'revision')::bigint;
  if base_revision is null or base_revision < 0 or next_revision is null or
     base_revision >= 9007199254740990 or next_revision <> base_revision + 1 then
    raise exception 'Invalid revision' using errcode = '22023';
  end if;
  payload_bytes := decode(incoming->>'payload', 'base64');
  if octet_length(payload_bytes) > 4194304 then raise exception 'Payload too large' using errcode = '22023'; end if;
  -- Verify that the portable Data payload is JSON; keep its original bytes so
  -- acknowledgements are byte-identical and no platform-specific JSON rewrite occurs.
  perform convert_from(payload_bytes, 'UTF8')::jsonb;

  -- Serialize ALL mutations per owner, including the change sequence allocation.
  -- Per-record locks alone allow a later sequence to commit first and make a
  -- cursor permanently skip an earlier, still-uncommitted transaction.
  perform pg_advisory_xact_lock(hashtextextended(actor::text, 0));
  select * into replay from public.bandal_operations where user_id=actor and operation_id=op_id;
  if found then
    if replay.request <> p_operation then raise exception 'Operation ID reused with different content' using errcode = '22023'; end if;
    return replay.result;
  end if;

  select * into existing from public.bandal_records where user_id=actor and record_id=rid;
  if found then
    if existing.kind <> record_kind then raise exception 'Record kind cannot change' using errcode = '22023'; end if;
    if existing.revision <> base_revision then
      answer := jsonb_build_object('status','conflict','record',existing.envelope);
    end if;
  elsif base_revision <> 0 then
    answer := jsonb_build_object('status','conflict','record',
      jsonb_build_object('id',rid,'kind',record_kind,'payload','e30=',
                        'revision',0,'deleted',true,'formatVersion',1));
  end if;
  if answer is null then
    insert into public.bandal_records(user_id,record_id,kind,revision,envelope)
      values(actor,rid,record_kind,next_revision,incoming)
      on conflict(user_id,record_id) do update set revision=excluded.revision,envelope=excluded.envelope;
    insert into public.bandal_changes(user_id,envelope) values(actor,incoming);
    answer := jsonb_build_object('status','accepted','record',incoming);
  end if;
  insert into public.bandal_operations(user_id,operation_id,request,result) values(actor,op_id,p_operation,answer);
  return answer;
end;
$$;

create function public.bandal_pull(p_after bigint default 0, p_limit integer default 200) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := auth.uid();
  result_records jsonb;
  next_cursor bigint;
  more boolean;
begin
  if actor is null then raise exception 'Authentication required' using errcode = '42501'; end if;
  if p_after is null or p_after < 0 or p_limit is null or p_limit not between 1 and 1000 then
    raise exception 'Invalid cursor or limit' using errcode = '22023';
  end if;
  select coalesce(jsonb_agg(batch.envelope order by batch.sequence),'[]'::jsonb), coalesce(max(batch.sequence),p_after)
    into result_records,next_cursor
    from (select sequence,envelope from public.bandal_changes
           where user_id=actor and sequence>p_after order by sequence limit p_limit) batch;
  select exists(select 1 from public.bandal_changes where user_id=actor and sequence>next_cursor) into more;
  return jsonb_build_object('records',result_records,'cursor',next_cursor,'hasMore',more);
end;
$$;

revoke all on function public.bandal_push(jsonb), public.bandal_pull(bigint,integer) from public, anon;
grant execute on function public.bandal_push(jsonb), public.bandal_pull(bigint,integer) to authenticated;

insert into storage.buckets(id,name,public,file_size_limit)
values('bandal-assets','bandal-assets',false,536870912);
create policy bandal_assets_read on storage.objects for select to authenticated using (
  bucket_id='bandal-assets' and (storage.foldername(name))[1]=(select auth.uid())::text
);
create policy bandal_assets_create on storage.objects for insert to authenticated with check (
  bucket_id='bandal-assets' and
  name ~ ('^' || (select auth.uid())::text || '/[0-9a-f]{64}$')
);
-- No UPDATE policy: content-addressed bytes are immutable. No client DELETE:
-- account deletion / audited GC can remove unreferenced objects later.
commit;
