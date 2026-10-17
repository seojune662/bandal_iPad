import Foundation

struct NativeSettingsCategory: Identifiable {
    let id: String
    let title: String
    let description: String
    let keywords: String
    let icon: String
    let group: String
}

enum NativeSettingsCatalog {
    static let groups: [(id: String, title: String)] = [
        ("ai", "AI"),
        ("setup", "설정"),
        ("workflows", "작업"),
        ("interface", "인터페이스"),
        ("privacy", "개인정보·보안"),
        ("advanced", "고급"),
        ("courses", "과목"),
        ("info", "정보"),
    ]
    static let categories: [NativeSettingsCategory] = [
        .init(id: "ai", title: "AI 엔진", description: "학습을 도와줄 AI 도구의 연결 상태를 확인합니다.", keywords: "에이전트 claude code codex 로그인 구독", icon: "sparkles", group: "ai"),
        .init(id: "assistant", title: "화면 도우미", description: "AI의 화면 도우미 동작을 관리합니다.", keywords: "화면 도우미 읽기 클릭 입력 screen assistant", icon: "rectangle.and.hand.point.up.left", group: "ai"),
        .init(id: "account", title: "계정", description: "반달 프로필과 로그인 상태를 관리합니다.", keywords: "계정 프로필 닉네임 로그아웃 로그인 반달", icon: "person.crop.circle", group: "setup"),
        .init(id: "general", title: "일반", description: "언어와 기본 동작을 관리합니다.", keywords: "일반 탭 언어 한국어 영어 튜토리얼 둘러보기 language korean english tutorial tour", icon: "slider.horizontal.3", group: "setup"),
        .init(id: "university", title: "학교", description: "학교 학사 사이트 바로가기를 관리합니다.", keywords: "학교 대학 학사 포털 lms 강의실 도서관 수강신청 바로가기 etl 캠퍼스 university", icon: "building.columns", group: "setup"),
        .init(id: "packs", title: "플러그인", description: "학습 도구, 확장과 외부 서비스를 한곳에서 관리합니다.", keywords: "플러그인 확장 학습 도구 팩 워크플로 연결 외부 서비스 MCP 서버 Notion GitHub Google Drive Slack JSON 권한 명령 패널", icon: "shippingbox", group: "workflows"),
        .init(id: "calendar", title: "달력", description: "Apple 캘린더와 반달 일정을 연결합니다.", keywords: "달력 애플 Apple iCloud 캘린더 일정 동기화 연결", icon: "calendar", group: "workflows"),
        .init(id: "browser", title: "브라우저", description: "홈페이지·검색·확대/축소와 링크 동작을 관리합니다.", keywords: "브라우저 웹뷰 홈페이지 검색 엔진 줌 확대 축소 링크 열기 브라우징 데이터 에이전트", icon: "globe", group: "workflows"),
        .init(id: "appearance", title: "화면", description: "반달이 보이는 방식을 선택합니다.", keywords: "외형 테마 라이트 다크 시스템 고대비 접근성 글자 크기 글꼴 밀도", icon: "paintpalette", group: "interface"),
        .init(id: "tabs", title: "탭", description: "마크다운·브라우저·AI·녹음·노트·학업 보드의 기본 동작을 관리합니다.", keywords: "탭 마크다운 녹음 STT Whisper 음성 모델 마이크 자막 재생 노트 학업 보드 단축키", icon: "rectangle.on.rectangle", group: "interface"),
        .init(id: "widgets", title: "위젯", description: "우측 사이드바의 위젯을 선택하고 정렬합니다.", keywords: "위젯 투두 할 일 학업 보드 메일 사이드바", icon: "square.grid.2x2", group: "interface"),
        .init(id: "notifications", title: "알림", description: "마감·AI 응답·다운로드를 OS 알림으로 받습니다.", keywords: "알림 OS 마감 AI 응답 다운로드 소리 포커스 방해 금지", icon: "bell", group: "interface"),
        .init(id: "shortcuts", title: "단축키", description: "반달과 웹뷰에서 사용할 키 조합을 관리합니다.", keywords: "단축키 키보드 키 조합 웹뷰 우선권 변경 초기화 JSON", icon: "keyboard", group: "interface"),
        .init(id: "usage", title: "사용 통계", description: "제공자별 AI 사용량을 확인합니다.", keywords: "사용 통계 토큰 한도 usage stats tokens limits", icon: "chart.bar", group: "interface"),
        .init(id: "permissions", title: "시스템 권한", description: "반달 기능에 필요한 기기 권한을 확인합니다.", keywords: "시스템 권한 화면 기록 손쉬운 사용 알림 문서 폴더 macOS permissions", icon: "lock.shield", group: "privacy"),
        .init(id: "privacy", title: "개인정보·진단", description: "데이터 처리와 진단 파일을 확인합니다.", keywords: "개인정보 보안 진단 데이터 수집 피드백 privacy diagnostics", icon: "hand.raised", group: "privacy"),
        .init(id: "advanced", title: "고급", description: "데이터 위치와 로그·캐시·초기화를 관리합니다.", keywords: "고급 데이터 폴더 로그 캐시 비우기 설정 초기화 유지 관리", icon: "wrench.and.screwdriver", group: "advanced"),
        .init(id: "experimental", title: "실험실", description: "아직 다듬고 있는 기능을 켜거나 끕니다.", keywords: "실험실 베타 확장 플러그인 런타임 기능 플래그", icon: "flask", group: "advanced"),
        .init(id: "courses", title: "과목", description: "반달에 등록된 과목을 한눈에 확인합니다.", keywords: "과목 수업 보관 아카이브", icon: "folder", group: "courses"),
        .init(id: "about", title: "정보", description: "반달의 버전을 확인하고 업데이트합니다.", keywords: "정보 버전 앱 제품 업데이트 최신 새버전 update", icon: "info.circle", group: "info"),
    ]
    private static let english: [String: String] = {
        guard let url = Bundle.main.url(forResource: "settings-en", withExtension: "json", subdirectory: "DesktopNative"), let data = try? Data(contentsOf: url), let values = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return values
    }()
    static func localized(_ locale: String) -> [NativeSettingsCategory] {
        guard locale == "en-US" else { return categories }
        return categories.map { item in
            NativeSettingsCategory(id: item.id, title: english["settings.category.\(item.id).label"] ?? item.title, description: english["settings.category.\(item.id).description"] ?? item.description, keywords: item.keywords + " " + (english["settings.category.\(item.id).keywords"] ?? ""), icon: item.icon, group: item.group)
        }
    }
    static func groupTitle(_ id: String, locale: String) -> String {
        if locale == "en-US" { return english["settings.group." + id] ?? (id == "privacy" ? "Privacy & security" : id) }
        return groups.first { $0.id == id }?.title ?? id
    }
    static func matching(_ query: String, locale: String = "ko-KR") -> [NativeSettingsCategory] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return localized(locale).filter { item in words.allSatisfy { (item.title + " " + item.description + " " + item.keywords).localizedStandardContains($0) } }
    }
}
