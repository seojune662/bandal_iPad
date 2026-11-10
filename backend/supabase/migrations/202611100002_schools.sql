-- "Set up my school": one school catalogue shared by every account. The 18 schools bundled with
-- the app are seeded as verified. A school nobody has set up yet is looked up once by the AI
-- routine of the `schools` Edge Function and kept, unverified, for everyone after. A student's
-- own edits are only recorded for review.
--   schools, school_links      the catalogue
--   school_setup_runs          one row per AI run: the daily limit and the cost log (µ¢, Bandal pays)
--   school_link_suggestions    edits for an admin to look at; never applied to a school
-- service_role only, like 202611060001_ai_metering: the app goes through the Edge Function.
begin;

-- Matching. school_fold is the text in lower case without whitespace; school_key is that minus
-- a trailing 대학교/대학/university/univ, so "서울 대학교", "서울대학교" and "서울대학" are one school.
-- Names are unique by key within a country. Aliases are only ever compared folded: the bundled
-- alias "대구" (경북대학교) must not make "대구대학교" look like the same school.
create function public.school_fold(value text) returns text
language sql immutable strict parallel safe set search_path = '' as $$
  select regexp_replace(lower(value), '\s+', '', 'g')
$$;
create function public.school_key(value text) returns text
language sql immutable strict parallel safe set search_path = '' as $$
  select regexp_replace(public.school_fold(value), '(대학교|대학|university|univ)$', '')
$$;

-- Bundled rows keep the app's ids ("snu", "snu.portal") so the app can tell them apart from its
-- own copy; everything else gets a UUID.
create table public.schools(
  id text primary key default gen_random_uuid()::text check (length(id) between 1 and 64),
  name text not null check (length(name) between 1 and 80 and public.school_key(name) <> ''),
  name_en text check (length(name_en) between 1 and 120),
  aliases text[] not null default '{}',
  country text not null check (country ~ '^[A-Z]{2}$'),
  domain text check (length(domain) between 3 and 253),
  verified boolean not null default false,
  source text not null check (source in ('bundled','ai','user')),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index schools_key_country on public.schools(public.school_key(name), country);

create table public.school_links(
  id text primary key default gen_random_uuid()::text check (length(id) between 1 and 64),
  school_id text not null references public.schools(id) on delete cascade,
  kind text not null check (kind in ('home','portal','lms','library','calendar','mail','registration','other')),
  title text not null check (length(title) between 1 and 60),
  url text not null check (url ~ '^https?://' and length(url) <= 500),
  verified boolean not null default false,
  "order" integer not null default 0
);
create index school_links_school on public.school_links(school_id, "order");

-- status: running → found | not_found | failed (the run broke after it may have cost something)
-- | unavailable (the AI was never reached; does not count against the daily limit).
create table public.school_setup_runs(
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  query text not null check (length(query) between 1 and 80),
  country text not null check (country ~ '^[A-Z]{2}$'),
  school_id text references public.schools(id) on delete set null,
  cost_ucents bigint not null default 0 check (cost_ucents >= 0),
  status text not null default 'running' check (status in ('running','found','not_found','failed','unavailable')),
  created_at timestamptz not null default now()
);
create index school_setup_runs_user on public.school_setup_runs(user_id, created_at);
create index school_setup_runs_created on public.school_setup_runs(created_at);
create index school_setup_runs_answered on public.school_setup_runs(public.school_key(query), country) where school_id is not null;

create table public.school_link_suggestions(
  id uuid primary key default gen_random_uuid(),
  school_id text not null references public.schools(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  links jsonb not null check (jsonb_typeof(links) = 'array'),
  created_at timestamptz not null default now()
);
create index school_link_suggestions_user on public.school_link_suggestions(user_id, created_at);

do $$ declare t text; begin
  foreach t in array array['schools','school_links','school_setup_runs','school_link_suggestions'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from public, anon, authenticated', t);
    execute format('grant all on public.%I to service_role', t);
  end loop;
end $$;

-- The School object of the Edge Function's API, links in display order. Null for an unknown id.
create function public.school_json(school text) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', s.id, 'name', s.name, 'nameEn', s.name_en, 'aliases', to_jsonb(s.aliases), 'country', s.country,
    'domain', s.domain, 'verified', s.verified, 'source', s.source,
    'links', coalesce((select jsonb_agg(jsonb_build_object(
        'id', l.id, 'kind', l.kind, 'title', l.title, 'url', l.url, 'verified', l.verified, 'order', l."order")
        order by l."order", l.id)
      from public.school_links l where l.school_id = s.id), '[]'::jsonb))
  from public.schools s where s.id = school
$$;

-- Search as the student types: any part of a name, English name or alias. Names also match by
-- key, so a different or half-typed suffix ("서울대학", "Korea Univ") still finds them. Verified
-- schools first, then exact before prefix before the rest; at most 20.
-- ponytail: scans every school and normalizes on the fly. Fine for thousands of rows; store the
-- keys and add a trigram index if the catalogue grows past that.
create function public.school_search(q text, country_code text default null) returns jsonb
language sql stable security definer set search_path = '' as $$
  with k as (select public.school_fold(q) as fold, public.school_key(q) as key),
  hits as (
    select s.id, s.verified, s.name, min(c.rank) as rank
    from k
    join public.schools s on country_code is null or s.country = country_code
    cross join lateral (
      select case when n.fold = k.fold or n.key = k.key then 0
                  when starts_with(n.fold, k.fold) or starts_with(n.key, k.key) then 1 else 2 end as rank
        from (select public.school_fold(v) as fold, public.school_key(v) as key
              from unnest(array[s.name, s.name_en]) v where v is not null) n
        where strpos(n.fold, k.fold) > 0 or strpos(n.key, k.key) > 0
      union all
      select case when a.fold = k.fold then 0 when starts_with(a.fold, k.fold) then 1 else 2 end
        from (select public.school_fold(v) as fold from unnest(s.aliases) v) a
        where strpos(a.fold, k.fold) > 0
    ) c
    where k.key <> ''
    group by s.id, s.verified, s.name
    order by s.verified desc, rank, s.name, s.id
    limit 20
  )
  select coalesce(jsonb_agg(public.school_json(h.id) order by h.verified desc, h.rank, h.name, h.id), '[]'::jsonb) from hits h
$$;

-- First step of a setup request. Returns one of
--   {status: cached, school}   the school is known: by name, by an unambiguous English name or
--                              alias ("KU" is two schools, so it is not a hit), or because an
--                              earlier run for the same normalized (query, country) produced it
--   {status: invalid}          nothing left of the query once normalized
--   {status: limited, limit}   the account's 3 runs of this UTC day are used up
--   {status: unavailable}      all accounts together have used the day's 500 runs: Bandal pays
--                              for every run and accounts are cheap to make, so this is the backstop
--   {status: run, run}         a run row was opened; school_setup_finish must close it
-- Every run counts except one that ended as 'unavailable'. A run that never finishes keeps
-- counting: it stopped somewhere after the AI may have been paid for.
create function public.school_setup_begin(actor uuid, q text, country_code text) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare daily_limit constant integer := 3; everyone_daily_limit constant integer := 500;
  today constant timestamptz := date_trunc('day', now() at time zone 'utc') at time zone 'utc';
  key text := public.school_key(q); fold text := public.school_fold(q);
  hit text; ids text[]; run uuid;
begin
  if actor is null then raise exception 'sign_in_required' using errcode = '42501'; end if;
  if key is null or key = '' or length(q) > 80 or country_code is null or country_code !~ '^[A-Z]{2}$' then
    return jsonb_build_object('status', 'invalid');
  end if;
  select s.id into hit from public.schools s where s.country = country_code and public.school_key(s.name) = key;
  if hit is null then
    select array_agg(s.id) into ids from public.schools s
      where s.country = country_code and (public.school_key(s.name_en) = key
        or exists (select 1 from unnest(s.aliases) a where public.school_fold(a) = fold));
    if cardinality(ids) = 1 then hit := ids[1]; end if;
  end if;
  if hit is null then
    select r.school_id into hit from public.school_setup_runs r
      where r.school_id is not null and r.country = country_code and public.school_key(r.query) = key
      order by r.created_at desc limit 1;
  end if;
  if hit is not null then return jsonb_build_object('status', 'cached', 'school', public.school_json(hit)); end if;

  perform pg_advisory_xact_lock(hashtextextended('school:' || actor::text, 0));
  if (select count(*) from public.school_setup_runs r
        where r.user_id = actor and r.status <> 'unavailable' and r.created_at >= today) >= daily_limit then
    return jsonb_build_object('status', 'limited', 'limit', daily_limit);
  end if;
  if (select count(*) from public.school_setup_runs r where r.status <> 'unavailable' and r.created_at >= today) >= everyone_daily_limit then
    return jsonb_build_object('status', 'unavailable');
  end if;
  insert into public.school_setup_runs(user_id, query, country) values (actor, q, country_code) returning id into run;
  return jsonb_build_object('status', 'run', 'run', run);
end $$;

-- Closes a run with its outcome and what it cost. For a found school `result` is
-- {name, named, nameEn, domain, links: [{kind, title, url}]}, links that answered the Edge
-- Function's URL check.
--   - A school of the name the model gave already exists (someone was faster, or it is a bundled
--     school under its full name): that one stands untouched and is returned.
--   - Otherwise a new school is stored, unverified with source 'ai' and unverified links. It gets
--     the model's name only when the function found that the typed name abbreviates it (`named`),
--     else the typed name: a query that talks the model into naming another school must not be
--     able to take that school's name, since the next student would be handed this row.
create function public.school_setup_finish(actor uuid, run uuid, outcome text, cost bigint, result jsonb default null) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare has_school constant boolean := coalesce(jsonb_typeof(result->'links') = 'array', false);
  r public.school_setup_runs; school_name text; sid text;
begin
  if outcome is null or outcome not in ('found','not_found','failed','unavailable') or cost is null or cost < 0
     or (outcome = 'found') <> has_school then
    raise exception 'invalid_request' using errcode = '22023';
  end if;
  select * into r from public.school_setup_runs x where x.id = run and x.user_id = actor and x.status = 'running' for update;
  if not found then raise exception 'invalid_request' using errcode = '22023'; end if;
  if has_school then
    select s.id into sid from public.schools s
      where s.country = r.country and public.school_key(s.name) = public.school_key(result->>'name');
  end if;
  if has_school and sid is null then
    school_name := case when (result->>'named')::boolean and public.school_key(result->>'name') <> '' then result->>'name' else r.query end;
    insert into public.schools(name, name_en, country, domain, source, created_by)
      values (school_name, result->>'nameEn', r.country, result->>'domain', 'ai', actor)
      on conflict (public.school_key(name), country) do nothing
      returning id into sid;
    if sid is null then
      -- Lost a race for the name: the row that won stands.
      select s.id into strict sid from public.schools s
        where s.country = r.country and public.school_key(s.name) = public.school_key(school_name);
    else
      insert into public.school_links(school_id, kind, title, url, "order")
        select sid, l->>'kind', l->>'title', l->>'url', (n - 1)::integer
        from jsonb_array_elements(result->'links') with ordinality as t(l, n);
    end if;
  end if;
  update public.school_setup_runs set status = outcome, cost_ucents = cost, school_id = sid where id = run;
  return public.school_json(sid);
end $$;

-- Records a student's version of a school's links for review. The school itself never changes.
-- Returns {status: recorded | not_found | limited, limit}; 20 a day per account.
create function public.school_suggest(actor uuid, school text, suggestion jsonb) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare daily_limit constant integer := 20;
begin
  if actor is null then raise exception 'sign_in_required' using errcode = '42501'; end if;
  if jsonb_typeof(suggestion) is distinct from 'array' or jsonb_array_length(suggestion) not between 1 and 20 then
    raise exception 'invalid_request' using errcode = '22023';
  end if;
  if not exists (select 1 from public.schools s where s.id = school) then return jsonb_build_object('status', 'not_found'); end if;
  perform pg_advisory_xact_lock(hashtextextended('school:' || actor::text, 0));
  if (select count(*) from public.school_link_suggestions g
        where g.user_id = actor and g.created_at >= date_trunc('day', now() at time zone 'utc') at time zone 'utc') >= daily_limit then
    return jsonb_build_object('status', 'limited', 'limit', daily_limit);
  end if;
  insert into public.school_link_suggestions(school_id, user_id, links) values (school, actor, suggestion);
  return jsonb_build_object('status', 'recorded');
end $$;

do $$ declare f text; begin
  foreach f in array array['school_fold(text)','school_key(text)','school_json(text)','school_search(text,text)',
    'school_setup_begin(uuid,text,text)','school_setup_finish(uuid,uuid,text,bigint,jsonb)','school_suggest(uuid,text,jsonb)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;

-- The schools bundled with the app (App/Resources/DesktopNative/universities.json), services in
-- their order with homepage → home.
-- seed:begin  generated by backend/scripts/seed-schools.ts; do not edit by hand
insert into public.schools(id, name, name_en, aliases, country, domain, verified, source) values
  ('snu', '서울대학교', 'Seoul National University', array['서울대', 'SNU', 'Seoul National', '관악']::text[], 'KR', 'snu.ac.kr', true, 'bundled'),
  ('yonsei', '연세대학교', 'Yonsei University', array['연세대', 'Yonsei', '신촌']::text[], 'KR', 'yonsei.ac.kr', true, 'bundled'),
  ('korea', '고려대학교', 'Korea University', array['고려대', 'Korea University', 'KU', '안암']::text[], 'KR', 'korea.ac.kr', true, 'bundled'),
  ('skku', '성균관대학교', 'Sungkyunkwan University', array['성균관대', 'SKKU', 'Sungkyunkwan', '성대']::text[], 'KR', 'skku.edu', true, 'bundled'),
  ('hanyang', '한양대학교', 'Hanyang University', array['한양대', 'Hanyang', 'HYU', 'ERICA', '에리카']::text[], 'KR', 'hanyang.ac.kr', true, 'bundled'),
  ('cau', '중앙대학교', 'Chung-Ang University', array['중앙대', 'CAU', 'Chung-Ang', '흑석']::text[], 'KR', 'cau.ac.kr', true, 'bundled'),
  ('khu', '경희대학교', 'Kyung Hee University', array['경희대', 'KHU', 'Kyung Hee', '회기', '국제캠']::text[], 'KR', 'khu.ac.kr', true, 'bundled'),
  ('sogang', '서강대학교', 'Sogang University', array['서강대', 'Sogang', '노고산']::text[], 'KR', 'sogang.ac.kr', true, 'bundled'),
  ('ewha', '이화여자대학교', 'Ewha Womans University', array['이화여대', '이대', 'Ewha', '이화']::text[], 'KR', 'ewha.ac.kr', true, 'bundled'),
  ('kaist', '한국과학기술원', 'KAIST', array['KAIST', '카이스트', '한국과학기술원', '대전']::text[], 'KR', 'kaist.ac.kr', true, 'bundled'),
  ('postech', '포항공과대학교', 'POSTECH', array['POSTECH', '포스텍', '포항공대', '포공']::text[], 'KR', 'postech.ac.kr', true, 'bundled'),
  ('konkuk', '건국대학교', 'Konkuk University', array['건국대', 'Konkuk', 'KU', '건대']::text[], 'KR', 'konkuk.ac.kr', true, 'bundled'),
  ('dongguk', '동국대학교', 'Dongguk University', array['동국대', 'Dongguk', '충무로']::text[], 'KR', 'dongguk.edu', true, 'bundled'),
  ('pusan', '부산대학교', 'Pusan National University', array['부산대', 'PNU', 'Pusan', '부산국립대']::text[], 'KR', 'pusan.ac.kr', true, 'bundled'),
  ('knu', '경북대학교', 'Kyungpook National University', array['경북대', 'KNU', 'Kyungpook', '대구']::text[], 'KR', 'knu.ac.kr', true, 'bundled'),
  ('inha', '인하대학교', 'Inha University', array['인하대', 'Inha', '인천']::text[], 'KR', 'inha.ac.kr', true, 'bundled'),
  ('ajou', '아주대학교', 'Ajou University', array['아주대', 'Ajou', '수원']::text[], 'KR', 'ajou.ac.kr', true, 'bundled'),
  ('sejong', '세종대학교', 'Sejong University', array['세종대', 'Sejong', '군자']::text[], 'KR', 'sejong.ac.kr', true, 'bundled');
insert into public.school_links(id, school_id, kind, title, url, verified, "order") values
  ('snu.portal', 'snu', 'portal', '마이스누', 'https://my.snu.ac.kr/', true, 0),
  ('snu.myetl', 'snu', 'lms', '내 강의실', 'https://myetl.snu.ac.kr/login', true, 1),
  ('snu.etl', 'snu', 'lms', 'eTL 강좌', 'https://etl.snu.ac.kr/', true, 2),
  ('snu.oldetl', 'snu', 'lms', '구 eTL', 'https://oldetl.snu.ac.kr/', true, 3),
  ('snu.registration', 'snu', 'registration', '수강신청', 'https://sugang.snu.ac.kr/', true, 4),
  ('snu.library', 'snu', 'library', '중앙도서관', 'https://lib.snu.ac.kr/', true, 5),
  ('snu.library.search', 'snu', 'library', '자료검색', 'https://lib.snu.ac.kr/find/', true, 6),
  ('snu.library.proxy', 'snu', 'other', '학외 접속', 'https://lib.snu.ac.kr/using/proxy/', true, 7),
  ('snu.mail', 'snu', 'mail', '학생 메일', 'https://mail.google.com/', true, 8),
  ('snu.mail.staff', 'snu', 'mail', '교직원 메일', 'https://snu.gov-dooray.com/', true, 9),
  ('snu.homepage', 'snu', 'home', '학교 홈페이지', 'https://www.snu.ac.kr/', true, 10),
  ('snu.calendar', 'snu', 'other', '학사일정', 'https://www.snu.ac.kr/academics/resources/calendar', true, 11),
  ('snu.snugenie', 'snu', 'other', '스누지니', 'https://snugenie.snu.ac.kr/', true, 12),
  ('snu.extra', 'snu', 'other', '비교과', 'https://extra.snu.ac.kr/main.html', true, 13),
  ('snu.food', 'snu', 'other', '생협 식단', 'https://snuco.snu.ac.kr/foodmenu/', true, 14),
  ('snu.map', 'snu', 'other', '캠퍼스 지도', 'https://map.snu.ac.kr/web/main.action', true, 15),
  ('yonsei.portal', 'yonsei', 'portal', '연세포탈', 'https://portal.yonsei.ac.kr/portal/MainCtr/index.do', true, 0),
  ('yonsei.lms', 'yonsei', 'lms', 'LearnUs', 'https://ys.learnus.org/', true, 1),
  ('yonsei.library', 'yonsei', 'library', '학술정보원', 'https://library.yonsei.ac.kr/', true, 2),
  ('yonsei.mail', 'yonsei', 'mail', '웹메일', 'https://mail.yonsei.ac.kr/', true, 3),
  ('yonsei.homepage', 'yonsei', 'home', '학교 홈페이지', 'https://www.yonsei.ac.kr/sc/index.do', true, 4),
  ('korea.portal', 'korea', 'portal', 'KUPID', 'https://portal.korea.ac.kr/', true, 0),
  ('korea.ams', 'korea', 'portal', '학사정보', 'https://ams.korea.ac.kr/', false, 1),
  ('korea.lms', 'korea', 'lms', 'LMS', 'https://lms.korea.ac.kr/', true, 2),
  ('korea.canvas', 'korea', 'lms', '강의실', 'https://canvas.korea.ac.kr/', true, 3),
  ('korea.registration', 'korea', 'registration', '수강신청', 'https://sugang.korea.ac.kr/', true, 4),
  ('korea.library', 'korea', 'library', '도서관', 'https://library.korea.ac.kr/', true, 5),
  ('korea.mail', 'korea', 'mail', '웹메일', 'https://mail.korea.ac.kr/', true, 6),
  ('korea.homepage', 'korea', 'home', '학교 홈페이지', 'https://www.korea.ac.kr/sites/ko/index.do', true, 7),
  ('korea.cert', 'korea', 'other', '증명발급', 'https://kucert.korea.ac.kr/', false, 8),
  ('skku.portal', 'skku', 'portal', '킹고포털', 'https://portal.skku.edu/', false, 0),
  ('skku.lms', 'skku', 'lms', '아이캠퍼스', 'https://icampus.skku.edu/', true, 1),
  ('skku.canvas', 'skku', 'lms', '강의실', 'https://canvas.skku.edu/login', false, 2),
  ('skku.registration', 'skku', 'registration', '수강신청', 'https://sugang.skku.edu/skku/', true, 3),
  ('skku.library', 'skku', 'library', '도서관', 'https://lib.skku.edu/', true, 4),
  ('skku.mail', 'skku', 'mail', '웹메일', 'https://mail.google.com/', true, 5),
  ('skku.homepage', 'skku', 'home', '학교 홈페이지', 'https://www.skku.edu/skku/index.do', true, 6),
  ('hanyang.portal', 'hanyang', 'portal', 'HY-in', 'https://portal.hanyang.ac.kr/sso/lgin.do', true, 0),
  ('hanyang.canvas', 'hanyang', 'lms', '강의실', 'https://learning.hanyang.ac.kr/', true, 1),
  ('hanyang.lms', 'hanyang', 'lms', 'LMS', 'https://lms.hanyang.ac.kr/', true, 2),
  ('hanyang.registration', 'hanyang', 'registration', '수강신청', 'https://portal.hanyang.ac.kr/sugang/sulg.do', true, 3),
  ('hanyang.library.seoul', 'hanyang', 'library', '도서관(서울)', 'https://lib.hanyang.ac.kr/', true, 4),
  ('hanyang.library.erica', 'hanyang', 'library', '도서관(ERICA)', 'https://information.hanyang.ac.kr/', true, 5),
  ('hanyang.mail', 'hanyang', 'mail', '웹메일', 'https://mail.google.com/', true, 6),
  ('hanyang.homepage', 'hanyang', 'home', '학교 홈페이지', 'https://www.hanyang.ac.kr/home', true, 7),
  ('hanyang.homepage.erica', 'hanyang', 'home', '홈페이지(ERICA)', 'https://www.hanyang.ac.kr/erica', true, 8),
  ('cau.portal', 'cau', 'portal', '중앙대 포탈', 'https://mportal.cau.ac.kr/', true, 0),
  ('cau.lms', 'cau', 'lms', 'e-Class', 'https://eclass3.cau.ac.kr/', true, 1),
  ('cau.canvas', 'cau', 'lms', 'CAU-ON', 'https://canvas.cau.ac.kr/', true, 2),
  ('cau.registration', 'cau', 'registration', '수강신청', 'https://sugang.cau.ac.kr/', true, 3),
  ('cau.library.seoul', 'cau', 'library', '도서관(서울)', 'https://library.cau.ac.kr/', true, 4),
  ('cau.library.davinci', 'cau', 'library', '도서관(다빈치)', 'https://alibrary.cau.ac.kr/', true, 5),
  ('cau.mail', 'cau', 'mail', '웹메일', 'https://mail.cau.ac.kr/', true, 6),
  ('cau.homepage', 'cau', 'home', '학교 홈페이지', 'https://www.cau.ac.kr/', true, 7),
  ('khu.portal', 'khu', 'portal', '포털', 'https://portal.khu.ac.kr/', true, 0),
  ('khu.info21', 'khu', 'portal', '인포21', 'https://info21.khu.ac.kr/', false, 1),
  ('khu.lms', 'khu', 'lms', 'e-Campus', 'https://e-campus.khu.ac.kr/', true, 2),
  ('khu.canvas', 'khu', 'lms', '강의실', 'https://khcanvas.khu.ac.kr/', true, 3),
  ('khu.registration', 'khu', 'registration', '수강신청', 'https://sugang.khu.ac.kr/', true, 4),
  ('khu.library', 'khu', 'library', '중앙도서관', 'https://lib.khu.ac.kr/', true, 5),
  ('khu.mail', 'khu', 'mail', '웹메일', 'https://mail.khu.ac.kr/', true, 6),
  ('khu.homepage', 'khu', 'home', '학교 홈페이지', 'https://www.khu.ac.kr/', true, 7),
  ('sogang.portal', 'sogang', 'portal', 'SAINT', 'https://saint.sogang.ac.kr/irj/portal', false, 0),
  ('sogang.lms', 'sogang', 'lms', '사이버캠퍼스', 'https://cyber.sogang.ac.kr/ilos/main/main_form.acl', true, 1),
  ('sogang.registration', 'sogang', 'registration', '수강신청', 'https://sis109.sogang.ac.kr/zu4a/zcmuik101', true, 2),
  ('sogang.library', 'sogang', 'library', '로욜라도서관', 'https://library.sogang.ac.kr/', true, 3),
  ('sogang.mail', 'sogang', 'mail', '웹메일', 'https://mail.sogang.ac.kr/', false, 4),
  ('sogang.homepage', 'sogang', 'home', '학교 홈페이지', 'https://www.sogang.ac.kr/', true, 5),
  ('ewha.eureka', 'ewha', 'portal', '유레카', 'https://eureka.ewha.ac.kr/', false, 0),
  ('ewha.portal', 'ewha', 'portal', '이화포탈', 'https://portal.ewha.ac.kr/', false, 1),
  ('ewha.lms', 'ewha', 'lms', '사이버캠퍼스', 'https://cyber.ewha.ac.kr/', true, 2),
  ('ewha.registration', 'ewha', 'registration', '수강신청', 'https://sugang.ewha.ac.kr/', true, 3),
  ('ewha.library', 'ewha', 'library', '중앙도서관', 'https://lib.ewha.ac.kr/', false, 4),
  ('ewha.mail', 'ewha', 'mail', '웹메일', 'https://mail.google.com/', true, 5),
  ('ewha.homepage', 'ewha', 'home', '학교 홈페이지', 'https://www.ewha.ac.kr/', true, 6),
  ('kaist.portal', 'kaist', 'portal', 'KAIST 포털', 'https://portal.kaist.ac.kr/', true, 0),
  ('kaist.lms', 'kaist', 'lms', 'KLMS', 'https://klms.kaist.ac.kr/', true, 1),
  ('kaist.registration', 'kaist', 'registration', '수강신청', 'https://sugang.kaist.ac.kr/', true, 2),
  ('kaist.library', 'kaist', 'library', '도서관', 'https://library.kaist.ac.kr/', true, 3),
  ('kaist.mail', 'kaist', 'mail', '메일', 'https://mail.kaist.ac.kr/', true, 4),
  ('kaist.homepage', 'kaist', 'home', '학교 홈페이지', 'https://www.kaist.ac.kr/kr/', true, 5),
  ('postech.povis', 'postech', 'portal', 'POVIS', 'https://povis.postech.ac.kr/', true, 0),
  ('postech.podium', 'postech', 'portal', 'PODIUM', 'https://podium.postech.ac.kr/', false, 1),
  ('postech.lms', 'postech', 'lms', 'PLMS', 'https://plms.postech.ac.kr/', true, 2),
  ('postech.library', 'postech', 'library', '학술정보관', 'https://library.postech.ac.kr/', true, 3),
  ('postech.mail', 'postech', 'mail', '웹메일', 'https://mail.postech.ac.kr/', true, 4),
  ('postech.homepage', 'postech', 'home', '학교 홈페이지', 'https://www.postech.ac.kr/kor/index.do', true, 5),
  ('postech.cert', 'postech', 'other', '증명발급', 'http://cert.postech.ac.kr/', false, 6),
  ('konkuk.portal', 'konkuk', 'portal', '위인전', 'https://wein.konkuk.ac.kr/', true, 0),
  ('konkuk.kuis', 'konkuk', 'portal', '학사정보', 'https://kuis.konkuk.ac.kr/', true, 1),
  ('konkuk.lms', 'konkuk', 'lms', 'eCampus', 'https://ecampus.konkuk.ac.kr/ilos/index.acl', true, 2),
  ('konkuk.registration', 'konkuk', 'registration', '수강신청', 'https://sugang.konkuk.ac.kr/sugang/index.jsp', true, 3),
  ('konkuk.library', 'konkuk', 'library', '상허기념도서관', 'https://library.konkuk.ac.kr/', true, 4),
  ('konkuk.mail', 'konkuk', 'mail', '웹메일', 'https://kumail.konkuk.ac.kr/', true, 5),
  ('konkuk.homepage', 'konkuk', 'home', '학교 홈페이지', 'https://www.konkuk.ac.kr/konkuk/index.do', true, 6),
  ('dongguk.portal', 'dongguk', 'portal', 'uDRIMS', 'https://nportal.dongguk.edu/comm/login/user/login.do', true, 0),
  ('dongguk.lms', 'dongguk', 'lms', '이클래스', 'https://eclass.dongguk.edu/', true, 1),
  ('dongguk.registration', 'dongguk', 'registration', '수강신청', 'https://sugang.dongguk.edu/', true, 2),
  ('dongguk.library', 'dongguk', 'library', '중앙도서관', 'https://lib.dongguk.edu/', true, 3),
  ('dongguk.mail', 'dongguk', 'mail', 'CloudMail', 'https://mail.dongguk.edu/', true, 4),
  ('dongguk.homepage', 'dongguk', 'home', '학교 홈페이지', 'https://www.dongguk.edu/main', true, 5),
  ('pusan.portal', 'pusan', 'portal', '학생지원시스템', 'https://onestop.pusan.ac.kr/', true, 0),
  ('pusan.one', 'pusan', 'portal', '교육정보시스템', 'https://one.pusan.ac.kr/', true, 1),
  ('pusan.lms', 'pusan', 'lms', 'PLATO', 'https://plato.pusan.ac.kr/', true, 2),
  ('pusan.registration', 'pusan', 'registration', '수강신청', 'https://sugang.pusan.ac.kr/', true, 3),
  ('pusan.library', 'pusan', 'library', '도서관', 'https://lib.pusan.ac.kr/', true, 4),
  ('pusan.mail', 'pusan', 'mail', '웹메일', 'https://mail.pusan.ac.kr/mail', true, 5),
  ('pusan.homepage', 'pusan', 'home', '학교 홈페이지', 'https://www.pusan.ac.kr/kor/', true, 6),
  ('knu.portal', 'knu', 'portal', '통합포털', 'https://on.knu.ac.kr/', true, 0),
  ('knu.knuin', 'knu', 'portal', '학사정보', 'https://knuin.knu.ac.kr/knuin/index.knu', false, 1),
  ('knu.lms', 'knu', 'lms', 'LMS', 'https://lms.knu.ac.kr/', true, 2),
  ('knu.canvas', 'knu', 'lms', '강의실', 'https://canvas.knu.ac.kr/', true, 3),
  ('knu.registration', 'knu', 'registration', '수강신청', 'https://sugang.knu.ac.kr/', false, 4),
  ('knu.library', 'knu', 'library', '도서관', 'https://kudos.knu.ac.kr/', true, 5),
  ('knu.mail', 'knu', 'mail', '웹메일', 'https://mail.knu.ac.kr/mail', true, 6),
  ('knu.homepage', 'knu', 'home', '학교 홈페이지', 'https://www.knu.ac.kr/wbbs/wbbs/main/main.action', true, 7),
  ('inha.portal', 'inha', 'portal', '인하포털', 'https://portal.inha.ac.kr/', true, 0),
  ('inha.lms', 'inha', 'lms', 'I-Class', 'https://learn.inha.ac.kr/', true, 1),
  ('inha.registration', 'inha', 'registration', '수강신청', 'https://sugang.inha.ac.kr/', true, 2),
  ('inha.library', 'inha', 'library', '정석학술정보관', 'https://lib.inha.ac.kr/', true, 3),
  ('inha.mail', 'inha', 'mail', '메일', 'https://cloud.inha.ac.kr/t/inha.ac.kr', true, 4),
  ('inha.homepage', 'inha', 'home', '학교 홈페이지', 'https://www.inha.ac.kr/kr/index.do', true, 5),
  ('inha.cert', 'inha', 'other', '증명발급', 'https://cert.inha.ac.kr/', true, 6),
  ('ajou.portal', 'ajou', 'portal', '아주대 포탈', 'https://portal.ajou.ac.kr/main.do', true, 0),
  ('ajou.haksa', 'ajou', 'portal', '학사서비스', 'https://mhaksa.ajou.ac.kr:30443/', false, 1),
  ('ajou.lms', 'ajou', 'lms', 'eClass', 'https://eclass2.ajou.ac.kr/', false, 2),
  ('ajou.library', 'ajou', 'library', '도서관', 'https://library.ajou.ac.kr/', true, 3),
  ('ajou.mail', 'ajou', 'mail', '메일', 'https://mail.google.com/a/ajou.ac.kr', true, 4),
  ('ajou.homepage', 'ajou', 'home', '학교 홈페이지', 'https://www.ajou.ac.kr/kr/index.do', true, 5),
  ('ajou.aims', 'ajou', 'other', 'AIMS2', 'https://aims.ajou.ac.kr/', false, 6),
  ('sejong.portal', 'sejong', 'portal', '세종대 포털', 'https://portal.sejong.ac.kr/jsp/login/loginSSL.jsp', true, 0),
  ('sejong.sjpt', 'sejong', 'portal', '학사정보', 'https://sjpt.sejong.ac.kr/', true, 1),
  ('sejong.lms', 'sejong', 'lms', '집현캠퍼스', 'https://ecampus.sejong.ac.kr/', true, 2),
  ('sejong.library', 'sejong', 'library', '학술정보원', 'https://library.sejong.ac.kr/', true, 3),
  ('sejong.mail', 'sejong', 'mail', '학생 메일', 'https://outlook.office.com/mail/', false, 4),
  ('sejong.mail.staff', 'sejong', 'mail', '교직원 메일', 'https://mail.sejong.ac.kr/', true, 5),
  ('sejong.homepage', 'sejong', 'home', '학교 홈페이지', 'https://www.sejong.ac.kr/kor/index.do', true, 6);
-- seed:end

commit;
