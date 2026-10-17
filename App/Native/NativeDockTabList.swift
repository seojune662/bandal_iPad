import SwiftUI

struct NativeDockTabList: View {
    let documents: [NativeDocumentReference]
    let activeID: String?
    let select: (String) -> Void
    let close: (String) -> Void
    @State private var query = ""
    private var matches: [NativeDocumentReference] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return documents.filter { needle.isEmpty || $0.title.localizedCaseInsensitiveContains(needle) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("열린 탭 \(documents.count)개").font(.headline).padding(.horizontal, 4)
            TextField("열린 탭 검색", text: $query).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("native-dock-tabs-search")
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(matches) { document in
                        HStack(spacing: 0) {
                            Button { select(document.id) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: document.id == activeID ? "checkmark.circle.fill" : "circle").frame(width: 18)
                                    Text(document.title).lineLimit(3).multilineTextAlignment(.leading)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }.padding(.horizontal, 8).frame(minHeight: 44).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .accessibilityIdentifier("native-dock-tab-list-select-" + document.id)
                                .accessibilityAddTraits(document.id == activeID ? .isSelected : [])
                            Button { close(document.id) } label: { Image(systemName: "xmark").font(.system(size: 12)).frame(width: 44, height: 44).contentShape(Rectangle()) }
                                .buttonStyle(.plain).accessibilityLabel(document.title + " 닫기")
                                .accessibilityIdentifier("native-dock-tab-list-close-" + document.id)
                        }.background(document.id == activeID ? NativeDesktopTheme.raised : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                    }
                    if matches.isEmpty { Text("일치하는 탭이 없어요.").foregroundStyle(NativeDesktopTheme.muted).padding() }
                }
            }
        }.padding(12).frame(width: 320, height: min(440, CGFloat(max(1, matches.count)) * 46 + 96))
            .background(NativeDesktopTheme.surface)
    }
}
