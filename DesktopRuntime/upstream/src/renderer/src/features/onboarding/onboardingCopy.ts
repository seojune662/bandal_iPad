import type { Locale } from '../../i18n'
import { getLocale } from '../../i18n/localeStore'

const ko = {
  welcome: '반달에 오신 걸 환영해요',
  description: '자료를 읽고, 질문하고, 복습하는 공부 공간입니다.',
  tour: '핵심 기능 5개 보기',
  direct: '바로 시작하기',
  close: '안내 닫기',
  tourDescription: '예시 과목으로 실제 화면을 보여드리며, 질문 전송이나 AI 생성은 실행하지 않아요. 끝내거나 건너뛰면 예시 자료는 모두 정리됩니다.',
  offer: '핵심 기능 5개를 살펴보세요',
  preparing: '예시 자료를 준비하는 중…',
  cleaning: '예시 자료를 정리하는 중…',
  next: '다음', previous: '이전', skip: '건너뛰기', finish: '끝내기', later: '나중에',
  moving: '화면을 여는 중…', progress: '튜토리얼 진행 단계', current: '현재 단계',
  missing: '이 화면이 보이지 않아도 설명을 읽고 다음으로 넘어갈 수 있어요.',
  dataRoot: '예시 자료를 저장할 위치를 설정해 주세요.',
  startFailed: '안내를 시작하지 못했어요. 잠시 후 다시 시도해 주세요.',
  cleanupFailed: '예시 자료를 정리하지 못했어요. 끝내기를 다시 눌러 주세요.',
  saveFailed: '안내 선택을 저장하지 못했어요. 다시 시도해 주세요.',
  courseName: '반달 튜토리얼', noteName: '예시 필기.md', pdfName: '예시 강의자료.pdf',
  seedNote: '# 예시 필기\n\nPDF를 보며 핵심 내용을 여기에 정리해 보세요. 필기는 자동으로 저장됩니다.\n\n이 과목과 자료는 튜토리얼이 끝나면 정리됩니다.\n',
  materialsTitle: '과목에 자료 모으기',
  materialsBody: '과목마다 자료와 필기를 한 폴더에 모을 수 있어요. 자료 가져오기를 누르거나 파일을 끌어오면 목록에 저장됩니다.',
  readingTitle: 'PDF를 읽고 필기하기',
  readingBody: 'PDF와 필기를 나란히 열어 읽으면서 정리하세요. PDF에 하이라이트와 메모를 남길 수 있고, 필기는 자동으로 저장됩니다.',
  assistantTitle: '현재 자료에 대해 AI에게 질문하기',
  assistantBody: '자료 옆의 AI를 열면 현재 문서와 페이지를 바탕으로 대화할 수 있어요. AI 연결이 필요하며, 질문은 보내기를 눌러야 전송됩니다.',
  reviewTitle: '내 자료로 퀴즈와 카드 만들기',
  reviewBody: '퀴즈 또는 카드에서 선택한 부분·현재 자료·과목 자료 중 범위를 고를 수 있어요. 만들기를 누르면 AI가 학습 자료를 만들고, 결과를 열어 풀거나 복습할 수 있어요.',
  englishTitle: '관심 있는 영어 글 읽기',
  englishBody: '영어 글 읽기에서 처음에는 관심 주제와 수준을 정하고, 다음부터 읽던 공간을 이어가요. 글을 읽고 표현을 모아 복습할 수 있어요.'
}
const en: typeof ko = {
  welcome: 'Welcome to Bandal', description: 'A study space to read, ask questions, and review.',
  tour: 'Explore 5 key features', direct: 'Start using Bandal', close: 'Close introduction',
  tourDescription: 'Explore the real interface with a sample course without sending questions or running AI generation. Its sample files are removed when you finish or skip.',
  offer: 'Explore 5 key features', preparing: 'Preparing sample files…', cleaning: 'Removing sample files…',
  next: 'Next', previous: 'Back', skip: 'Skip tour', finish: 'Finish', later: 'Later', moving: 'Opening the view…',
  progress: 'Tutorial progress', current: 'current step',
  missing: 'You can read this explanation and continue even when the view is unavailable.',
  dataRoot: 'Choose a location for the sample files first.', startFailed: 'Could not start the tour. Please try again shortly.',
  cleanupFailed: 'Could not remove the sample files. Select Finish again.', saveFailed: 'Could not save your choice. Please try again.',
  courseName: 'Bandal tutorial', noteName: 'Sample notes.md', pdfName: 'Sample lecture.pdf',
  seedNote: '# Sample notes\n\nWrite down the key points while reading the PDF. Notes save automatically.\n\nThis course and its files are removed when the tour ends.\n',
  materialsTitle: 'Collect materials by course',
  materialsBody: 'Keep each course’s materials and notes in one folder. Import files or drag them into the materials list to save them there.',
  readingTitle: 'Read PDFs and take notes',
  readingBody: 'Read your PDF beside your notes. Highlight passages and add comments to the PDF; your notes save automatically.',
  assistantTitle: 'Ask AI about the current material',
  assistantBody: 'Open AI beside a document to discuss its current content and page. Connect an AI provider first; a question is sent only when you select Send.',
  reviewTitle: 'Create quizzes and flashcards from your material',
  reviewBody: 'Choose quizzes or flashcards and select a passage, the current material, or the course materials as the scope. Select Create to have AI prepare study material you can open to practice and review.',
  englishTitle: 'Read English about your interests',
  englishBody: 'Choose English reading to set your interests and level the first time, then return to the space you were reading. Read articles and collect expressions to review.'
}
export function onboardingCopy(locale: Locale = getLocale()): typeof ko {
  return locale === 'en-US' ? en : ko
}
