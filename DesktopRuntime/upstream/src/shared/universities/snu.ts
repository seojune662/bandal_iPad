/**
 * 서울대학교 preset — the reference entry (docs/university-sites.md §1).
 *
 * The one thing to remember: **eTL is Canvas, not Moodle.**
 * `etl.snu.ac.kr` is a Xinics 강좌 카탈로그 + SSO gateway whose
 * `/course/view.php?id=` 404s; the actual 강의실 is `myetl.snu.ac.kr`
 * (Instructure Canvas), and the catalog's 24-hex `catalog_id` is NOT a
 * Canvas course id.
 */

import type { University } from '../types/university'
import { canvasCourseLink } from './specs'

export const VERIFIED_AT = '2026-08-05'

export const SNU: University = {
  id: 'snu',
  nameKo: '서울대학교',
  nameEn: 'Seoul National University',
  aliases: ['서울대', 'SNU', 'Seoul National', '관악'],
  domain: 'snu.ac.kr',
  verifiedAt: VERIFIED_AT,
  courseLink: canvasCourseLink('myetl.snu.ac.kr', {
    hint: '내 강의실에서 과목을 연 뒤 주소창을 통째로 붙여넣어 주세요. (myetl.snu.ac.kr/courses/12345)'
  }),
  services: [
    {
      id: 'snu.portal',
      kind: 'portal',
      label: '마이스누',
      labelEn: 'mySNU',
      url: 'https://my.snu.ac.kr/',
      verification: 'verified',
      note: '학사정보·성적·증명서·등록이 모두 이 안에 있어요.'
    },
    {
      id: 'snu.myetl',
      kind: 'lms',
      label: '내 강의실',
      labelEn: 'myeTL',
      url: 'https://myetl.snu.ac.kr/login',
      verification: 'verified',
      note: '루트(/)로 들어가면 로그인 전에는 JSON 원문이 보여요. /login이 SSO로 태워줍니다.'
    },
    {
      id: 'snu.etl',
      kind: 'lms',
      label: 'eTL 강좌',
      labelEn: 'New eTL',
      url: 'https://etl.snu.ac.kr/',
      verification: 'verified',
      note: '강좌 카탈로그·공지 전용이에요. 실제 강의실은 "내 강의실"입니다.'
    },
    {
      id: 'snu.oldetl',
      kind: 'lms',
      label: '구 eTL',
      url: 'https://oldetl.snu.ac.kr/',
      secondary: true,
      verification: 'verified',
      note: '지난 학기 자료 조회용 Moodle이에요.'
    },
    {
      id: 'snu.registration',
      kind: 'registration',
      label: '수강신청',
      url: 'https://sugang.snu.ac.kr/',
      verification: 'verified',
      note: 'NetFUNNEL 대기열을 써요. 대기 중에는 탭을 닫지 마세요.'
    },
    {
      id: 'snu.library',
      kind: 'library',
      label: '중앙도서관',
      url: 'https://lib.snu.ac.kr/',
      verification: 'verified'
    },
    {
      id: 'snu.library.search',
      kind: 'library',
      label: '자료검색',
      url: 'https://lib.snu.ac.kr/find/',
      secondary: true,
      verification: 'verified'
    },
    {
      id: 'snu.library.proxy',
      kind: 'other',
      label: '학외 접속',
      url: 'https://lib.snu.ac.kr/using/proxy/',
      secondary: true,
      verification: 'verified',
      note: '한 번 로그인해 두면 같은 세션으로 전자자원 접근이 유지돼요.'
    },
    {
      id: 'snu.mail',
      kind: 'mail',
      label: '학생 메일',
      url: 'https://mail.google.com/',
      opensExternally: true,
      externalReason: 'federated-login',
      verification: 'verified',
      note: '@snu.ac.kr 계정은 Google Workspace예요.'
    },
    {
      id: 'snu.mail.staff',
      kind: 'mail',
      label: '교직원 메일',
      url: 'https://snu.gov-dooray.com/',
      secondary: true,
      verification: 'verified'
    },
    {
      id: 'snu.homepage',
      kind: 'homepage',
      label: '학교 홈페이지',
      url: 'https://www.snu.ac.kr/',
      verification: 'verified'
    },
    {
      id: 'snu.calendar',
      kind: 'other',
      label: '학사일정',
      url: 'https://www.snu.ac.kr/academics/resources/calendar',
      secondary: true,
      verification: 'verified'
    },
    {
      id: 'snu.snugenie',
      kind: 'other',
      label: '스누지니',
      url: 'https://snugenie.snu.ac.kr/',
      secondary: true,
      verification: 'verified'
    },
    {
      id: 'snu.extra',
      kind: 'other',
      label: '비교과',
      url: 'https://extra.snu.ac.kr/main.html',
      secondary: true,
      verification: 'verified'
    },
    {
      id: 'snu.food',
      kind: 'other',
      label: '생협 식단',
      url: 'https://snuco.snu.ac.kr/foodmenu/',
      secondary: true,
      verification: 'verified'
    },
    {
      id: 'snu.map',
      kind: 'other',
      label: '캠퍼스 지도',
      url: 'https://map.snu.ac.kr/web/main.action',
      secondary: true,
      verification: 'verified'
    }
  ]
}
