import SwiftUI

struct NativeAccountView: View {
    @ObservedObject var store: NativeWorkspaceStore
    var body: some View { NativeSettingsWorkspace(store: store, initialCategory: "account") }
}

struct NativeHelpView: View {
    @State private var shortcuts = false
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—" }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("도움말").font(.system(size: 26, weight: .medium))
                Text("반달에서 읽고, 기록하고, 연결하세요.").foregroundStyle(NativeDesktopTheme.secondary)
                NativeSettingsCard(title: "시작하기", description: "자료와 생각을 한 작업 공간에서 이어갑니다.") {
                    VStack(alignment: .leading, spacing: 14) {
                        Label("과목을 만들고 오른쪽 자료 목록에서 파일을 가져오세요.", systemImage: "folder.badge.plus")
                        Label("탭 옆 +에서 브라우저, 노트, 마크다운, AI, 녹음을 여세요.", systemImage: "plus")
                        Label("탭을 끌어 나누거나 화면 배치 메뉴로 여러 자료를 함께 보세요.", systemImage: "rectangle.split.2x1")
                        Label("PDF와 노트에는 Apple Pencil로 필기할 수 있습니다.", systemImage: "pencil.tip")
                    }.font(.system(size: 13))
                }
                NativeSettingsCard(title: "도움말과 지원", description: "공식 문서와 변경 사항을 확인하세요.") {
                    VStack(alignment: .leading, spacing: 16) {
                        Button("키보드 단축키", systemImage: "keyboard") { shortcuts = true }
                        Link(destination: URL(string: "https://bandal.io/ko/docs")!) { Label("사용 안내", systemImage: "book") }
                        Link(destination: URL(string: "https://bandal.io/ko/changelog")!) { Label("업데이트 내역", systemImage: "clock.arrow.circlepath") }
                        Link(destination: URL(string: "https://github.com/seojune662/bandal/issues")!) { Label("문제 제보 · 기능 제안", systemImage: "bubble.left") }
                    }.buttonStyle(.plain)
                }
                Text("반달 \(version)").font(.system(size: 12)).foregroundStyle(NativeDesktopTheme.muted)
            }.padding(32).frame(maxWidth: 820, alignment: .leading).frame(maxWidth: .infinity, alignment: .topLeading)
        }.background(NativeDesktopTheme.bgApp)
            .sheet(isPresented: $shortcuts) {
                NavigationStack {
                    List(NativeBrowserShortcuts.specs) { item in
                        HStack { Text(item.label); Spacer(); Text(item.chord.replacingOccurrences(of: "mod+", with: "⌘").replacingOccurrences(of: "alt+", with: "⌥").replacingOccurrences(of: "shift+", with: "⇧").uppercased()).foregroundStyle(.secondary) }
                    }.navigationTitle("기본 단축키").toolbar { ToolbarItem(placement: .confirmationAction) { Button("완료") { shortcuts = false } } }
                }
            }
    }
}

@MainActor
final class NativeMarketplaceModel: ObservableObject {
    @Published var context: [String: Any] = [:]
    @Published var dashboard: [String: Any] = [:]
    @Published var courses: [[String: Any]] = []
    @Published var listings: [[String: Any]] = []
    @Published var schoolID = ""
    @Published var courseID = ""
    @Published var query = ""
    @Published var sort = "newest"
    @Published var error: String?
    @Published var loading = false
    @Published var nextCursor: String?
    @Published var signedIn = false
    private var generation = 0
    private var loadedSchoolID: String?
    private let store: NativeWorkspaceStore
    init(store: NativeWorkspaceStore) { self.store = store }
    var universities: [[String: Any]] { context["universities"] as? [[String: Any]] ?? [] }
    var configured: Bool { context["configured"] as? Bool == true }
    var filterKey: String { [schoolID, courseID, query, sort].joined(separator: "\n") }
    func request(_ action: String, _ input: [String: Any] = [:]) async throws -> Any {
        try await store.invokePrivate("studyMarket:request", ["action": action, "input": input])
    }
    func reload() async {
        generation += 1; let version = generation
        loading = true; error = nil; dashboard = [:]; loadedSchoolID = nil
        defer { if version == generation { loading = false } }
        do {
            let auth = try await store.invoke("auth:getState") as? [String: Any] ?? [:]
            let result = try await request("context") as? [String: Any] ?? [:]
            try Task.checkCancellation(); guard version == generation else { return }
            context = result; signedIn = auth["phase"] as? String == "signed-in"
            if !universities.contains(where: { $0["id"] as? String == schoolID }) {
                let settings = (try? await store.invoke("settings:get")) as? [String: Any] ?? [:]
                let preferred = (settings["university"] as? [String: Any])?["universityId"] as? String
                schoolID = universities.first(where: { $0["id"] as? String == preferred })?["id"] as? String ?? ""
            }
            if signedIn {
                let value = try await request("dashboard") as? [String: Any] ?? [:]
                try Task.checkCancellation(); guard version == generation else { return }; dashboard = value
            }
            await loadListings()
        } catch is CancellationError { }
        catch { if version == generation { self.error = error.localizedDescription } }
    }
    func loadListings(more: Bool = false) async {
        guard configured, !schoolID.isEmpty else { listings = []; courses = []; nextCursor = nil; return }
        let key = filterKey, version = generation, school = schoolID
        if !more { listings = []; nextCursor = nil }
        loading = true; error = nil
        defer { if key == filterKey && version == generation { loading = false } }
        do {
            if !more && loadedSchoolID != school {
                let schoolContext = try await request("context", ["universityId": school]) as? [String: Any] ?? [:]
                let values = try await request("courses", ["universityId": school]) as? [[String: Any]] ?? []
                try Task.checkCancellation(); guard key == filterKey && version == generation else { return }; courses = values; context = schoolContext; loadedSchoolID = school
            }
            var input: [String: Any] = ["universityId": school, "q": query.trimmingCharacters(in: .whitespacesAndNewlines), "sort": sort]
            if !courseID.isEmpty { input["courseIds"] = [courseID] }
            if more, let nextCursor { input["cursor"] = nextCursor }
            let value = try await request("listings", input) as? [String: Any] ?? [:]
            try Task.checkCancellation(); guard key == filterKey && version == generation else { return }
            let rows = value["listings"] as? [[String: Any]] ?? []
            if more { let existing = Set(listings.compactMap { $0["id"] as? String }); listings += rows.filter { !existing.contains($0["id"] as? String ?? "") } } else { listings = rows }
            nextCursor = value["nextCursor"] as? String
        } catch is CancellationError { }
        catch { if key == filterKey && version == generation { self.error = error.localizedDescription } }
    }
}

struct NativeMarketplaceView: View {
    @ObservedObject var store: NativeWorkspaceStore
    @StateObject private var model: NativeMarketplaceModel
    @State private var tab = "browse"
    @State private var showingAccount = false
    @State private var detail: MarketDetail?
    private struct MarketDetail: Identifiable { let id: String; let row: [String: Any] }
    init(store: NativeWorkspaceStore) { self.store = store; _model = StateObject(wrappedValue: NativeMarketplaceModel(store: store)) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                HStack(spacing: 24) {
                    ForEach([("browse", "둘러보기"), ("purchases", "구매한 자료"), ("sales", "판매 관리")], id: \.0) { id, label in
                        Button { tab = id } label: {
                            Text(label).font(.system(size: 14, weight: tab == id ? .semibold : .regular)).padding(.vertical, 12)
                                .overlay(alignment: .bottom) { (tab == id ? NativeDesktopTheme.accent : .clear).frame(height: 2) }
                        }.buttonStyle(.plain).accessibilityIdentifier("native-market-" + id)
                    }
                    Spacer()
                    Button { Task { await model.reload() } } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("마켓 새로고침")
                }.overlay(alignment: .bottom) { NativeDesktopTheme.border.frame(height: 1) }
                if let error = model.error { NativeToolError(message: error) }
                if let notice = model.context["notice"] as? String, !notice.isEmpty { Text(notice).foregroundStyle(NativeDesktopTheme.secondary).font(.system(size: 13)).padding(14).frame(maxWidth: .infinity, alignment: .leading).background(NativeDesktopTheme.raised, in: RoundedRectangle(cornerRadius: 8)) }
                if model.loading { ProgressView().frame(maxWidth: .infinity) }
                if tab == "browse" { browse }
                else if !model.signedIn { empty("로그인하고 내 자료를 확인하세요", description: "구매한 자료와 판매 내역은 계정에 보관됩니다."); Button("로그인") { showingAccount = true }.buttonStyle(.borderedProminent) }
                else if tab == "purchases" { purchases }
                else { sales }
                Text("iPad에서는 자료와 구매·판매 내역을 조회할 수 있습니다. 구매, 판매 등록, 환불, 구매 자료 가져오기는 아직 지원하지 않습니다.")
                    .font(.system(size: 12)).foregroundStyle(NativeDesktopTheme.muted).fixedSize(horizontal: false, vertical: true)
            }.padding(32).frame(maxWidth: 1100, alignment: .leading).frame(maxWidth: .infinity, alignment: .topLeading)
        }.background(NativeDesktopTheme.bgApp)
            .task { await model.reload() }
            .task(id: model.filterKey) {
                do { if !model.query.isEmpty { try await Task.sleep(for: .milliseconds(220)) }; try Task.checkCancellation(); await model.loadListings() } catch { }
            }
            .onChange(of: model.schoolID) { _, _ in model.courseID = "" }
            .onReceive(store.events) { if $0.channel == "auth:changed" { Task { await model.reload() } } }
            .sheet(isPresented: $showingAccount) { NativeAccountView(store: store) }
            .sheet(item: $detail) { item in detailView(item.row) }
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Menu {
                ForEach(model.universities.compactMap { row -> MarketSchool? in guard let id = row["id"] as? String, let name = row["name"] as? String else { return nil }; return MarketSchool(id: id, name: name) }) { school in Button(school.name) { model.schoolID = school.id } }
            } label: { HStack { Text(model.universities.first(where: { $0["id"] as? String == model.schoolID })?["name"] as? String ?? "대학교 선택"); Image(systemName: "chevron.down") }.font(.system(size: 13)) }
                .disabled(model.universities.isEmpty).accessibilityIdentifier("native-market-school")
            Text("마켓플레이스").font(.system(size: 28, weight: .semibold))
            Text("나의 공부가 누군가의 다음 공부가 되는 곳.").foregroundStyle(NativeDesktopTheme.secondary)
        }
    }
    private struct MarketSchool: Identifiable { let id: String; let name: String }
    @ViewBuilder private var browse: some View {
        if !model.configured && !model.loading { empty("마켓플레이스 연결을 준비하고 있어요", description: "연결 가능한 학교와 자료는 서버에서 확인한 뒤 표시합니다.") }
        else if model.schoolID.isEmpty { empty("대학교를 선택해 주세요", description: "같은 학교 학생들의 공부 자료를 만나보세요.") }
        else {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(NativeDesktopTheme.muted)
                TextField("어떤 과목의 자료를 찾나요?", text: $model.query).textFieldStyle(.plain).accessibilityIdentifier("native-market-search")
                Picker("자료 정렬", selection: $model.sort) { Text("최신순").tag("newest"); Text("낮은 가격순").tag("price") }.labelsHidden()
            }.padding(12).background(NativeDesktopTheme.raised, in: RoundedRectangle(cornerRadius: 8))
            Picker("과목 선택", selection: $model.courseID) {
                Text("전체 과목").tag("")
                ForEach(model.courses.compactMap { row -> MarketSchool? in guard let id = row["id"] as? String, let name = row["name"] as? String else { return nil }; return MarketSchool(id: id, name: name) }) { course in Text(course.name).tag(course.id) }
            }.pickerStyle(.menu)
            if model.listings.isEmpty && !model.loading { empty("아직 등록된 자료가 없어요", description: "다른 과목을 선택하거나 검색어를 바꿔 보세요.") }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16)], spacing: 16) {
                ForEach(Array(model.listings.enumerated()), id: \.offset) { _, row in
                    Button { detail = .init(id: row["id"] as? String ?? UUID().uuidString, row: row) } label: { listingCard(row) }.buttonStyle(.plain)
                }
            }
            if model.nextCursor != nil { Button("더 보기") { Task { await model.loadListings(more: true) } }.disabled(model.loading).frame(maxWidth: .infinity) }
        }
    }
    private func listingCard(_ row: [String: Any]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "doc.richtext").font(.system(size: 36, weight: .light)).foregroundStyle(NativeDesktopTheme.muted).frame(maxWidth: .infinity).frame(height: 116).background(NativeDesktopTheme.raised)
            Text((row["course"] as? [String: Any])?["name"] as? String ?? "").font(.system(size: 11)).foregroundStyle(NativeDesktopTheme.muted)
            Text(row["title"] as? String ?? "자료").font(.system(size: 15, weight: .medium)).lineLimit(2)
            Text(row["sellerName"] as? String ?? "").font(.system(size: 12)).foregroundStyle(NativeDesktopTheme.muted)
            Text(won(row["price"])).font(.system(size: 16, weight: .semibold))
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(NativeDesktopTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(NativeDesktopTheme.border, lineWidth: 1))
    }
    @ViewBuilder private var purchases: some View {
        let rows = model.dashboard["purchases"] as? [[String: Any]] ?? []
        if rows.isEmpty && !model.loading { empty("구매한 자료가 없어요", description: "자료를 구매하면 이곳에서 내역을 확인할 수 있습니다.") }
        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
            HStack { VStack(alignment: .leading, spacing: 6) { Text(row["courseName"] as? String ?? "").font(.caption).foregroundStyle(NativeDesktopTheme.muted); Text(row["title"] as? String ?? "자료"); Text(won(row["amount"])).font(.subheadline) }; Spacer(); Text(["pending": "결제 대기", "paid": "구매 완료", "refund_pending": "환불 처리 중", "refunded": "환불 완료", "failed": "결제 실패", "cancelled": "결제 취소"][row["status"] as? String ?? ""] ?? "상태 확인 필요").font(.caption) }.padding(16).background(NativeDesktopTheme.raised, in: RoundedRectangle(cornerRadius: 8))
        }
    }
    @ViewBuilder private var sales: some View {
        let seller = model.dashboard["seller"] as? [String: Any] ?? [:]
        Text(["unregistered": "판매자 미등록", "pending": "본인인증 확인 중", "ready": "판매 가능", "verification_required": "본인인증 필요", "suspended": "판매 일시 중지"][seller["status"] as? String ?? ""] ?? "판매 상태 확인 중").font(.headline)
        if let reason = seller["reason"] as? String, !reason.isEmpty { Text(reason).font(.subheadline) }
        if !model.dashboard.isEmpty {
            HStack(spacing: 32) { total("판매 건수", "\((model.dashboard["salesCount"] as? NSNumber)?.intValue ?? 0)건"); total("지급 대기", won(model.dashboard["pendingAmount"])); total("지급 완료", won(model.dashboard["paidAmount"])) }
        }
        let rows = model.dashboard["listings"] as? [[String: Any]] ?? []
        if rows.isEmpty && !model.loading { empty("등록한 판매 자료가 없어요", description: "데스크톱에서 등록한 자료와 판매 내역을 이곳에서 확인할 수 있습니다.") }
        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in Button { detail = .init(id: row["id"] as? String ?? UUID().uuidString, row: row) } label: { listingCard(row) }.buttonStyle(.plain) }
    }
    private func total(_ title: String, _ value: String) -> some View { VStack(alignment: .leading, spacing: 6) { Text(title).font(.caption).foregroundStyle(NativeDesktopTheme.muted); Text(value).font(.title3.weight(.semibold)) } }
    private func won(_ value: Any?) -> String { guard let number = value as? NSNumber else { return "—" }; return number.intValue.formatted(.number.locale(Locale(identifier: "ko-KR"))) + "원" }
    private func empty(_ title: String, description: String) -> some View { VStack(spacing: 12) { Image(systemName: "books.vertical").font(.system(size: 34, weight: .light)); Text(title).font(.headline); Text(description).font(.subheadline).multilineTextAlignment(.center) }.foregroundStyle(NativeDesktopTheme.secondary).frame(maxWidth: .infinity).padding(.vertical, 44) }
    private func detailView(_ row: [String: Any]) -> some View {
        NavigationStack {
            ScrollView { VStack(alignment: .leading, spacing: 16) { listingCard(row); Text(row["description"] as? String ?? ""); if let files = row["files"] as? [[String: Any]] { ForEach(Array(files.enumerated()), id: \.offset) { _, file in Label(file["path"] as? String ?? "파일", systemImage: "doc") } }; Text("구매와 판매 등록은 iPad에서 아직 지원하지 않습니다.").font(.footnote).foregroundStyle(.secondary) }.padding(24) }
                .navigationTitle("자료 정보").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .confirmationAction) { Button("완료") { detail = nil } } }
        }
    }
}
