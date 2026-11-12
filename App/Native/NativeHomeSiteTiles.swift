import SwiftUI
import UIKit

/// One site on the home sidebar: a school link, a site the user added, or one they visit often.
struct NativeHomeSite: Identifiable, Equatable {
    enum Source: String { case school, custom, visited }
    let id: String
    var title: String
    var url: String
    var host: String
    var source: Source
    var visits: Int
    var pinned: Bool
    var opensExternally = false
}

/// What the user changed: pins in their order, added sites, and sites they removed (by host).
struct NativeHomeSitePreferences: Equatable {
    var pinned: [String] = []
    var custom: [(id: String, title: String, url: String)] = []
    var hidden: [String] = []
    static let key = "homeSites"
    init() {}
    init(settings: [String: Any]) {
        let raw = settings[Self.key] as? [String: Any] ?? [:]
        pinned = raw["pinned"] as? [String] ?? []
        hidden = raw["hidden"] as? [String] ?? []
        custom = (raw["custom"] as? [[String: Any]] ?? []).compactMap { row in
            guard let id = row["id"] as? String, let url = row["url"] as? String else { return nil }
            return (id, row["title"] as? String ?? "", url)
        }
    }
    var json: [String: Any] {
        ["pinned": pinned, "hidden": hidden, "custom": custom.map { ["id": $0.id, "title": $0.title, "url": $0.url] }]
    }
    static func == (a: Self, b: Self) -> Bool { NSDictionary(dictionary: a.json).isEqual(to: b.json) }
}

enum NativeHomeSites {
    /// A school's essentials: its first links, before the rest earn a place by visits.
    static let schoolLimit = 4
    /// A site seen this often in the browser joins the tiles on its own.
    static let visitedThreshold = 3
    static let limit = 12
    static func host(_ url: String) -> String? {
        guard let host = URL(string: url)?.host?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
    /// Pinned sites first, in the order they were pinned; then the rest by visits. Each school link and each added
    /// site starts with one visit, so it holds its place until browsing says otherwise; ties keep the school's order.
    static func rank(school: [NativeUniversityService], preferences: NativeHomeSitePreferences, visited: [(host: String, title: String, visits: Int)]) -> [NativeHomeSite] {
        var visits: [String: Int] = [:]
        for site in visited { visits[site.host.hasPrefix("www.") ? String(site.host.dropFirst(4)) : site.host, default: 0] += site.visits }
        let hidden = Set(preferences.hidden)
        var sites: [NativeHomeSite] = []
        var hosts = Set<String>()
        func add(_ site: NativeHomeSite) {
            guard !hidden.contains(site.host), !sites.contains(where: { $0.id == site.id }) else { return }
            sites.append(site); hosts.insert(site.host)
        }
        for service in school.filter({ !$0.secondary && !$0.hidden }).prefix(schoolLimit) {
            guard let host = host(service.url) else { continue }
            add(.init(id: "school:" + service.id, title: service.label, url: service.url, host: host, source: .school,
                      visits: 1 + (visits[host] ?? 0), pinned: false, opensExternally: service.opensExternally))
        }
        for custom in preferences.custom {
            guard let host = host(custom.url) else { continue }
            add(.init(id: custom.id, title: custom.title.isEmpty ? host : custom.title, url: custom.url, host: host, source: .custom,
                      visits: 1 + (visits[host] ?? 0), pinned: false))
        }
        for site in visited {
            let host = site.host.hasPrefix("www.") ? String(site.host.dropFirst(4)) : site.host
            guard !hosts.contains(host), (visits[host] ?? 0) >= visitedThreshold else { continue }
            add(.init(id: "visited:" + host, title: site.title.isEmpty ? host : site.title, url: "https://" + site.host + "/", host: host,
                      source: .visited, visits: visits[host] ?? 0, pinned: false))
        }
        let order = Dictionary(sites.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        for index in sites.indices { sites[index].pinned = preferences.pinned.contains(sites[index].id) }
        let pinned = preferences.pinned.compactMap { id in sites.first { $0.id == id } }
        let rest = sites.filter { !$0.pinned }.sorted { $0.visits != $1.visits ? $0.visits > $1.visits : order[$0.id]! < order[$1.id]! }
        return pinned + rest.prefix(max(0, limit - pinned.count))
    }
}

/// Site icons, fetched from the site itself (never a third-party icon service) and kept on disk.
@MainActor @Observable final class NativeSiteIconCache {
    static let shared = NativeSiteIconCache()
    private(set) var images: [String: UIImage] = [:]
    private var failed: Set<String> = []
    private var loading: Set<String> = []
    private var folder: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("SiteIcons", isDirectory: true)
    }
    func load(_ host: String, store: NativeWorkspaceStore) {
        guard images[host] == nil, !failed.contains(host), !loading.contains(host) else { return }
        let file = folder?.appendingPathComponent(host + ".png")
        if let file, let data = try? Data(contentsOf: file), let image = UIImage(data: data) { images[host] = image; return }
        loading.insert(host)
        Task { @MainActor in
            defer { loading.remove(host) }
            for path in ["/apple-touch-icon.png", "/favicon.ico"] {
                guard let result = try? await store.invoke("browser:favicon", ["url": "https://" + host + path, "profileId": "default"]) as? [String: Any],
                      let dataURL = result["dataUrl"] as? String, let comma = dataURL.firstIndex(of: ","),
                      let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])), let image = UIImage(data: data) else { continue }
                images[host] = image
                if let folder, let file {
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try? data.write(to: file, options: .atomic)
                }
                return
            }
            failed.insert(host)
        }
    }
}

/// The home sidebar's sites: three across, sliding sideways for more, the last tile adds one.
/// School essentials come first; after that the browser's visits decide the order. A long press pins a site.
struct NativeHomeSiteTiles: View {
    var store: NativeWorkspaceStore
    let settings: [String: Any]
    let onOpenURL: (String) -> Void
    let onOpenSettings: (String) -> Void
    @State private var visited: [(host: String, title: String, visits: Int)] = []
    @State private var adding = false
    @State private var busy = false
    @State private var reload = 0
    private var preferences: NativeHomeSitePreferences { NativeHomeSitePreferences(settings: settings) }
    private var sites: [NativeHomeSite] {
        NativeHomeSites.rank(school: NativeUniversityCatalog.resolvedServices(settings: settings), preferences: preferences, visited: visited)
    }
    private static let spacing: CGFloat = 8, height: CGFloat = 52
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if NativeUniversityCatalog.university(settings) == nil {
                NativeSchoolPickerButton(store: store, arrowEdge: .leading) { Label("학교 고르기", systemImage: "building.columns") }
                    .buttonStyle(.plain).font(NativeDesktopTheme.font(14)).foregroundStyle(NativeDesktopTheme.secondary).frame(minHeight: 32)
                    .accessibilityIdentifier("native-university-choose")
            } else if let university = NativeUniversityCatalog.university(settings), NativeUniversityCatalog.needsLinks(settings) {
                // A school known by name only: AI finds its sites.
                NativeSchoolPickerButton(store: store, aiQuery: university["nameKo"] as? String, country: university["country"] as? String, arrowEdge: .leading) {
                    Label("AI로 학교 링크 찾기", systemImage: "sparkles")
                }.buttonStyle(.plain).font(NativeDesktopTheme.font(14, weight: .medium)).foregroundStyle(NativeDesktopTheme.accent).frame(minHeight: 32)
                    .accessibilityLabel("AI로 링크 찾기").accessibilityIdentifier("native-university-find-links")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Self.spacing) {
                    ForEach(sites) { tile($0) }
                    addTile
                }.scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .frame(height: Self.height)
            .accessibilityIdentifier("native-home-sites")
        }
        .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 12).disabled(busy)
        .task(id: reload) { await loadVisited() }
        .onReceive(store.events) { event in
            if event.channel == "browser:history-changed" || event.channel == "browser:profiles-changed" { reload &+= 1 }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in reload &+= 1 }
    }
    private func tile(_ site: NativeHomeSite) -> some View {
        Button {
            if site.opensExternally, let url = URL(string: site.url) { UIApplication.shared.open(url) } else { onOpenURL(site.url) }
        } label: {
            NativeSiteIcon(host: site.host, title: site.title, store: store)
                .frame(maxWidth: .infinity).frame(height: Self.height)
                .background(NativeGlass.selection, in: RoundedRectangle(cornerRadius: 14))
                .overlay(alignment: .topTrailing) {
                    if site.pinned { Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(NativeGlass.panelTertiary).padding(6) }
                }
                .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .containerRelativeFrame(.horizontal, count: 3, spacing: Self.spacing)
        .help(site.title)
        .accessibilityLabel(site.title + (site.pinned ? ", 고정됨" : ""))
        .accessibilityIdentifier("native-home-site-" + site.id)
        .contextMenu {
            Text(site.title)
            Button(site.pinned ? "고정 해제" : "고정", systemImage: site.pinned ? "pin.slash" : "pin") { togglePin(site) }
            Button("삭제", systemImage: "trash", role: .destructive) { remove(site) }
            if site.source == .school { Button("학교 설정", systemImage: "gearshape") { onOpenSettings("university") } }
        }
    }
    private var addTile: some View {
        Button { adding = true } label: {
            Image(systemName: "plus").font(.system(size: 18)).foregroundStyle(NativeGlass.panelIcon)
                .frame(maxWidth: .infinity).frame(height: Self.height)
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(NativeDesktopTheme.border, style: StrokeStyle(lineWidth: 1.2, dash: [4, 3])))
                .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .containerRelativeFrame(.horizontal, count: 3, spacing: Self.spacing)
        .accessibilityLabel("사이트 추가").accessibilityIdentifier("native-home-site-add")
        .bandalPopover(isPresented: $adding, arrowEdge: .leading, width: 320, radius: 20, padding: 16) {
            NativeHomeSiteAdd(suggestions: suggestions) { title, url in
                adding = false
                var next = preferences
                next.custom.append((id: "custom:" + UUID().uuidString, title: title, url: url))
                if let host = NativeHomeSites.host(url) { next.hidden.removeAll { $0 == host } }
                persist(next)
            }
        }
    }
    /// AI sites and frequently visited ones that are not tiles yet.
    private var suggestions: [(title: String, url: String)] {
        let shown = Set(sites.map(\.host))
        let ai = NativeAIWebShortcut.all.map { (title: $0.title, url: $0.url) }
        let frequent = visited.map { (title: $0.title.isEmpty ? $0.host : $0.title, url: "https://" + $0.host + "/") }
        var seen = Set<String>()
        return (ai + frequent).filter { item in
            guard let host = NativeHomeSites.host(item.url), !shown.contains(host) else { return false }
            return seen.insert(host).inserted
        }.prefix(8).map { $0 }
    }
    private func togglePin(_ site: NativeHomeSite) {
        var next = preferences
        if site.pinned { next.pinned.removeAll { $0 == site.id } } else { next.pinned.append(site.id) }
        persist(next)
    }
    private func remove(_ site: NativeHomeSite) {
        var next = preferences
        next.pinned.removeAll { $0 == site.id }
        if site.source == .custom { next.custom.removeAll { $0.id == site.id } }
        // Removed by host, so browsing it again does not bring it back.
        if site.source != .custom || site.visits > 1 { if !next.hidden.contains(site.host) { next.hidden.append(site.host) } }
        persist(next)
    }
    private func persist(_ next: NativeHomeSitePreferences) {
        guard !busy, next != preferences else { return }; busy = true
        Task { @MainActor in
            defer { busy = false }
            do { _ = try await store.invoke("settings:set", [NativeHomeSitePreferences.key: next.json]) }
            catch { store.errorMessage = error.localizedDescription }
        }
    }
    private func loadVisited() async {
        // Debounced: the browser reports every page it opens.
        if reload > 0 { try? await Task.sleep(for: .seconds(1)) }
        guard !Task.isCancelled else { return }
        guard let result = try? await store.invoke("browser:topSites", ["profileId": "default", "limit": 40]) as? [String: Any] else { return }
        visited = (result["sites"] as? [[String: Any]] ?? []).compactMap { row in
            guard let host = row["host"] as? String else { return nil }
            return (host, row["title"] as? String ?? "", (row["visitCount"] as? NSNumber)?.intValue ?? 0)
        }
    }
}

/// The site's own icon, or its initial on a tinted square while there is none.
private struct NativeSiteIcon: View {
    let host: String
    let title: String
    var store: NativeWorkspaceStore
    private var cache: NativeSiteIconCache { .shared }
    var body: some View {
        Group {
            if let image = cache.images[host] {
                Image(uiImage: image).resizable().interpolation(.high).scaledToFit().frame(width: 24, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            } else {
                Text(String((title.first ?? host.first ?? "?")).uppercased()).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(NativeDesktopTheme.onAccent).frame(width: 24, height: 24)
                    .background(NativeDesktopTheme.accent.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .onAppear { cache.load(host, store: store) }
        .accessibilityHidden(true)
    }
}

/// Adds a site: an address and an optional name, or one of the suggestions.
private struct NativeHomeSiteAdd: View {
    let suggestions: [(title: String, url: String)]
    let add: (String, String) -> Void
    @State private var address = ""
    @State private var name = ""
    @FocusState private var focused: Bool
    private var url: String? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        return NativeSettingsSchema.webURL(candidate) && NativeHomeSites.host(candidate)?.contains(".") == true ? candidate : nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("사이트 추가").font(NativeDesktopTheme.font(15, weight: .semibold))
            TextField("주소 (예: chatgpt.com)", text: $address).textFieldStyle(.roundedBorder).keyboardType(.URL)
                .textInputAutocapitalization(.never).autocorrectionDisabled().focused($focused).onSubmit(submit)
                .accessibilityIdentifier("native-home-site-url")
            TextField("이름 (선택)", text: $name).textFieldStyle(.roundedBorder).onSubmit(submit)
                .accessibilityIdentifier("native-home-site-name")
            HStack {
                Spacer()
                Button("추가", action: submit).buttonStyle(.borderedProminent).disabled(url == nil).accessibilityIdentifier("native-home-site-submit")
            }
            if !suggestions.isEmpty {
                Text("추천").font(NativeDesktopTheme.font(12, weight: .medium)).foregroundStyle(NativeDesktopTheme.secondary)
                ForEach(suggestions.indices, id: \.self) { index in
                    let item = suggestions[index]
                    Button { add(item.title, item.url) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "plus.circle").foregroundStyle(NativeDesktopTheme.accent)
                            Text(item.title).font(NativeDesktopTheme.font(14)).lineLimit(1)
                            Spacer(minLength: 0)
                            Text(NativeHomeSites.host(item.url) ?? "").font(NativeDesktopTheme.font(11)).foregroundStyle(NativeDesktopTheme.muted).lineLimit(1)
                        }.frame(minHeight: 32).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
        }
        .onAppear { focused = true }
    }
    private func submit() {
        guard let url else { return }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        add(title.isEmpty ? (NativeHomeSites.host(url) ?? url) : title, url)
    }
}
