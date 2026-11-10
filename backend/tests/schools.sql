-- Schools: normalization, seed, uniqueness, search order, cached lookups, the daily run limits,
-- closing a run, suggestions. Runs as service_role.
\set a '''aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'''
\set b '''bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'''
\set c '''cccccccc-cccc-4ccc-8ccc-cccccccccccc'''
set role authenticated;
do $$ begin
  perform public.school_search('서울');
  raise exception 'authenticated unexpectedly called school_search';
exception when insufficient_privilege then null; end $$;
do $$ begin
  perform * from public.schools;
  raise exception 'authenticated unexpectedly read schools';
exception when insufficient_privilege then null; end $$;
reset role;
set role anon;
do $$ begin
  perform * from public.school_setup_runs;
  raise exception 'anon unexpectedly read school_setup_runs';
exception when insufficient_privilege then null; end $$;
do $$ begin
  perform public.school_setup_begin('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', '서울대학교', 'KR');
  raise exception 'anon unexpectedly called school_setup_begin';
exception when insufficient_privilege then null; end $$;
reset role;

set role service_role;
-- Normalization.
select public.assert_true(public.school_key('서울 대학교') = '서울' and public.school_key('서울대학') = '서울', 'whitespace and Korean suffixes');
select public.assert_true(public.school_key(' Seoul  National University ') = 'seoulnational' and public.school_key('Korea Univ') = 'korea', 'case and English suffixes');
select public.assert_true(public.school_key('University of Seoul') = 'universityofseoul', 'only a trailing suffix goes');
select public.assert_true(public.school_key('대학교') = '' and public.school_fold('경인 교대') = '경인교대', 'empty key; fold keeps the whole name');

-- Seed: the bundled list, verified, services in order with homepage → home.
select public.assert_true((select count(*) = 18 and bool_and(verified and source = 'bundled' and country = 'KR') from public.schools), '18 bundled schools');
select public.assert_true((select count(*) = 137 from public.school_links), '137 bundled links');
select public.assert_true((select count(*) = 19 from public.school_links where kind = 'home'), 'homepage became home');
select public.assert_true((select count(*) = 18 from public.school_links where not verified), 'partial and unverified links are not verified');
select public.assert_true((select array_agg(id order by "order") = array['yonsei.portal','yonsei.lms','yonsei.library','yonsei.mail','yonsei.homepage']
  from public.school_links where school_id = 'yonsei'), 'service order kept');

-- The School object.
select public.assert_true((select array_agg(k order by k) from jsonb_object_keys(public.school_json('snu')) k)
  = array['aliases','country','domain','id','links','name','nameEn','source','verified'], 'School keys');
select public.assert_true((select array_agg(k order by k) from jsonb_object_keys(public.school_json('snu')->'links'->0) k)
  = array['id','kind','order','title','url','verified'], 'link keys');
select public.assert_true(public.school_json('snu')->'links'->0->>'id' = 'snu.portal' and jsonb_array_length(public.school_json('snu')->'links') = 16, 'links in order');
select public.assert_true(public.school_json('snu')->'aliases' = '["서울대","SNU","Seoul National","관악"]'::jsonb, 'aliases from the bundled list');
select public.assert_true(public.school_json('nope') is null, 'unknown school');

-- One school per normalized name and country.
do $$ begin
  insert into public.schools(name, country, source) values ('서울 대학', 'KR', 'user');
  raise exception 'duplicate normalized name accepted';
exception when unique_violation then null; end $$;
insert into public.schools(id, name, country, source) values ('snu-jp', '서울대학교', 'JP', 'user');
do $$ begin
  insert into public.schools(name, country, source) values ('University', 'US', 'user');
  raise exception 'name without a key accepted';
exception when check_violation then null; end $$;

insert into public.schools(id, name, name_en, aliases, country, source) values
  ('ginue', '경인교육대학교', 'Gyeongin National University of Education', array['경인교대'], 'KR', 'ai'),
  ('seoultech', '서울과학기술대학교', 'Seoul National University of Science and Technology', '{}', 'KR', 'ai');

-- Search: verified first, then exact before prefix before the rest.
select public.assert_true(public.school_search('서울 대학교', 'KR')->0->>'id' = 'snu', 'spaced suffix finds 서울대학교');
select public.assert_true((select array_agg(e->>'id') from jsonb_array_elements(public.school_search('서울', 'KR')) e) = array['snu','seoultech'], 'verified before unverified');
select public.assert_true((select array_agg(e->>'id') from jsonb_array_elements(public.school_search('서울')) e) = array['snu','snu-jp','seoultech'], 'no country: exact before prefix among the unverified');
select public.assert_true(public.school_search('경인교대', 'KR')->0->>'id' = 'ginue', 'alias');
select public.assert_true(public.school_search('snu')->0->>'id' = 'snu', 'alias, any case');
select public.assert_true(public.school_search('Korea Univ', 'KR')->0->>'id' = 'korea', 'another suffix, by key');
select public.assert_true(public.school_search('서울과학기술대', 'KR')->0->>'id' = 'seoultech', 'half-typed suffix');
select public.assert_true(public.school_search('대구', 'KR')->0->>'id' = 'knu', 'a place alias matches as typed');
select public.assert_true(public.school_search('대구대학교', 'KR') = '[]'::jsonb, 'but is not the name of another school');
select public.assert_true(public.school_search('', 'KR') = '[]'::jsonb and public.school_search('  대학교 ') = '[]'::jsonb and public.school_search(null) = '[]'::jsonb, 'nothing to search for');
select public.assert_true(public.school_search('서울', 'US') = '[]'::jsonb, 'country filter');
select public.assert_true(public.school_search('100%_', 'KR') = '[]'::jsonb, 'no pattern characters');
insert into public.schools(name, country, source) select '서울테스트' || n || '대학교', 'KR', 'ai' from generate_series(1, 25) n;
select public.assert_true(jsonb_array_length(public.school_search('서울', 'KR')) = 20, 'at most 20');
select public.assert_true(public.school_search('서울', 'KR')->0->>'id' = 'snu', 'verified stays first');
delete from public.schools where name like '서울테스트%';

-- Setup, step one: a known school is returned without a run.
select public.assert_true(public.school_setup_begin(:a, '서울 대학교', 'KR')->'school'->>'id' = 'snu', 'name');
select public.assert_true(public.school_setup_begin(:a, '경인교대', 'KR')->'school'->>'id' = 'ginue', 'alias');
select public.assert_true(public.school_setup_begin(:a, 'Yonsei University', 'KR')->'school'->>'id' = 'yonsei', 'English name');
select public.assert_true(public.school_setup_begin(:a, '대학교', 'KR')->>'status' = 'invalid' and public.school_setup_begin(:a, '서울대학교', 'kr')->>'status' = 'invalid', 'empty key, bad country');
select public.assert_true((select count(*) = 0 from public.school_setup_runs), 'none of these opened a run');

-- Three runs per account per UTC day.
select public.school_setup_begin(:a, 'KU', 'KR')->>'run' as run1 \gset
select public.school_setup_begin(:a, '대구대학교', 'KR')->>'run' as run2 \gset
select public.school_setup_begin(:a, '한국대학교', 'KR')->>'run' as run3 \gset
select public.assert_true((select count(*) = 3 and bool_and(status = 'running') from public.school_setup_runs where user_id = :a),
  'an alias of two schools and a place alias are not hits');
select public.assert_true(public.school_setup_begin(:a, '세계대학교', 'KR') = '{"status":"limited","limit":3}'::jsonb, 'fourth run refused');
select public.assert_true(public.school_setup_begin(:a, '서울대학교', 'KR')->>'status' = 'cached', 'a cached school still answers');
select public.school_setup_begin(:b, '세계대학교', 'KR')->>'run' as run4 \gset

-- Closing a run. Found under a name the typed one abbreviates: an unverified 'ai' school with
-- that name, unverified links in order, the cost logged.
select public.school_setup_finish(:a, :'run2', 'found', 2155000, '{"name":"대구대학교","named":true,"nameEn":"Daegu University","domain":"daegu.ac.kr","links":[
  {"kind":"home","title":"홈페이지","url":"https://www.daegu.ac.kr/"},{"kind":"lms","title":"LMS","url":"https://lms.daegu.ac.kr/"}]}') as found \gset
select public.assert_true((:'found'::jsonb)->>'name' = '대구대학교' and (:'found'::jsonb)->>'source' = 'ai' and not ((:'found'::jsonb)->>'verified')::boolean
  and (:'found'::jsonb)->>'nameEn' = 'Daegu University' and (:'found'::jsonb)->>'domain' = 'daegu.ac.kr' and (:'found'::jsonb)->>'country' = 'KR', 'found school is unverified ai');
select public.assert_true((:'found'::jsonb)->'links'->1->>'kind' = 'lms' and ((:'found'::jsonb)->'links'->1->>'order')::integer = 1
  and not ((:'found'::jsonb)->'links'->1->>'verified')::boolean, 'links in order, unverified like the school');
select public.assert_true((select status = 'found' and cost_ucents = 2155000 and school_id = (:'found'::jsonb)->>'id' from public.school_setup_runs where id = :'run2'), 'run closed with its cost');
select public.assert_true((select created_by = :a from public.schools where name = '대구대학교'), 'created_by');
select public.assert_true(public.school_setup_begin(:b, '대구 대학교', 'KR')->'school'->>'name' = '대구대학교', 'the next account gets it cached');
-- The model names a school that exists: that school stands, nothing is added to it, whatever was typed.
select public.assert_true(public.school_setup_finish(:a, :'run1', 'found', 100, '{"name":"고려대학교","named":false,"nameEn":null,"domain":"evil.example","links":[
  {"kind":"home","title":"x","url":"https://evil.example/"}]}')->>'id' = 'korea', 'existing school returned');
select public.assert_true((select count(*) = 9 from public.school_links where school_id = 'korea') and (select domain = 'korea.ac.kr' from public.schools where id = 'korea'), 'and left untouched');
select public.assert_true(public.school_setup_begin(:b, ' ku ', 'KR')->'school'->>'id' = 'korea', 'the same query is now answered by that run');
-- The model names a school we do not have, but the typed name does not abbreviate it (`named`
-- false): the new school is stored as typed, so the name the model gave stays free.
select public.school_setup_finish(:b, :'run4', 'found', 5, '{"name":"한국외국어대학교","named":false,"nameEn":null,"domain":"evil.example","links":[
  {"kind":"home","title":"x","url":"https://evil.example/"}]}') as typed \gset
select public.assert_true((:'typed'::jsonb)->>'name' = '세계대학교' and (:'typed'::jsonb)->>'domain' = 'evil.example', 'stored under the typed name');
select public.assert_true(public.school_search('한국외국어대학교', 'KR') = '[]'::jsonb, 'the model''s name was not taken');
-- Not found, and what cannot be closed.
select public.assert_true(public.school_setup_finish(:a, :'run3', 'not_found', 1200000) is null, 'not_found returns no school');
select public.assert_true((select status = 'not_found' and cost_ucents = 1200000 and school_id is null from public.school_setup_runs where id = :'run3'), 'not_found logged');
do $$ declare run uuid := (public.school_setup_begin('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', '달나라대학교', 'KR')->>'run')::uuid; begin
  begin
    perform public.school_setup_finish('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', run, 'not_found', 0);
    raise exception 'another account closed the run';
  exception when invalid_parameter_value then null; end;
  begin
    perform public.school_setup_finish('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', run, 'found', 0);
    raise exception 'found without a school accepted';
  exception when invalid_parameter_value then null; end;
  perform public.school_setup_finish('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', run, 'unavailable', 0);
  begin
    perform public.school_setup_finish('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', run, 'not_found', 0);
    raise exception 'run closed twice';
  exception when invalid_parameter_value then null; end;
end $$;
-- A model name without a key also falls back to what was typed.
select public.school_setup_begin(:b, '별나라대학교', 'KR')->>'run' as run5 \gset
select public.assert_true(public.school_setup_finish(:b, :'run5', 'found', 5, '{"name":"대학교","named":true,"links":[]}')->>'name' = '별나라대학교', 'typed name when the model''s has no key');
-- b has used two runs (both found) plus one that was unavailable: one more fits, the next does not.
select public.assert_true(public.school_setup_begin(:b, '해나라대학교', 'KR')->>'status' = 'run', 'unavailable does not count');
select public.assert_true(public.school_setup_begin(:b, '꿈나라대학교', 'KR')->>'status' = 'limited', 'b is at the limit');

-- The day is the UTC day, whatever the session's time zone: one second before UTC midnight is
-- yesterday, midnight itself is today.
set time zone 'Asia/Seoul';
update public.school_setup_runs set created_at = date_trunc('day', now() at time zone 'utc') at time zone 'utc' - interval '1 second' where user_id = :a;
select public.assert_true(public.school_setup_begin(:a, '세계 대학', 'KR')->'school'->>'name' = '세계대학교' and public.school_setup_begin(:a, '꿈나라대학교', 'KR')->>'status' = 'run', 'a new day');
update public.school_setup_runs set created_at = date_trunc('day', now() at time zone 'utc') at time zone 'utc' where id in (:'run1', :'run2');
select public.assert_true(public.school_setup_begin(:a, '물나라대학교', 'KR')->>'status' = 'limited', 'UTC midnight belongs to today');
reset time zone;

-- All accounts together: 500 runs a day, then the AI is unavailable to everyone, cached schools aside.
insert into public.school_setup_runs(user_id, query, country, status) select :b, '채우기' || n, 'KR', 'not_found' from generate_series(1, 500) n;
select public.assert_true(public.school_setup_begin(:c, '불나라대학교', 'KR') = '{"status":"unavailable"}'::jsonb, 'ceiling for everyone');
select public.assert_true(public.school_setup_begin(:c, '서울대학교', 'KR')->>'status' = 'cached', 'cached schools still answer');
delete from public.school_setup_runs where query like '채우기%';
select public.assert_true(public.school_setup_begin(:c, '불나라대학교', 'KR')->>'status' = 'run', 'and below it runs open again');

-- Suggestions are stored and change nothing.
select public.assert_true(public.school_suggest(:a, 'snu', '[{"kind":"portal","title":"포털","url":"https://evil.example/"}]')->>'status' = 'recorded', 'recorded');
select public.assert_true(public.school_suggest(:a, 'nope', '[{"kind":"portal","title":"포털","url":"https://evil.example/"}]')->>'status' = 'not_found', 'unknown school');
select public.assert_true((select count(*) = 1 and bool_and(links->0->>'url' = 'https://evil.example/') from public.school_link_suggestions where school_id = 'snu' and user_id = :a), 'stored once');
select public.assert_true(public.school_json('snu')->'links'->0->>'url' = 'https://my.snu.ac.kr/' and jsonb_array_length(public.school_json('snu')->'links') = 16, 'the school is untouched');
do $$ begin
  perform public.school_suggest('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'snu', '[]');
  raise exception 'empty suggestion accepted';
exception when invalid_parameter_value then null; end $$;
insert into public.school_link_suggestions(school_id, user_id, links) select 'snu', :a, '[]' from generate_series(1, 19);
select public.assert_true(public.school_suggest(:a, 'snu', '[{"kind":"home","title":"홈","url":"https://www.snu.ac.kr/"}]') = '{"status":"limited","limit":20}'::jsonb, '20 a day');
reset role;
select 'PASS: schools normalization, seed, search, cached lookups, run limits, suggestions' as result;
