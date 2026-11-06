# 기본 UI 인벤토리 (1.4.0 UX 패스)

기준: NavigationStack 제목 바 + 취소/완료 시트, TextField 든 `.alert`, `confirmationDialog`, 시트·알림으로 하는 이름 변경.
처리: **팝오버** = BandalPopover(누른 컨트롤에 앵커), **인라인** = BandalInlineEditor, **확인** = `bandalConfirm`(앵커 팝오버 한 줄 + 버튼), **유지** = 시스템이 요구.

## 시트

| 파일:줄 | 화면 | 하는 일 | 처리 |
|---|---|---|---|
| Native/NativeWorkspaceView.swift:330 | 새 탭 | 새 탭 종류 선택 | 팝오버 |
| Native/NativeWorkspaceView.swift:336 | 새 과목 | 과목 만들기 (취소/만들기) | 팝오버 |
| Native/NativeWorkspaceView.swift:337, NativeSettingsSections.swift:64 | 과목 관리 | 과목 목록·보관 (완료) | 팝오버 |
| Native/NativeCourseManager.swift:63 | 과목 이름 | 과목 이름 변경 (NativeNameSheet) | 인라인 |
| Native/NativeCourseManager.swift:104 | 이동할 폴더 | 폴더 고르기 (취소) | 팝오버(검색 리스트) |
| Native/NativeSettingsSections.swift:65 | 반달 둘러보기 | 사용 안내 (완료) | 프로필 › 도움말 › 화면 도우미로 이동 |
| Native/NativePDFWorkspace.swift:94 | 원문 메모 | PDF 메모 편집 (취소/저장) | 팝오버, 즉시 저장 |
| Native/NativePDFWorkspace.swift:120 | 댓글 | PDF 댓글 편집 (취소/완료) | 팝오버, 즉시 저장 |
| Native/NativeBrowserWorkspace.swift:381 | 로그인 관리 | 저장된 로그인 (완료) | 팝오버 |
| Native/NativeBrowserWorkspace.swift:382 | 방문 기록 | 기록 보기·지우기 (완료) | 팝오버(검색 리스트) |
| Native/NativeBrowserWorkspace.swift:383 | 다운로드 | 다운로드 목록 (완료) | 팝오버 |
| Native/NativeBrowserWorkspace.swift:389 | 새 브라우저 프로필 | 프로필 이름 (NativeNameSheet) | 팝오버 한 줄 입력 |
| Native/NativeBrowserTabStrip.swift:35 | 열린 탭 N개 | 탭 목록 (완료) | 팝오버(검색 리스트) |
| Native/NativeMarkdownWorkspace.swift:176 | 노트 연결 | 위키 링크 노트 고르기 (취소) | 팝오버(검색 리스트) |
| Native/NativePlannerWorkspace.swift:107 | 새 할 일 / 할 일 수정 | 할 일 편집 (취소/저장) | 팝오버 |
| Native/NativeSettingsWidgetDock.swift:75–76 | 새 할 일 / 할 일 수정 | 위젯에서 할 일 편집 | 팝오버 |
| Native/NativeAuxiliaryDestinations.swift:35 | 기본 단축키 | 단축키 표 (완료) | 팝오버 |
| Native/NativeAuxiliaryDestinations.swift:155 | 계정 | 계정·로그인 화면 | 로그인은 시스템(ASWebAuthenticationSession) 유지, 시트 대신 레일 프로필 → 로그인 |
| Native/NativeAuxiliaryDestinations.swift:156 | 자료 정보 | 마켓 자료 정보 (완료) | 팝오버 (마켓 플래그 꺼짐) |
| Native/NativeLearningHome.swift:51, :83, NativeFeatureLauncherPanel.swift:43 | 학습 시작 | 학습 자료 만들기 (취소/시작) | 팝오버 |
| Native/NativeLearningHome.swift:188 | 새 프로젝트 | 프로젝트 이름 | 팝오버 한 줄 입력 |
| Native/NativeLearningHome.swift:195 | 프로젝트 이름 | 이름 변경 | 인라인 |
| Native/NativeLearningArticleView.swift:29 | 표현 저장 | 단어·표현 저장 (취소/저장) | 팝오버 |
| Native/NativeLibraryView.swift:161 | 새 노트 / 마크다운 / 폴더 | 만들기 (취소/만들기) | 팝오버 |
| Native/NativeLibraryView.swift:162 | 이동할 폴더 | 자료 이동 (취소) | 팝오버(검색 리스트) |
| Native/NativeLibraryView.swift:166 | 이름 변경 | 자료·폴더 이름 변경 | 인라인 |
| Native/NativeSettingsSyncPanel.swift:113 | {위치} 연결 | 동기화 합치기/덮어쓰기 선택 | 팝오버 |
| Native/NativeAssistantWorkspace.swift:403 | AI 선택 | 모델·effort (취소/적용) | 삭제 → 입력창 "Auto ▾" 팝오버 |
| Native/NativeAssistantWorkspace.swift:404 | {모드} 설정 | 퀴즈 범위·개수·난이도 (완료) | 팝오버 |
| Native/NativeAssistantWorkspace.swift:410 | 첨부 미리보기 | 첨부 보기 (닫기) | 팝오버 |
| Native/NativeSettingsShortcutsPanel.swift:70 | 단축키 변경 | 키 하나 편집 | 인라인 |
| PDF/PDFWorkspaceView.swift:105 | 페이지 | 옛 PDF 뷰 페이지 목록 | 팝오버 |
| Native/NativeLibrarySourceTray.swift:186 | 사진 선택 | 사진 피커 | 유지 (시스템) |
| Native/NativeMembership.swift:21 | 멤버십 | 페이월 (SubscriptionStoreView) | 유지 (StoreKit) |
| Native/NativeMembership.swift:142 | AI 크레딧 | 충전팩 (ProductView) | 유지 (StoreKit) |
| AI/AIConsent.swift:45 | AI 동의 | 제3자 전송 동의 | 유지 (5.1.2(i) 동의, 모달이어야 함) |
| Native/NativeRichTextEditor.swift:580 | 이미지 설정 | 이미지 폭·배치 | 이미 UIKit 팝오버 |

## TextField 든 alert (이름·값 입력)

| 파일:줄 | 화면 | 하는 일 | 처리 |
|---|---|---|---|
| Native/NativeWorkspaceWindowControls.swift:125 | 윈도우 이름 | 윈도우 이름 변경 | 인라인 |
| Native/NativeCourseSidebar.swift:64 | 이름 변경 | 사이드바 과목·그룹 이름 변경 | 인라인 |
| Native/NativeFavoritesSection.swift:68 | 즐겨찾기 이름 | 즐겨찾기 이름 변경 | 인라인 |
| Native/NativeLearningHome.swift:127 | 학습 공간 이름 | 이름 변경 | 인라인 |
| Native/NativeLearningArticleView.swift:66 | 표현의 뜻 | 뜻 입력 | 인라인 |
| Native/NativeLearningWorkspace.swift:36 | 기사 주소 | 기사 URL 추가 | 팝오버 한 줄 입력 |
| Native/NativeAssistantWorkspace.swift:405 | 기사 주소 | 기사 URL 가져오기 | 팝오버 한 줄 입력 |
| Native/NativeMarkdownWorkspace.swift:197 | 수식 편집 | LaTeX 수식 | 팝오버 한 줄 입력 |
| Native/NativeMarkdownWorkspace.swift:202 | 링크 주소 | 링크 삽입 | 팝오버 한 줄 입력 |
| PDF/PDFWorkspaceView.swift:129 | 텍스트 메모 | 옛 PDF 뷰 메모 | 팝오버 한 줄 입력 |
| Desktop/BrowserPage.swift:464, :472, DesktopBrowserHost.swift:607 | 웹 페이지 alert/prompt/confirm | WKUIDelegate | 유지 (웹 페이지가 요구) |

오류·안내 `.alert` 10개(작업을 완료하지 못했어요 등)는 BandalToast로 바꿉니다. 페이지 삭제·기록 지우기·로그인 저장 확인 alert는 `bandalConfirm`.

## confirmationDialog (18개)

설정 계정 삭제·새 프로필·로그아웃·기타(NativeSettingsWorkspace.swift:149/159/162/171), 시스템 패널(NativeSettingsSystemPanels.swift:37), 동기화 시작·끄기·덮어쓰기·클라우드에서 시작(NativeSettingsSyncPanel.swift:107/110/398/401), 단축키 초기화(NativeSettingsShortcutsPanel.swift:85), 브라우저 데이터 삭제(NativeSettingsBrowserPanel.swift:36), 파일 다시 읽기(NativeMarkdownWorkspace.swift:170), 할 일 삭제(NativePlannerWorkspace.swift:113), 학습 공간·프로젝트 삭제(NativeLearningHome.swift:128/204), 과목 보관·그룹 삭제(NativeCourseSidebar.swift:69/72), 대화 삭제(NativeAssistantWorkspace.swift:411), 자료 삭제(NativeLibraryView.swift:171) → 전부 `bandalConfirm`.

## 유지 (시스템 요구)

fileImporter 5곳, UIDocumentPicker·공유 시트, PhotosPicker, ASWebAuthenticationSession(Apple·Google 로그인, Google Drive), StoreKit 페이월·충전, AI 동의, WKWebView의 alert/prompt/confirm.
