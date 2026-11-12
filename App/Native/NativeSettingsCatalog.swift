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
    static var categories: [NativeSettingsCategory] {
        allCategories.filter { (NativeReleaseFlags.showsAccount || $0.id != "account") && (NativeReleaseFlags.membership || $0.id != "subscription") }
    }
    /// Section ids from before 1.4.0 (deep links, saved state) and where their rows live now.
    static let aliases: [String: String] = [
        "notifications": "general", "shortcuts": "general", "advanced": "general", "about": "general", "privacy": "general",
        "permissions": "general", "usage": "subscription", "tabs": "appearance", "widgets": "appearance", "university": "integrations", "referral": "account",
        "courses": "general", "assistant": "ai", "packs": "integrations", "plugins": "integrations", "experimental": "integrations",
        "calendar": "integrations", "browser": "integrations",
    ]
    /// The page inside its section that an old id opens: the school page, or the section's 더 보기.
    static func subpage(_ id: String) -> String? {
        id == "university" ? "university" : ["notifications", "shortcuts", "advanced", "about", "privacy", "permissions", "tabs", "widgets", "calendar", "browser", "referral"].contains(id) ? "more" : nil
    }
    static func resolve(_ id: String) -> String {
        let value = aliases[id] ?? id
        return categories.contains { $0.id == value } ? value : "general"
    }
    private static let allCategories: [NativeSettingsCategory] = [
        .init(id: "general", title: "일반", description: "언어, 시작, 알림, 단축키", keywords: "일반 언어 한국어 영어 시작 복원 탭 알림 마감 소리 단축키 키보드 키 조합 우선권 고급 캐시 초기화 진단 language notifications shortcuts", icon: "gearshape", group: "settings"),
        .init(id: "appearance", title: "화면", description: "테마, 글자, 탭과 위젯", keywords: "화면 외형 테마 꾸미기 색 팔레트 세기 그라데이션 라이트 다크 시스템 글자 크기 글꼴 밀도 탭 마크다운 녹음 노트 배경 학업 보드 위젯 투두 메일 appearance theme", icon: "macwindow", group: "settings"),
        .init(id: "account", title: "계정", description: "프로필, 학교, 로그인", keywords: "계정 프로필 닉네임 이메일 로그인 로그아웃 계정 삭제 학교 대학 학사 포털 바로가기 account university", icon: "person.2", group: "settings"),
        .init(id: "subscription", title: "구독·사용량", description: "플랜, AI 사용량, 충전", keywords: "구독 멤버십 플러스 프로 Plus Pro 결제 구매 복원 무료 체험 한도 AI 사용량 충전 크레딧 subscription usage", icon: "moon", group: "settings"),
        .init(id: "ai", title: "AI", description: "기본 모델, 전송 동의", keywords: "AI 모델 Auto Anthropic OpenAI Claude GPT effort 동의 철회 공정 이용", icon: "sparkles", group: "settings"),
        .init(id: "sync", title: "동기화", description: "iCloud · Google Drive", keywords: "동기화 iCloud 아이클라우드 Google Drive 구글 드라이브 클라우드 기기 sync", icon: "icloud", group: "settings"),
        .init(id: "integrations", title: "통합", description: "달력, 브라우저", keywords: "통합 달력 캘린더 Apple 일정 내보내기 브라우저 홈페이지 검색 엔진 확대 링크 추적 팝업 프로필 비밀번호 북마크 가져오기 사이트 권한 calendar browser", icon: "envelope", group: "settings"),
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
    static func matching(_ query: String, locale: String = "ko-KR") -> [NativeSettingsCategory] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return localized(locale).filter { item in words.allSatisfy { (item.title + " " + item.description + " " + item.keywords).localizedStandardContains($0) } }
    }
}
