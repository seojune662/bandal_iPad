/**
 * 이공계 특성화 · 지방 거점 국립대 · 수도권 사립대 presets
 * (docs/university-sites.md §3).
 *
 * Three of the embedded-browser hard blocks live in this file:
 * KAIST 수강신청 (UA sniffing that fails closed), 아주대 AIMS2 (NPAPI/ActiveX
 * — structurally impossible since Chromium dropped NPAPI in 2015), and
 * 세종대 포털 (INCA nProtect keyboard security, which does not error — it
 * simply never submits the form).
 */

import type { University } from '../types/university'
import {
  blackboardCourseLink,
  ilosCourseLink,
  moodleCourseLink,
  canvasCourseLink
} from './specs'
import { VERIFIED_AT } from './snu'

const KAIST: University = {
  id: 'kaist',
  nameKo: '한국과학기술원',
  nameEn: 'KAIST',
  aliases: ['KAIST', '카이스트', '한국과학기술원', '대전'],
  domain: 'kaist.ac.kr',
  verifiedAt: VERIFIED_AT,
  courseLink: moodleCourseLink('klms.kaist.ac.kr'),
  services: [
    {
      id: 'kaist.portal',
      kind: 'portal',
      label: 'KAIST 포털',
      url: 'https://portal.kaist.ac.kr/',
      verification: 'verified'
    },
    {
      id: 'kaist.lms',
      kind: 'lms',
      label: 'KLMS',
      url: 'https://klms.kaist.ac.kr/',
      verification: 'verified'
    },
    {
      id: 'kaist.registration',
      kind: 'registration',
      label: '수강신청',
      url: 'https://sugang.kaist.ac.kr/',
      opensExternally: true,
      externalReason: 'ua-sniffing',
      verification: 'verified',
      note: 'browserCheck.js가 분류하지 못한 브라우저에서 빈 화면을 남겨요.'
    },
    {
      id: 'kaist.library',
      kind: 'library',
      label: '도서관',
      url: 'https://library.kaist.ac.kr/',
      verification: 'verified'
    },
    {
      id: 'kaist.mail',
      kind: 'mail',
      label: '메일',
      url: 'https://mail.kaist.ac.kr/',
      verification: 'verified',
      note: 'Dooray라서 학사 로그인과는 별개 세션이에요.'
    },
    {
      id: 'kaist.homepage',
      kind: 'homepage',
      label: '학교 홈페이지',
      url: 'https://www.kaist.ac.kr/kr/',
      verification: 'verified'
    }
  ]
}

const POSTECH: University = {
  id: 'postech',
  nameKo: '포항공과대학교',
  nameEn: 'POSTECH',
  aliases: ['POSTECH', '포스텍', '포항공대', '포공'],
  domain: 'postech.ac.kr',
  verifiedAt: VERIFIED_AT,
  courseLink: moodleCourseLink('plms.postech.ac.kr'),
  services: [
    {
      id: 'postech.povis',
      kind: 'portal',
      label: 'POVIS',
      url: 'https://povis.postech.ac.kr/',
      verification: 'verified',
      note: '수강신청도 POVIS 안에 있어요.'
    },
    {
      id: 'postech.podium',
      kind: 'portal',
      label: 'PODIUM',
      url: 'https://podium.postech.ac.kr/',
      secondary: true,
      verification: 'partial',
      note: 'POVIS와 함께 살아 있어요. 학과 안내에 따라 다를 수 있습니다.'
    },
    {
      id: 'postech.lms',
      kind: 'lms',
      label: 'PLMS',
      url: 'https://plms.postech.ac.kr/',
      verification: 'verified'
    },
    {
      id: 'postech.library',
      kind: 'library',
      label: '학술정보관',
      url: 'https://library.postech.ac.kr/',
      verification: 'verified'
    },
    {
      id: 'postech.mail',
      kind: 'mail',
      label: '웹메일',
      url: 'https://mail.postech.ac.kr/',
      opensExternally: true,
      externalReason: 'federated-login',
      verification: 'verified',
      note: 'Microsoft Exchange + ADFS 로그인이에요.'
    },
    {
      id: 'postech.homepage',
      kind: 'homepage',
      label: '학교 홈페이지',
      url: 'https://www.postech.ac.kr/kor/index.do',
      verification: 'verified'
    },
    {
      id: 'postech.cert',
      kind: 'other',
      label: '증명발급',
      url: 'http://cert.postech.ac.kr/',
      opensExternally: true,
      externalReason: 'native-plugin',
      secondary: true,
      verification: 'partial',
      note: '문서보안 프로그램을 설치해야 해서 앱 안에서는 동작하지 않아요.'
    }
  ]
}

const KONKUK: University = {
  id: 'konkuk',
  nameKo: '건국대학교',
  nameEn: 'Konkuk University',
  aliases: ['건국대', 'Konkuk', 'KU', '건대'],
  domain: 'konkuk.ac.kr',
  verifiedAt: VERIFIED_AT,
  courseLink: ilosCourseLink('ecampus.konkuk.ac.kr'),
  services: [
    {
      id: 'konkuk.portal',
      kind: 'portal',
      label: '위인전',
      labelEn: 'WeIn',
      url: 'https://wein.konkuk.ac.kr/',
      verification: 'verified'
    },
    {
      id: 'konkuk.kuis',
      kind: 'portal',
      label: '학사정보',
      labelEn: 'KUIS',
      url: 'https://kuis.konkuk.ac.kr/',
      verification: 'verified'
    },
    {
      id: 'konkuk.lms',
      kind: 'lms',
      label: 'eCampus',
      url: 'https://ecampus.konkuk.ac.kr/ilos/index.acl',
      verification: 'verified'
    },
    {
      id: 'konkuk.registration',
      kind: 'registration',
      label: '수강신청',
      url: 'https://sugang.konkuk.ac.kr/sugang/index.jsp',
      verification: 'verified'
    },
    {
      id: 'konkuk.library',
      kind: 'library',
      label: '상허기념도서관',
      url: 'https://library.konkuk.ac.kr/',
      verification: 'verified'
    },
    {
      id: 'konkuk.mail',
      kind: 'mail',
      label: '웹메일',
      url: 'https://kumail.konkuk.ac.kr/',
      opensExternally: true,
      externalReason: 'federated-login',
      verification: 'verified',
      note: '건국대 메일은 Microsoft 365 + ADFS예요.'
    },
    {
      id: 'konkuk.homepage',
      kind: 'homepage',
      label: '학교 홈페이지',
      url: 'https://www.konkuk.ac.kr/konkuk/index.do',
      verification: 'verified',
      note: '리다이렉트가 5번 일어나서 열리는 데 잠깐 걸릴 수 있어요.'
    }
  ]
}

const DONGGUK: University = {
  id: 'dongguk',
  nameKo: '동국대학교',
  nameEn: 'Dongguk University',
  aliases: ['동국대', 'Dongguk', '충무로'],
  domain: 'dongguk.edu',
  verifiedAt: VERIFIED_AT,
  courseLink: moodleCourseLink('eclass.dongguk.edu'),
  services: [
    {
      id: 'dongguk.portal',
      kind: 'portal',
      label: 'uDRIMS',
      url: 'https://nportal.dongguk.edu/comm/login/user/login.do',
      verification: 'verified',
      note: 'portal.dongguk.edu는 이 주소로 강제 이동시켜요.'
    },
    {
      id: 'dongguk.lms',
      kind: 'lms',
      label: '이클래스',
      url: 'https://eclass.dongguk.edu/',
      verification: 'verified'
    },
    {
      id: 'dongguk.registration',
      kind: 'registration',
      label: '수강신청',
      url: 'https://sugang.dongguk.edu/',
      verification: 'verified'
    },
    {
      id: 'dongguk.library',
      kind: 'library',
      label: '중앙도서관',
      url: 'https://lib.dongguk.edu/',
      verification: 'verified'
    },
    {
      id: 'dongguk.mail',
      kind: 'mail',
      label: 'CloudMail',
      url: 'https://mail.dongguk.edu/',
      verification: 'verified'
    },
    {
      id: 'dongguk.homepage',
      kind: 'homepage',
      label: '학교 홈페이지',
      url: 'https://www.dongguk.edu/main',
      verification: 'verified'
    }
  ]
}

const PUSAN: University = {
  id: 'pusan',
  nameKo: '부산대학교',
  nameEn: 'Pusan National University',
  aliases: ['부산대', 'PNU', 'Pusan', '부산국립대'],
  domain: 'pusan.ac.kr',
  verifiedAt: VERIFIED_AT,
  courseLink: moodleCourseLink('plato.pusan.ac.kr'),
  services: [
    {
      id: 'pusan.portal',
      kind: 'portal',
      label: '학생지원시스템',
      url: 'https://onestop.pusan.ac.kr/',
      verification: 'verified',
      note: '처음 로그인할 때 이메일 2차 인증이 필요해요.'
    },
    {
      id: 'pusan.one',
      kind: 'portal',
      label: '교육정보시스템',
      url: 'https://one.pusan.ac.kr/',
      secondary: true,
      verification: 'verified'
    },
    {
      id: 'pusan.lms',
      kind: 'lms',
      label: 'PLATO',
      url: 'https://plato.pusan.ac.kr/',
      verification: 'verified'
    },
    {
      id: 'pusan.registration',
      kind: 'registration',
      label: '수강신청',
      url: 'https://sugang.pusan.ac.kr/',
      verification: 'verified'
    },
    {
      id: 'pusan.library',
      kind: 'library',
      label: '도서관',
      url: 'https://lib.pusan.ac.kr/',
      verification: 'verified'
    },
    {
      id: 'pusan.mail',
      kind: 'mail',
      label: '웹메일',
      url: 'https://mail.pusan.ac.kr/mail',
      verification: 'verified'
    },
    {
      id: 'pusan.homepage',
      kind: 'homepage',
      label: '학교 홈페이지',
      url: 'https://www.pusan.ac.kr/kor/',
      verification: 'verified'
    }
  ]
}

const KNU: University = {
  id: 'knu',
  nameKo: '경북대학교',
  nameEn: 'Kyungpook National University',
  aliases: ['경북대', 'KNU', 'Kyungpook', '대구'],
  domain: 'knu.ac.kr',
  verifiedAt: VERIFIED_AT,
  courseLink: canvasCourseLink('canvas.knu.ac.kr'),
  services: [
    {
      id: 'knu.portal',
      kind: 'portal',
      label: '통합포털',
      url: 'https://on.knu.ac.kr/',
      verification: 'verified',
      note: '로그인이 여러 화면을 거쳐서 넘어가요. 중간에 멈춘 것처럼 보여도 기다려 주세요.'
    },
    {
      id: 'knu.knuin',
      kind: 'portal',
      label: '학사정보',
      labelEn: 'KNUIN',
      url: 'https://knuin.knu.ac.kr/knuin/index.knu',
      secondary: true,
      verification: 'partial'
    },
    {
      id: 'knu.lms',
      kind: 'lms',
      label: 'LMS',
      url: 'https://lms.knu.ac.kr/',
      verification: 'verified'
    },
    {
      id: 'knu.canvas',
      kind: 'lms',
      label: '강의실',
      url: 'https://canvas.knu.ac.kr/',
      secondary: true,
      verification: 'verified'
    },
    {
      id: 'knu.registration',
      kind: 'registration',
      label: '수강신청',
      url: 'https://sugang.knu.ac.kr/',
      verification: 'partial'
    },
    {
      id: 'knu.library',
      kind: 'library',
      label: '도서관',
      url: 'https://kudos.knu.ac.kr/',
      verification: 'verified'
    },
    {
      id: 'knu.mail',
      kind: 'mail',
      label: '웹메일',
      url: 'https://mail.knu.ac.kr/mail',
      verification: 'verified'
    },
    {
      id: 'knu.homepage',
      kind: 'homepage',
      label: '학교 홈페이지',
      url: 'https://www.knu.ac.kr/wbbs/wbbs/main/main.action',
      verification: 'verified'
    }
  ]
}

const INHA: University = {
  id: 'inha',
  nameKo: '인하대학교',
  nameEn: 'Inha University',
  aliases: ['인하대', 'Inha', '인천'],
  domain: 'inha.ac.kr',
  verifiedAt: VERIFIED_AT,
  courseLink: moodleCourseLink('learn.inha.ac.kr'),
  services: [
    {
      id: 'inha.portal',
      kind: 'portal',
      label: '인하포털',
      url: 'https://portal.inha.ac.kr/',
      verification: 'verified'
    },
    {
      id: 'inha.lms',
      kind: 'lms',
      label: 'I-Class',
      url: 'https://learn.inha.ac.kr/',
      verification: 'verified'
    },
    {
      id: 'inha.registration',
      kind: 'registration',
      label: '수강신청',
      url: 'https://sugang.inha.ac.kr/',
      verification: 'verified'
    },
    {
      id: 'inha.library',
      kind: 'library',
      label: '정석학술정보관',
      url: 'https://lib.inha.ac.kr/',
      verification: 'verified'
    },
    {
      id: 'inha.mail',
      kind: 'mail',
      label: '메일',
      url: 'https://cloud.inha.ac.kr/t/inha.ac.kr',
      opensExternally: true,
      externalReason: 'federated-login',
      verification: 'verified',
      note: 'Google Workspace로 연결돼요.'
    },
    {
      id: 'inha.homepage',
      kind: 'homepage',
      label: '학교 홈페이지',
      url: 'https://www.inha.ac.kr/kr/index.do',
      verification: 'verified'
    },
    {
      id: 'inha.cert',
      kind: 'other',
      label: '증명발급',
      url: 'https://cert.inha.ac.kr/',
      opensExternally: true,
      externalReason: 'native-plugin',
      secondary: true,
      verification: 'verified',
      note: '보안 프로그램 설치를 요구해서 앱 안에서는 동작하지 않아요.'
    }
  ]
}

const AJOU: University = {
  id: 'ajou',
  nameKo: '아주대학교',
  nameEn: 'Ajou University',
  aliases: ['아주대', 'Ajou', '수원'],
  domain: 'ajou.ac.kr',
  verifiedAt: VERIFIED_AT,
  courseLink: blackboardCourseLink('eclass2.ajou.ac.kr'),
  services: [
    {
      id: 'ajou.portal',
      kind: 'portal',
      label: '아주대 포탈',
      url: 'https://portal.ajou.ac.kr/main.do',
      verification: 'verified'
    },
    {
      id: 'ajou.haksa',
      kind: 'portal',
      label: '학사서비스',
      url: 'https://mhaksa.ajou.ac.kr:30443/',
      secondary: true,
      verification: 'partial'
    },
    {
      id: 'ajou.lms',
      kind: 'lms',
      label: 'eClass',
      url: 'https://eclass2.ajou.ac.kr/',
      verification: 'partial',
      note: 'Blackboard 기반이고, 다른 시스템으로 이관이 진행 중일 수 있어요.'
    },
    {
      id: 'ajou.library',
      kind: 'library',
      label: '도서관',
      url: 'https://library.ajou.ac.kr/',
      verification: 'verified'
    },
    {
      id: 'ajou.mail',
      kind: 'mail',
      label: '메일',
      url: 'https://mail.google.com/a/ajou.ac.kr',
      opensExternally: true,
      externalReason: 'federated-login',
      verification: 'verified',
      note: '아주대는 자체 웹메일 없이 Google Workspace를 써요.'
    },
    {
      id: 'ajou.homepage',
      kind: 'homepage',
      label: '학교 홈페이지',
      url: 'https://www.ajou.ac.kr/kr/index.do',
      verification: 'verified'
    },
    {
      id: 'ajou.aims',
      kind: 'other',
      label: 'AIMS2',
      url: 'https://aims.ajou.ac.kr/',
      opensExternally: true,
      externalReason: 'native-plugin',
      secondary: true,
      verification: 'partial',
      note: 'ActiveX/NPAPI 기반이라 최신 브라우저에서도 별도 프로그램이 필요해요.'
    }
  ]
}

const SEJONG: University = {
  id: 'sejong',
  nameKo: '세종대학교',
  nameEn: 'Sejong University',
  aliases: ['세종대', 'Sejong', '군자'],
  domain: 'sejong.ac.kr',
  verifiedAt: VERIFIED_AT,
  courseLink: moodleCourseLink('ecampus.sejong.ac.kr'),
  services: [
    {
      id: 'sejong.portal',
      kind: 'portal',
      label: '세종대 포털',
      url: 'https://portal.sejong.ac.kr/jsp/login/loginSSL.jsp',
      opensExternally: true,
      externalReason: 'native-plugin',
      verification: 'verified',
      note: '키보드보안 프로그램(nProtect)이 필요해서 앱 안에서는 로그인 버튼이 눌리지 않아요.'
    },
    {
      id: 'sejong.sjpt',
      kind: 'portal',
      label: '학사정보',
      url: 'https://sjpt.sejong.ac.kr/',
      verification: 'verified',
      note: '수강신청도 이 안에 있어요.'
    },
    {
      id: 'sejong.lms',
      kind: 'lms',
      label: '집현캠퍼스',
      url: 'https://ecampus.sejong.ac.kr/',
      verification: 'verified'
    },
    {
      id: 'sejong.library',
      kind: 'library',
      label: '학술정보원',
      url: 'https://library.sejong.ac.kr/',
      verification: 'verified'
    },
    {
      id: 'sejong.mail',
      kind: 'mail',
      label: '학생 메일',
      url: 'https://outlook.office.com/mail/',
      opensExternally: true,
      externalReason: 'federated-login',
      verification: 'partial',
      note: '학생 계정(@sju.ac.kr)은 Microsoft 365예요.'
    },
    {
      id: 'sejong.mail.staff',
      kind: 'mail',
      label: '교직원 메일',
      url: 'https://mail.sejong.ac.kr/',
      opensExternally: true,
      externalReason: 'native-plugin',
      secondary: true,
      verification: 'verified',
      note: '포털과 같은 키보드보안 프로그램을 써요.'
    },
    {
      id: 'sejong.homepage',
      kind: 'homepage',
      label: '학교 홈페이지',
      url: 'https://www.sejong.ac.kr/kor/index.do',
      verification: 'verified'
    }
  ]
}

export const REGIONAL_UNIVERSITIES: readonly University[] = [
  KAIST,
  POSTECH,
  KONKUK,
  DONGGUK,
  PUSAN,
  KNU,
  INHA,
  AJOU,
  SEJONG
]
