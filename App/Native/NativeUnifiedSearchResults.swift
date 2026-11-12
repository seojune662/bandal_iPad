import SwiftUI

struct NativeUnifiedSearchResponse: Decodable {
    struct Section: Decodable, Identifiable { let id: String; let groups: [Group] }
    struct Workspace: Decodable { let kind: String?; let id: String?; let rootRelPath: String? }
    /// A file with its matching pages, or a conversation with its matching messages.
    struct Group: Decodable, Identifiable {
        let courseId: String, courseName: String
        let relPath: String?, kind: String?
        let sessionId: String?, title: String?, workspace: Workspace?
        let hits: [Hit]
        var id: String { courseId + "\n" + (relPath ?? sessionId ?? "") }
        /// A markdown note reads as a note, without its extension, as in the file list.
        var name: String {
            guard let relPath else { return title ?? "" }
            let name = (relPath as NSString).lastPathComponent
            return name.hasSuffix(".md") ? String(name.dropLast(3)) : name
        }
    }
    struct Hit: Decodable, Identifiable {
        let snippet: String
        let page: Int?
        let box: [Double]?
        let messageId: String?
        var id: String { (messageId ?? "") + ":\(page ?? 0):" + (box.map { "\($0)" } ?? "") + snippet }
    }
    let capped: Bool
    let handwritingIndexing: Bool?
    let sections: [Section]
    var isEmpty: Bool { sections.allSatisfy(\.groups.isEmpty) }
}

/// The results of the files panel's search field, listed in the panel itself: 자료, 손글씨, 대화.
struct NativeUnifiedSearchResults: View {
    var store: NativeWorkspaceStore
    /// Trimmed, two characters or more.
    let query: String
    let scope: NativeWorkspaceContext?
    /// 이 폴더만. The chip itself sits in the panel's title row, clear of the floating pen palette.
    let courseOnly: Bool
    static let debounce = Duration.milliseconds(300), sectionPreview = 5
    @State private var response: NativeUnifiedSearchResponse?
    @State private var answered = ""
    @State private var failure: String?
    @State private var revision = 0
    @State private var allShown = Set<String>()
    @State private var opened = Set<String>()
    @Environment(\.locale) private var locale

    private var courseID: String? { scope?.courseID ?? store.selectedCourseID }
    private var taskID: String { "\(query)\n\(courseID ?? "")\n\(courseOnly)\n\(revision)" }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if response?.handwritingIndexing == true {
                    Text("손글씨 색인 중이라 일부 결과가 빠질 수 있어요").font(.system(size: 11)).foregroundStyle(NativeDesktopTheme.muted)
                        .padding(.horizontal, 6).padding(.bottom, 6).accessibilityIdentifier("native-search-indexing")
                }
                if let failure { Text(failure).font(.system(size: 12)).foregroundStyle(NativeDesktopTheme.muted).padding(6) }
                else {
                    // While a new query is on its way the previous results stay, dimmed, under a spinner.
                    if answered != query { ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(8).accessibilityIdentifier("native-search-loading") }
                    if let response {
                        if response.isEmpty && answered == query { Text("결과 없음").font(.system(size: 12)).foregroundStyle(NativeDesktopTheme.muted).padding(6).accessibilityIdentifier("native-search-empty") }
                        ForEach(response.sections) { section in if !section.groups.isEmpty { self.section(section) } }
                            .opacity(answered == query ? 1 : 0.45)
                    }
                }
            }.padding(.horizontal, 6).padding(.bottom, 16)
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("native-search-results")
        .task(id: taskID) { await search() }
        .onReceive(store.events) { event in
            // Text extracted or handwriting read while the results are open.
            if ["search:changed", "materials:changed"].contains(event.channel) { revision += 1 }
            else if event.channel == "handwriting:progress", (event.payload as? [String: Any])?["active"] as? Bool != (response?.handwritingIndexing ?? false) { revision += 1 }
        }
    }

    private func title(_ id: String) -> String { id == "material" ? "자료" : id == "handwriting" ? "손글씨" : "대화" }
    @ViewBuilder private func section(_ section: NativeUnifiedSearchResponse.Section) -> some View {
        let all = allShown.contains(section.id), groups = all ? section.groups : Array(section.groups.prefix(Self.sectionPreview))
        HStack(spacing: 6) {
            Text(NativeAppLocale.string(title(section.id), locale)).font(.system(size: 11)).foregroundStyle(NativeGlass.panelTertiary)
            Text(verbatim: String(section.groups.count)).font(.system(size: 11).monospacedDigit()).foregroundStyle(NativeDesktopTheme.muted)
        }.padding(.horizontal, 6).frame(height: 30).accessibilityAddTraits(.isHeader).accessibilityIdentifier("native-search-section-" + section.id)
        ForEach(groups) { group in self.group(group, section: section.id) }
        if section.groups.count > Self.sectionPreview, !all {
            Button { allShown.insert(section.id) } label: {
                Text("더 보기").font(.system(size: 12, weight: .medium)).foregroundStyle(NativeDesktopTheme.secondary)
                    .padding(.horizontal, 6).frame(maxWidth: .infinity, minHeight: 36, alignment: .leading).contentShape(Rectangle())
            }.accessibilityIdentifier("native-search-more-" + section.id)
        }
    }

    @ViewBuilder private func group(_ group: NativeUnifiedSearchResponse.Group, section: String) -> some View {
        let key = section + "\n" + group.id, expanded = opened.contains(key), several = group.hits.count > 1
        Button { if several { if expanded { opened.remove(key) } else { opened.insert(key) } } else { open(group, hit: group.hits.first, section: section) } } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: section == "chat" ? "bubble.left" : group.kind == "pdf" ? "doc" : "doc.text")
                    .font(.system(size: 15)).foregroundStyle(NativeDesktopTheme.secondary).frame(width: 17).padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(verbatim: group.name).font(.system(size: 14)).foregroundStyle(NativeDesktopTheme.text).lineLimit(1)
                        if section == "handwriting" { tag("손글씨") }
                        Spacer(minLength: 0)
                        if several {
                            Text("\(group.hits.count)곳").font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(NativeDesktopTheme.secondary)
                                .padding(.horizontal, 6).frame(height: 18).background(NativeDesktopTheme.raised, in: Capsule())
                            Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9)).foregroundStyle(NativeGlass.panelIcon)
                        }
                    }
                    Text(verbatim: ([group.courseName] + (several ? [] : [group.hits.first?.page.map { "p.\($0)" }].compactMap { $0 })).joined(separator: " · "))
                        .font(.system(size: 11)).foregroundStyle(NativeDesktopTheme.muted).lineLimit(1)
                    if !several, let hit = group.hits.first { snippet(hit.snippet) }
                }
            }.padding(.horizontal, 6).padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .accessibilityIdentifier("native-search-" + section + "-" + (group.relPath ?? group.sessionId ?? ""))
        if several, expanded {
            ForEach(group.hits) { hit in
                Button { open(group, hit: hit, section: section) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if let page = hit.page { Text(verbatim: "p.\(page)").font(.system(size: 11).monospacedDigit()).foregroundStyle(NativeDesktopTheme.secondary).frame(minWidth: 30, alignment: .leading) }
                        snippet(hit.snippet)
                    }.padding(.leading, 33).padding(.trailing, 6).frame(maxWidth: .infinity, minHeight: 34, alignment: .leading).contentShape(Rectangle())
                }.accessibilityIdentifier("native-search-hit-" + section + "-" + (group.relPath ?? group.sessionId ?? "") + "-" + String(hit.page ?? 0))
            }
        }
    }
    private func tag(_ title: String) -> some View {
        Text(NativeAppLocale.string(title, locale)).font(.system(size: 10, weight: .medium)).foregroundStyle(NativeDesktopTheme.secondary)
            .padding(.horizontal, 5).frame(height: 16).overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(NativeDesktopTheme.border) }.fixedSize()
    }
    private func snippet(_ text: String) -> some View {
        Text(Self.highlighted(text, query: query)).font(.system(size: 12)).foregroundStyle(NativeDesktopTheme.secondary).lineLimit(1).truncationMode(.tail)
    }
    static let matchTint = NativeDesktopTheme.adaptive(0xffe27a, 0x7a6200)
    /// The snippet with every occurrence of the query marked.
    static func highlighted(_ text: String, query: String) -> AttributedString {
        var result = AttributedString(text)
        var cursor = text.startIndex
        while let found = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: cursor..<text.endIndex), !found.isEmpty {
            if let lower = AttributedString.Index(found.lowerBound, within: result), let upper = AttributedString.Index(found.upperBound, within: result) {
                result[lower..<upper].backgroundColor = matchTint
                result[lower..<upper].foregroundColor = NativeDesktopTheme.text
            }
            cursor = found.upperBound
        }
        return result
    }

    private func search() async {
        do {
            try await Task.sleep(for: Self.debounce)
            var request: [String: Any] = ["query": query]
            if courseOnly, let courseID { request["courseId"] = courseID }
            var value: NativeUnifiedSearchResponse = try NativeToolJSON.decode(try await store.invoke("search:unified", request))
            try Task.checkCancellation()
            // A project space lists only what lives under its folder.
            if courseOnly, let scope, scope.kind == .project {
                value = .init(capped: value.capped, handwritingIndexing: value.handwritingIndexing, sections: value.sections.map { section in
                    .init(id: section.id, groups: section.groups.filter { $0.relPath.map(scope.contains(path:)) ?? true })
                })
            }
            response = value; answered = query; failure = nil
        } catch is CancellationError {} catch { failure = error.localizedDescription; response = nil }
    }

    private func open(_ group: NativeUnifiedSearchResponse.Group, hit: NativeUnifiedSearchResponse.Hit?, section: String) {
        if section == "chat" {
            var payload: [String: Any] = ["courseId": group.courseId, "conversationId": group.sessionId ?? ""]
            if let message = hit?.messageId { payload["messageId"] = message }
            if let workspace = group.workspace, workspace.kind == "project" { payload["rootRelPath"] = workspace.rootRelPath ?? "" }
            store.events.send(.init(channel: "nativeWorkspace:openConversation", payload: payload)); return
        }
        guard let path = group.relPath else { return }
        var payload: [String: Any] = ["courseId": group.courseId, "relPath": path, "kind": group.kind == "pdf" ? "pdf" : "note"]
        if let page = hit?.page, group.kind == "pdf" {
            payload["page"] = page
            // The viewer marks the match for a moment: the text itself, or the handwritten line's box.
            payload["highlight"] = hit?.box.map { ["box": $0] as [String: Any] } ?? ["query": query]
        }
        store.events.send(.init(channel: "nativeWorkspace:openDocument", payload: payload))
    }
}

/// 이 과목만, on by default while a course is open; a tap searches everything.
struct NativeSearchScopeChip: View {
    @Binding var courseOnly: Bool
    var body: some View {
        Button { courseOnly.toggle() } label: {
            HStack(spacing: 4) {
                if courseOnly { Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold)) }
                Text("이 폴더만").font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(courseOnly ? NativeDesktopTheme.text : NativeDesktopTheme.secondary)
            .padding(.horizontal, 10).frame(height: 28)
            .background(courseOnly ? NativeDesktopTheme.raised : .clear, in: Capsule())
            .overlay { Capsule().strokeBorder(courseOnly ? .clear : NativeDesktopTheme.border) }
            .frame(minHeight: 44).contentShape(Rectangle())
        }
        .accessibilityIdentifier("native-search-scope").accessibilityAddTraits(courseOnly ? .isSelected : [])
    }
}
