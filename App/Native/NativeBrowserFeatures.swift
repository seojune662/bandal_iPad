import Foundation

@MainActor
extension NativeBrowserSession {
    var activeProfileName: String { profiles.first { $0["id"] == active?.profileID }?["name"] ?? "기본" }
    var defaultZoom: Double { ((preferences["browser"] as? [String: Any])?["defaultZoomLevel"] as? NSNumber)?.doubleValue ?? 0 }
    var zoomLevel: Double { activeID.flatMap { zoomLevels[$0] } ?? defaultZoom }
    var zoomPercent: Int { Int((pow(1.2, zoomLevel) * 100).rounded()) }
    var findState: NativeBrowserFindState { activeID.flatMap { findStates[$0] } ?? .init() }
    var favoriteLinks: [NativeBrowserLink] {
        var seen = Set<String>()
        return favorites.compactMap { favorite in
            guard favorite.kind == "browser", (favorite.payload["profileId"] as? String ?? "default") == (active?.profileID ?? "default"),
                  let url = favorite.payload["initialUrl"] as? String, seen.insert(NativeBrowserAddress.canonical(url)).inserted else { return nil }
            return NativeBrowserLink(title: NativeBrowserAddress.title(favorite.label, url: url), url: url)
        }
    }
    var schoolLinks: [NativeBrowserLink] { NativeUniversityCatalog.resolvedServices(settings: preferences).map { .init(title: $0.label, url: $0.url) } }
    var activeFavorite: NativeSidebarFavorite? {
        guard let active, !active.isPrivate else { return nil }
        return favorites.first { $0.kind == "browser" && ($0.payload["profileId"] as? String ?? "default") == active.profileID && ($0.payload["initialUrl"] as? String).map(NativeBrowserAddress.canonical) == NativeBrowserAddress.canonical(active.url) }
    }
    var visibleDownloads: [NativeBrowserDownloadItem] {
        guard let active else { return [] }
        return downloadItems.filter { item in
            item.profileID == active.profileID && item.isPrivate == active.isPrivate && (!item.isPrivate || item.tabID.map(owns) == true)
        }
    }
    func reloadProfiles() async throws {
        let request = UUID(); profileRequest = request
        let result = try await host.handle(channel: "browser:profiles", request: [:]) as? [[String: String]] ?? []
        guard !retired, profileRequest == request else { return }
        profiles = result
    }
    func reloadFeatures() async {
        do { try await reloadFavorites(); try await reloadDownloads() }
        catch { if !retired { self.error = error.localizedDescription } }
    }
    func reloadFavorites() async throws {
        let request = UUID(); favoriteRequest = request
        let course = effectiveCourseID
        var rows: [[String: Any]] = []
        if let course { rows += try await store.invoke("favorites:list", ["courseId": course]) as? [[String: Any]] ?? [] }
        rows += try await store.invoke("favorites:list", ["courseId": NSNull()]) as? [[String: Any]] ?? []
        guard !retired, favoriteRequest == request else { return }
        favorites = rows.compactMap(NativeSidebarFavorite.init)
    }
    func toggleFavorite() async throws {
        guard let active, !active.isPrivate, let url = URL(string: active.url), ["http", "https"].contains(url.scheme ?? "") else { return }
        if let favorite = activeFavorite { _ = try await store.invoke("favorites:remove", ["id": favorite.id]) }
        else {
            _ = try await store.invoke("favorites:add", ["courseId": effectiveCourseID as Any? ?? NSNull(), "label": NativeBrowserAddress.title(active.title, url: active.url),
                "descriptor": ["kind": "browser", "payload": ["initialUrl": active.url, "profileId": active.profileID]]])
        }
        try await reloadFavorites()
        store.events.send(.init(channel: "nativeWorkspace:favoritesChanged", payload: ["courseId": effectiveCourseID as Any? ?? NSNull()]))
    }
    func suggestions(_ query: String, history: [NativeBrowserLink]) -> [NativeBrowserSuggestion] {
        let current = active
        let links = tabs.filter { !$0.isPrivate && $0.profileID == current?.profileID }.map { NativeBrowserLink(title: $0.title, url: $0.url) }
        return NativeBrowserAddress.suggestions(query, engine: preferences["browserSearchEngine"] as? String ?? "google", tabs: links,
            favorites: favoriteLinks, services: schoolLinks, history: current?.isPrivate == true ? [] : history)
    }
    func searchHistory(_ query: String, profileID: String? = nil) async throws -> [NativeBrowserLink] {
        guard active?.isPrivate != true else { return [] }
        let result = try await host.handle(channel: "browser:searchHistory", request: ["profileId": profileID ?? active?.profileID ?? "default", "query": query, "limit": 100]) as? [String: Any]
        return (result?["entries"] as? [[String: Any]] ?? []).compactMap { row in
            guard let url = row["url"] as? String else { return nil }; return .init(title: row["title"] as? String ?? "", url: url)
        }
    }
    func home() async throws {
        let home = (preferences["browser"] as? [String: Any])?["homePage"] as? String ?? ""
        try await navigate(home.isEmpty ? "about:blank" : home)
    }
    func zoom(_ direction: Int?) async throws {
        try await action("setZoomLevel", args: [direction.map { min(8, max(-8, zoomLevel + Double($0))) } ?? defaultZoom])
    }
    func switchSession(profileID: String, isPrivate: Bool) async throws {
        guard !sessionChanging, !retired, let id = activeID, let page = host.pages[id] else { return }
        sessionChanging = true; defer { sessionChanging = false }
        let result = try await host.handle(channel: "browser:switchPageSession", request: ["tabId": id, "profileId": profileID, "isPrivate": isPrivate, "expectedWebContentsId": page.id]) as? [String: Any]
        guard !retired, result?["allowed"] as? Bool == true else { return }
        findTasks[id]?.cancel(); findStates[id] = nil
        refresh(id); try save()
        try await reloadFavorites()
        #if DEBUG
        await loadUITestFixture(id: id)
        #endif
    }
    func setFindVisible(_ visible: Bool) {
        guard let id = activeID else { return }
        var state = findStates[id] ?? .init()
        let reopening = visible && !state.visible
        state.visible = visible
        if visible { state.focusRevision &+= 1 }
        else { state.count = nil; state.ordinal = 0; state.searchedQuery = nil }
        findStates[id] = state
        if !visible {
            findTasks[id]?.cancel(); findTasks[id] = nil
            Task { try? await action("stopFindInPage", tabID: id) }
        } else if reopening && !state.query.isEmpty {
            // The close action removed WebKit's highlight state. Opening the
            // existing query must search the current DOM before showing counts.
            setFindQuery(state.query)
        }
    }
    func setFindQuery(_ query: String) {
        guard let id = activeID else { return }
        var state = findStates[id] ?? .init(); state.query = query; state.count = nil; state.ordinal = 0; state.searchedQuery = nil; findStates[id] = state
        findTasks[id]?.cancel()
        findTasks[id] = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(120)); try Task.checkCancellation()
                guard let self, self.findStates[id]?.query == query else { return }
                try await self.searchPage(id: id, forward: true, advance: false)
            } catch is CancellationError {} catch { self?.error = error.localizedDescription }
        }
    }
    func stepFind(forward: Bool) async throws {
        guard let id = activeID else { return }
        findTasks[id]?.cancel(); findTasks[id] = nil
        try await searchPage(id: id, forward: forward, advance: true)
    }
    private func searchPage(id: String, forward: Bool, advance: Bool) async throws {
        guard let state = findStates[id], state.visible, !retired else { return }
        if state.query.isEmpty { try await action("stopFindInPage", tabID: id); return }
        findStates[id]?.searchedQuery = state.query
        try await action("findInPage", args: [state.query, ["forward": forward, "findNext": advance && state.searchedQuery == state.query]], tabID: id)
    }
    func reloadDownloads() async throws {
        let rows = try await host.handle(channel: "browser:downloadsSnapshot", request: [:]) as? [[String: Any]] ?? []
        guard !retired else { return }; downloadItems = rows.compactMap(NativeBrowserDownloadItem.init).sorted { $0.id < $1.id }
    }
    func downloadAction(_ snapshot: NativeBrowserDownloadItem, action: String) async throws {
        // The automatic material import can finish while a sheet dismisses.
        // Resolve by identity instead of routing with the earlier row snapshot.
        guard let item = visibleDownloads.first(where: { $0.id == snapshot.id }) else { return }
        if action == "open", let course = item.courseID, let path = item.relativePath {
            store.events.send(.init(channel: "nativeWorkspace:openDocument", payload: ["courseId": course, "relPath": path, "title": (path as NSString).lastPathComponent, "kind": NativeSidebarDescriptor.materialKind(path)]))
        } else {
            let channel = action == "dismiss" ? "browser:dismissDownload" : ["pause", "resume", "cancel"].contains(action) ? "browser:controlDownload" : "browser:downloadFile"
            _ = try await host.handle(channel: channel, request: ["id": item.id, "action": action])
        }
        try await reloadDownloads()
    }
    func receiveFeatureEvent(_ event: NativeWorkspaceEvent) {
        if event.channel == "browser:profiles-changed" {
            Task { do { try await reloadProfiles() } catch { if !retired { self.error = error.localizedDescription } } }; return
        }
        if event.channel == "browser:search-selection", let value = event.payload as? [String: Any],
           let id = value["tabId"] as? String, owns(id), let source = tabs.first(where: { $0.id == id }), let text = value["text"] as? String {
            Task {
                do {
                    let url = try Self.addressURL(text, searchEngine: preferences["browserSearchEngine"] as? String ?? "google")
                    let createdID = try await add(profileID: source.profileID, isPrivate: source.isPrivate)
                    try await action("loadURL", args: [url.absoluteString], tabID: createdID)
                } catch { self.error = error.localizedDescription }
            }; return
        }
        if event.channel == "browser:popup-blocked", let value = event.payload as? [String: Any],
           let id = value["tabId"] as? String, owns(id) { error = value["reason"] as? String ?? "팝업을 열 수 없습니다."; return }
        if event.channel == "browser:context-action-failed", let value = event.payload as? [String: Any],
           let id = value["tabId"] as? String, owns(id) { error = value["message"] as? String; return }
        if ["nativeWorkspace:favoritesChanged", "favorites:changed"].contains(event.channel) {
            Task { do { try await reloadFavorites() } catch { self.error = error.localizedDescription } }; return
        }
        if event.channel == "browser:download", let value = event.payload as? [String: Any], let item = NativeBrowserDownloadItem(value) {
            if let index = downloadItems.firstIndex(where: { $0.id == item.id }) { downloadItems[index] = item } else { downloadItems.insert(item, at: 0) }; return
        }
        guard event.channel == "browser:page-event", let value = event.payload as? [String: Any], let id = value["tabId"] as? String, owns(id) else { return }
        let name = value["name"] as? String
        if name == "found-in-page", let result = (value["detail"] as? [String: Any])?["result"] as? [String: Any],
           let query = result["query"] as? String, findStates[id]?.visible == true, findStates[id]?.query == query {
            findStates[id]?.count = (result["matches"] as? NSNumber)?.intValue ?? 0
            findStates[id]?.ordinal = (result["activeMatchOrdinal"] as? NSNumber)?.intValue ?? 0
        }
        if name == "did-start-navigation" || name == "did-start-loading" { findTasks[id]?.cancel(); findStates[id] = nil }
    }
}
