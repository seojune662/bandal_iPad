/**
 * 서울권 주요 사립대 presets (docs/university-sites.md §2).
 *
 * Recurring shape: a Xinics "front" host (`lms.*` / `icampus.*` /
 * `e-campus.*`) in front of a Canvas "core" host (`canvas.*` /
 * `learning.*`). Course deep links live on the CORE host only.
 */

import type { University } from '../types/university'
import {
  canvasCourseLink,
  ilosCourseLink,
  moodleCourseLink
} from './specs'
import { VERIFIED_AT } from './snu'

const YONSEI: University = {
  id: 'yonsei',
  nameKo: '연세대학교',
  nameEn: 'Yonsei University',
  aliases: ['연세대', 'Yonsei', '신촌'],
  domain: 'yonsei.ac.kr',
  verifiedAt: VERIFIED_AT,
  courseLink: moodleCourseLink('ys.learnus.org'),
  services: [
    {
      id: 'yonsei.portal',
      kind: 'portal',
      label: '연세포탈',
      url: 'https://portal.yonsei.ac.kr/portal/MainCtr/index.do',
      opensExternally: true,
      externalReason: 'ua-sniffing',
      verification: 'verified',
      note: 'browserCheck.js가 분류하지 못한 브라우저를 전부 안내 페이지로 돌려보내요. 수강신청도 이 포털 안에 있습니다.'
    },
    {
      id: 'yonsei.lms',
      kind: 'lms',
      label: 'LearnUs',
      url: 'https://ys.learnus.org/',
      verification: 'verified'
    },
    {
      id: 'yonsei.library',
      kind: 'library',
      label: '학술정보원',
      url: 'https://library.yonsei.ac.kr/',
      verification: 'verified',
      note: '중간 인증서 체인이 불완전해서 드물게 경고가 뜰 수 있어요.'
    },
    {
      id: 'yonsei.mail',
      kind: 'mail',
      label: '웹메일',
      url: 'https://mail.yonsei.ac.kr/',
      verification: 'verified'
    },
    {
      id: 'yonsei.homepage',
      kind: 'homepage',
      label: '학교 홈페이지',
      url: 'https://www.yonsei.ac.kr/sc/index.do',
      verification: 'verified'
    }
  ]
}

const KOREA: University = {
  id: 'korea',
  nameKo: '고려대학교',
  nameEn: 'Korea University',
  aliases: ['고려대', 'Korea University', 'KU', '안암'],
  domain: 'korea.ac.kr',
  verifiedAt: VERIFIED_AT,
  courseLink: canvasCourseLink('canvas.korea.ac.kr'),
  services: [
    {
      id: 'korea.portal',
      kind: 'portal',
      label: 'KUPID',
      url: 'https://portal.korea.ac.kr/',
      verification: 'verified'
    },
    {
      id: 'korea.ams',
      kind: 'portal',
      label: '학사정보',
      labelEn: 'AMS',
      url: 'https://ams.korea.ac.kr/',
      secondary: true,
      verification: 'partial'
    },
    {
      id: 'korea.lms',
      kind: 'lms',
      label: 'LMS',
      url: 'https://lms.korea.ac.kr/',
      verification: 'verified'
    },
    {
      id: 'korea.canvas',
      kind: 'lms',
      label: '강의실',
      url: 'https://canvas.korea.ac.kr/',
      secondary: true,
      verification: 'verified'
    },
    {
      id: 'korea.registration',
      kind: 'registration',
      label: '수강신청',
      url: 'https://sugang.korea.ac.kr/',
      verification: 'verified'
    },
    {
      id: 'korea.library',
      kind: 'library',
      label: '도서관',
      url: 'https://library.korea.ac.kr/',
      verification: 'verified'
    },
    {
      id: 'korea.mail',
      kind: 'mail',
      label: '웹메일',
      url: 'https://mail.korea.ac.kr/',
      verification: 'verified'
    },
    {
      id: 'korea.homepage',
      kind: 'homepage',
      label: '학교 홈페이지',
      url: 'https://www.korea.ac.kr/sites/ko/index.do',
      verification: 'verified'
    },
    {
      id: 'korea.cert',
      kind: 'other',
      label: '증명발급',
      url: 'https://kucert.korea.ac.kr/',
      opensExternally: true,
      externalReason: 'native-plugin',
      secondary: true,
      verification: 'partial',
      note: '문서보안 프로그램을 설치해야 해서 앱 안에서는 동작하지 않아요.'
    }
  ]
}

const SKKU: University = {
  id: 'skku',
  nameKo: '성균관대학교',
  nameEn: 'Sungkyunkwan University',
  aliases: ['성균관대', 'SKKU', 'Sungkyunkwan', '성대'],
  domain: 'skku.edu',
  verifiedAt: VERIFIED_AT,
  courseLink: canvasCourseLink('canvas.skku.edu', { reliable: false }),
  services: [
    {
      id: 'skku.portal',
      kind: 'portal',
      label: '킹고포털',
      url: 'https://portal.skku.edu/',
      verification: 'partial'
    },
    {
      id: 'skku.lms',
      kind: 'lms',
      label: '아이캠퍼스',
      labelEn: 'i-Campus',
      url: 'https://icampus.skku.edu/',
      verification: 'verified',
      note: '녹화강의 재생에 Windows 전용 EverLec을 쓰는 과목이 있어요.'
    },
    {
      id: 'skku.canvas',
      kind: 'lms',
      label: '강의실',
      url: 'https://canvas.skku.edu/login',
      secondary: true,
      verification: 'partial'
    },
    {
      id: 'skku.registration',
      kind: 'registration',
      label: '수강신청',
      url: 'https://sugang.skku.edu/skku/',
      verification: 'verified'
    },
    {
      id: 'skku.library',
      kind: 'library',
      label: '도서관',
      url: 'https://lib.skku.edu/',
      verification: 'verified'
    },
    {
      id: 'skku.mail',
      kind: 'mail',
      label: '웹메일',
      url: 'https://mail.google.com/',
      opensExternally: true,
      externalReason: 'federated-login',
      verification: 'verified',
      note: '성균관대 메일은 Google Workspace예요.'
    },
    {
      id: 'skku.homepage',
      kind: 'homepage',
      label: '학교 홈페이지',
      url: 'https://www.skku.edu/skku/index.do',
      verification: 'verified'
    }
  ]
}

const HANYANG: University = {
  id: 'hanyang',
  nameKo: '한양대학교',
  nameEn: 'Hanyang University',
  aliases: ['한양대', 'Hanyang', 'HYU', 'ERICA', '에리카'],
  domain: 'hanyang.ac.kr',
  verifiedAt: VERIFIED_AT,
  courseLink: canvasCourseLink('learning.hanyang.ac.kr'),
  services: [
    {
      id: 'hanyang.portal',
      kind: 'portal',
      label: 'HY-in',
      url: 'https://portal.hanyang.ac.kr/sso/lgin.do',
      verification: 'verified'
    },
    {
      id: 'hanyang.canvas',
      kind: 'lms',
      label: '강의실',
      url: 'https://learning.hanyang.ac.kr/',
      verification: 'verified'
    },
    {
      id: 'hanyang.lms',
      kind: 'lms',
      label: 'LMS',
      url: 'https://lms.hanyang.ac.kr/',
      secondary: true,
      verification: 'verified'
    },
    {
      id: 'hanyang.registration',
      kind: 'registration',
      label: '수강신청',
      url: 'https://portal.hanyang.ac.kr/sugang/sulg.do',
      verification: 'verified',
      note: 'sugang.hanyang.ac.kr은 TLS 연결이 불안정해서 포털 경로를 씁니다.'
    },
    {
      id: 'hanyang.library.seoul',
      kind: 'library',
      label: '도서관(서울)',
      url: 'https://lib.hanyang.ac.kr/',
      verification: 'verified'
    },
    {
      id: 'hanyang.library.erica',
      kind: 'library',
      label: '도서관(ERICA)',
      url: 'https://information.hanyang.ac.kr/',
      verification: 'verified'
    },
    {
      id: 'hanyang.mail',
      kind: 'mail',
      label: '웹메일',
      url: 'https://mail.google.com/',
      opensExternally: true,
      externalReason: 'federated-login',
      verification: 'verified',
      note: '한양대 메일은 Google Workspace예요.'
    },
    {
      id: 'hanyang.homepage',
      kind: 'homepage',
      label: '학교 홈페이지',
      url: 'https://www.hanyang.ac.kr/home',
      verification: 'verified'
    },
    {
      id: 'hanyang.homepage.erica',
      kind: 'homepage',
      label: '홈페이지(ERICA)',
      url: 'https://www.hanyang.ac.kr/erica',
      secondary: true,
      verification: 'verified'
    }
  ]
}

const CAU: University = {
  id: 'cau',
  nameKo: '중앙대학교',
  nameEn: 'Chung-Ang University',
  aliases: ['중앙대', 'CAU', 'Chung-Ang', '흑석'],
  domain: 'cau.ac.kr',
  verifiedAt: VERIFIED_AT,
  courseLink: canvasCourseLink('eclass3.cau.ac.kr'),
  services: [
    {
      id: 'cau.portal',
      kind: 'portal',
      label: '중앙대 포탈',
      url: 'https://mportal.cau.ac.kr/',
      verification: 'verified'
    },
    {
      id: 'cau.lms',
      kind: 'lms',
      label: 'e-Class',
      url: 'https://eclass3.cau.ac.kr/',
      verification: 'verified'
    },
    {
      id: 'cau.canvas',
      kind: 'lms',
      label: 'CAU-ON',
      url: 'https://canvas.cau.ac.kr/',
      secondary: true,
      verification: 'verified'
    },
    {
      id: 'cau.registration',
      kind: 'registration',
      label: '수강신청',
      url: 'https://sugang.cau.ac.kr/',
      verification: 'verified'
    },
    {
      id: 'cau.library.seoul',
      kind: 'library',
      label: '도서관(서울)',
      url: 'https://library.cau.ac.kr/',
      verification: 'verified'
    },
    {
      id: 'cau.library.davinci',
      kind: 'library',
      label: '도서관(다빈치)',
      url: 'https://alibrary.cau.ac.kr/',
      verification: 'verified'
    },
    {
      id: 'cau.mail',
      kind: 'mail',
      label: '웹메일',
      url: 'https://mail.cau.ac.kr/',
      opensExternally: true,
      externalReason: 'federated-login',
      verification: 'verified',
      note: '중앙대 메일은 Microsoft 365예요.'
    },
    {
      id: 'cau.homepage',
      kind: 'homepage',
      label: '학교 홈페이지',
      url: 'https://www.cau.ac.kr/',
      verification: 'verified'
    }
  ]
}

const KHU: University = {
  id: 'khu',
  nameKo: '경희대학교',
  nameEn: 'Kyung Hee University',
  aliases: ['경희대', 'KHU', 'Kyung Hee', '회기', '국제캠'],
  domain: 'khu.ac.kr',
  verifiedAt: VERIFIED_AT,
  courseLink: canvasCourseLink('khcanvas.khu.ac.kr'),
  services: [
    {
      id: 'khu.portal',
      kind: 'portal',
      label: '포털',
      url: 'https://portal.khu.ac.kr/',
      verification: 'verified'
    },
    {
      id: 'khu.info21',
      kind: 'portal',
      label: '인포21',
      labelEn: 'Info21',
      url: 'https://info21.khu.ac.kr/',
      verification: 'partial',
      note: '통합 아이디의 기준이 되는 학사정보 시스템이에요.'
    },
    {
      id: 'khu.lms',
      kind: 'lms',
      label: 'e-Campus',
      url: 'https://e-campus.khu.ac.kr/',
      verification: 'verified'
    },
    {
      id: 'khu.canvas',
      kind: 'lms',
      label: '강의실',
      url: 'https://khcanvas.khu.ac.kr/',
      secondary: true,
      verification: 'verified'
    },
    {
      id: 'khu.registration',
      kind: 'registration',
      label: '수강신청',
      url: 'https://sugang.khu.ac.kr/',
      verification: 'verified'
    },
    {
      id: 'khu.library',
      kind: 'library',
      label: '중앙도서관',
      url: 'https://lib.khu.ac.kr/',
      verification: 'verified'
    },
    {
      id: 'khu.mail',
      kind: 'mail',
      label: '웹메일',
      url: 'https://mail.khu.ac.kr/',
      verification: 'verified'
    },
    {
      id: 'khu.homepage',
      kind: 'homepage',
      label: '학교 홈페이지',
      url: 'https://www.khu.ac.kr/',
      verification: 'verified'
    }
  ]
}

const SOGANG: University = {
  id: 'sogang',
  nameKo: '서강대학교',
  nameEn: 'Sogang University',
  aliases: ['서강대', 'Sogang', '노고산'],
  domain: 'sogang.ac.kr',
  verifiedAt: VERIFIED_AT,
  courseLink: ilosCourseLink('cyber.sogang.ac.kr'),
  services: [
    {
      id: 'sogang.portal',
      kind: 'portal',
      label: 'SAINT',
      url: 'https://saint.sogang.ac.kr/irj/portal',
      opensExternally: true,
      externalReason: 'ua-sniffing',
      verification: 'partial',
      note: 'SAP 포털이 브라우저를 가려서 "iView를 열 수 없습니다"를 돌려줘요.'
    },
    {
      id: 'sogang.lms',
      kind: 'lms',
      label: '사이버캠퍼스',
      url: 'https://cyber.sogang.ac.kr/ilos/main/main_form.acl',
      verification: 'verified'
    },
    {
      id: 'sogang.registration',
      kind: 'registration',
      label: '수강신청',
      url: 'https://sis109.sogang.ac.kr/zu4a/zcmuik101',
      verification: 'verified',
      note: 'SAINT와 동시에 로그인하면 중복 로그인 문제가 생길 수 있어요.'
    },
    {
      id: 'sogang.library',
      kind: 'library',
      label: '로욜라도서관',
      url: 'https://library.sogang.ac.kr/',
      verification: 'verified'
    },
    {
      id: 'sogang.mail',
      kind: 'mail',
      label: '웹메일',
      url: 'https://mail.sogang.ac.kr/',
      verification: 'partial'
    },
    {
      id: 'sogang.homepage',
      kind: 'homepage',
      label: '학교 홈페이지',
      url: 'https://www.sogang.ac.kr/',
      verification: 'verified'
    }
  ]
}

const EWHA: University = {
  id: 'ewha',
  nameKo: '이화여자대학교',
  nameEn: 'Ewha Womans University',
  aliases: ['이화여대', '이대', 'Ewha', '이화'],
  domain: 'ewha.ac.kr',
  verifiedAt: VERIFIED_AT,
  courseLink: moodleCourseLink('cyber.ewha.ac.kr'),
  services: [
    {
      id: 'ewha.eureka',
      kind: 'portal',
      label: '유레카',
      labelEn: 'EUREKA',
      url: 'https://eureka.ewha.ac.kr/',
      verification: 'partial',
      note: '통합로그인의 기준이 되는 시스템이에요.'
    },
    {
      id: 'ewha.portal',
      kind: 'portal',
      label: '이화포탈',
      url: 'https://portal.ewha.ac.kr/',
      secondary: true,
      verification: 'unverified',
      note: '정확한 진입 경로를 아직 확인하지 못했어요.'
    },
    {
      id: 'ewha.lms',
      kind: 'lms',
      label: '사이버캠퍼스',
      url: 'https://cyber.ewha.ac.kr/',
      verification: 'verified'
    },
    {
      id: 'ewha.registration',
      kind: 'registration',
      label: '수강신청',
      url: 'https://sugang.ewha.ac.kr/',
      verification: 'verified'
    },
    {
      id: 'ewha.library',
      kind: 'library',
      label: '중앙도서관',
      url: 'https://lib.ewha.ac.kr/',
      verification: 'partial'
    },
    {
      id: 'ewha.mail',
      kind: 'mail',
      label: '웹메일',
      url: 'https://mail.google.com/',
      opensExternally: true,
      externalReason: 'federated-login',
      verification: 'verified',
      note: '이화여대 메일은 Google Workspace예요.'
    },
    {
      id: 'ewha.homepage',
      kind: 'homepage',
      label: '학교 홈페이지',
      url: 'https://www.ewha.ac.kr/',
      verification: 'verified'
    }
  ]
}

export const SEOUL_PRIVATE_UNIVERSITIES: readonly University[] = [
  YONSEI,
  KOREA,
  SKKU,
  HANYANG,
  CAU,
  KHU,
  SOGANG,
  EWHA
]
