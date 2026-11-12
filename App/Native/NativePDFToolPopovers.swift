import SwiftUI

/// The popover a tool opens on a second tap (Figma 259:8811 지우개 · 올가미 · 테이프 · 형광펜, 261:8446 펜):
/// glass, 280 wide (펜 300), radius 22, padding 18, 14 between rows. The surface comes from `bandalPopover`.
struct NativePDFToolPopover<Content: View>: View {
    var model: NativePDFWorkspaceModel
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content() }
            // The design has no close button (a tap outside closes). VoiceOver and UI tests get one in the corner padding.
            .overlay(alignment: .topLeading) {
                Button { model.showStyle = false } label: { Color.clear.frame(width: 16, height: 16).contentShape(Rectangle()) }
                    .offset(x: -17, y: -17).accessibilityLabel("도구 메뉴 닫기").accessibilityIdentifier("native-pdf-style-close")
            }
            .buttonStyle(.plain).foregroundStyle(NativeDesktopTheme.text)
            .disabled(model.isLoading || model.isBusy || model.errorMessage != nil)
    }
}

struct NativePDFPopoverTitle: View {
    let title: LocalizedStringKey
    init(_ title: LocalizedStringKey) { self.title = title }
    var body: some View { Text(title).font(.system(size: 17, weight: .bold)).accessibilityAddTraits(.isHeader) }
}

struct NativePDFPopoverCaption: View {
    let title: LocalizedStringKey
    init(_ title: LocalizedStringKey) { self.title = title }
    var body: some View { Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(NativeDesktopTheme.muted) }
}

/// The popovers' segmented choice: a 34 pt track (#F7F7F7, radius 10) with the chosen cell raised.
struct NativePDFSegments: View {
    let options: [(value: String, title: String)]
    let selection: String
    var identifierPrefix: String
    let choose: (String) -> Void
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let on = selection == option.value
                Button { choose(option.value) } label: {
                    Text(LocalizedStringKey(option.title)).font(.system(size: 13, weight: on ? .semibold : .medium)).lineLimit(1)
                        .foregroundStyle(on ? NativeDesktopTheme.text : NativeDesktopTheme.secondary).frame(maxWidth: .infinity).frame(height: 30)
                        .background { if on { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(NativeDesktopTheme.segmentSelected).shadow(color: .black.opacity(0.08), radius: 1.5, y: 1) } }
                        .contentShape(Rectangle())
                }.accessibilityIdentifier(identifierPrefix + option.value).accessibilityAddTraits(on ? .isSelected : [])
            }
        }.padding(2).background(NativeGlass.tool, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// A 36 pt colour cell with a 26 pt dot; the chosen one has a 1.5 pt ring.
struct NativePDFColorCell: View {
    let color: Color
    let chosen: Bool
    /// The near-black ink gets a hairline so it reads on dark glass.
    var rimmed = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Circle().fill(color).frame(width: 26, height: 26)
                .overlay { if rimmed { Circle().strokeBorder(NativeGlass.separator, lineWidth: 1) } }
                .frame(width: 36, height: 36).overlay { if chosen { Circle().strokeBorder(NativeDesktopTheme.muted, lineWidth: 1.5) } }.contentShape(Rectangle())
        }.accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// The design's slider: label and value above a 4 pt track with a dark 22 pt thumb. With `ticks` the thumb sits on one of them.
struct NativePDFSlider: View {
    let title: LocalizedStringKey
    let value: String
    let id: String
    /// 0…1 along the track.
    let fraction: Double
    var ticks = 0
    var spoken: String?
    let set: (Double) -> Void
    private static let thumb: CGFloat = 22
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 0) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(NativeDesktopTheme.secondary)
                Spacer(minLength: 8)
                Text(verbatim: value).font(.system(size: 13, weight: .semibold)).monospacedDigit()
            }.accessibilityHidden(true)
            GeometryReader { geometry in
                let travel = max(1, geometry.size.width - Self.thumb), x = travel * min(1, max(0, fraction))
                ZStack(alignment: .leading) {
                    Capsule().fill(NativeGlass.tool).frame(height: 4)
                    Capsule().fill(NativeDesktopTheme.accent).frame(width: fraction >= 1 ? geometry.size.width : x + Self.thumb / 2, height: 4)
                    ForEach(0..<ticks, id: \.self) { index in
                        let position = Double(index) / Double(max(1, ticks - 1))
                        Capsule().fill(position < fraction - 0.0001 ? NativeDesktopTheme.text : NativeGlass.tool).frame(width: 2, height: 8)
                            .offset(x: travel * position + Self.thumb / 2 - 1)
                    }
                    Circle().fill(NativeDesktopTheme.accent).frame(width: Self.thumb, height: Self.thumb)
                        .shadow(color: .black.opacity(0.12), radius: 16, y: 10).shadow(color: .black.opacity(0.06), radius: 1.5, y: 1).offset(x: x)
                }
                .frame(height: Self.thumb).contentShape(Rectangle().inset(by: -11))
                .gesture(DragGesture(minimumDistance: 0).onChanged { set(min(1, max(0, ($0.location.x - Self.thumb / 2) / travel))) })
            }.frame(height: Self.thumb)
                .accessibilityElement().accessibilityLabel(title).accessibilityValue(spoken ?? value)
                .accessibilityAdjustableAction { direction in
                    let step = ticks > 1 ? 1 / Double(ticks - 1) : 0.1
                    switch direction {
                    case .increment: set(min(1, fraction + step))
                    case .decrement: set(max(0, fraction - step))
                    @unknown default: break
                    }
                }
                .accessibilityIdentifier(id)
        }
    }
}

/// 굵기: the current ink tool's twelve steps. The pen shows "5 / 12" over twelve ticks, the highlighter the step alone.
struct NativePDFWidthSlider: View {
    var model: NativePDFWorkspaceModel
    var showsCount = false
    var body: some View {
        let step = NativePDFPaletteStyle.nearestStep(model.width, tool: model.tool)
        NativePDFSlider(title: "굵기", value: showsCount ? "\(step + 1) / 12" : "\(step + 1)", id: "native-pdf-width-slider", fraction: Double(step) / 11,
                        ticks: showsCount ? 12 : 0, spoken: NativePDFPaletteStyle.stepLabel(step)) {
            let next = Int(($0 * 11).rounded())
            if next != step { model.setWidthStep(next, slot: nil) }
        }
    }
}

struct NativePDFOpacitySlider: View {
    var model: NativePDFWorkspaceModel
    var body: some View {
        let bounds = NativePDFPaletteStyle.opacityRange(model.opacity, highlighter: model.tool == "highlighter")
        let span = max(0.0001, bounds.upperBound - bounds.lowerBound)
        NativePDFSlider(title: "투명도", value: "\(Int((model.opacity * 100).rounded()))%", id: "native-pdf-opacity-slider", fraction: (model.opacity - bounds.lowerBound) / span) {
            model.setOpacity(bounds.lowerBound + $0 * span)
        }
    }
}

/// One option line: 14 pt label and the 44 × 26 switch.
struct NativePDFOptionToggle: View {
    let title: String
    let id: String
    let isOn: Bool
    let set: (Bool) -> Void
    var body: some View {
        Toggle(isOn: Binding(get: { isOn }, set: set)) { Text(LocalizedStringKey(title)).font(.system(size: 14)) }
            .toggleStyle(BandalToggleStyle(compact: true)).frame(height: 26)
            .accessibilityLabel(LocalizedStringKey(title)).accessibilityIdentifier(id)
    }
}

/// Three size cells (44 × 40) in a tool's popover: the palette's three thickness dots again, under their own identifiers.
/// A tap picks one; a tap on the picked one opens its twelve steps.
struct NativePDFWidthSlots: View {
    var model: NativePDFWorkspaceModel
    private static let sizes: [CGFloat] = [8, 14, 22]
    var body: some View {
        let selected = model.selectedWidthSlot, tape = model.tool == "tape"
        let tint = tape ? Color(uiColor: NativePDFObjectRenderer.tapeColor(model.activeColor)) : NativeDesktopTheme.text
        HStack(spacing: 8) {
            ForEach(Array(model.widthSlots.enumerated()), id: \.offset) { index, step in
                Button { model.chooseWidthSlot(index) } label: {
                    Group { if tape { Circle().fill(tint) } else { Circle().strokeBorder(tint, lineWidth: 1.5) } }
                        .frame(width: Self.sizes[min(index, 2)], height: Self.sizes[min(index, 2)]).frame(width: 44, height: 40)
                        .background(selected == index ? NativeGlass.tool : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous)).contentShape(Rectangle())
                }
                .accessibilityLabel("굵기 \(index + 1)").accessibilityValue(NativePDFPaletteStyle.stepLabel(step))
                .accessibilityIdentifier("native-pdf-option-width-slot-\(index)").accessibilityAddTraits(selected == index ? .isSelected : [])
                .bandalPopover(isPresented: Binding(get: { model.editingWidthSlot == index }, set: { if !$0, model.editingWidthSlot == index { model.editingWidthSlot = nil } }),
                               width: 320, radius: 18, padding: 14, dims: false) {
                    NativePDFWidthSteps(color: tint, selected: model.widthSlots.indices.contains(index) ? model.widthSlots[index] : step) { model.setWidthStep($0, slot: index) }
                }
            }
        }
    }
}

struct NativePDFEraserOptions: View {
    var model: NativePDFWorkspaceModel
    var body: some View {
        NativePDFToolPopover(model: model) {
            NativePDFPopoverTitle("지우개")
            NativePDFSegments(options: [("stroke", "획 전체"), ("partial", "부분")], selection: model.palette.eraserMode, identifierPrefix: "native-pdf-eraser-mode-") { model.setEraserMode($0) }
            NativePDFPopoverCaption("크기 · 부분 지우개일 때")
            NativePDFWidthSlots(model: model)
            NativePDFOptionToggle(title: "형광펜만 지우기", id: "native-pdf-eraser-highlighter-only", isOn: model.palette.eraserHighlighterOnly) { model.setEraserHighlighterOnly($0) }
        }
    }
}

struct NativePDFLassoOptions: View {
    var model: NativePDFWorkspaceModel
    var body: some View {
        NativePDFToolPopover(model: model) {
            NativePDFPopoverTitle("올가미")
            NativePDFSegments(options: [("freeform", "자유형"), ("box", "사각형")], selection: model.lassoMode, identifierPrefix: "native-pdf-lasso-mode-") { model.setLassoMode($0) }
            NativePDFOptionToggle(title: "필기만 고르기", id: "native-pdf-lasso-ink-only", isOn: model.palette.lassoInkOnly) { model.setLassoInkOnly($0) }
            Text("끄면 사진 · 글상자도 같이 고름").font(.system(size: 12)).foregroundStyle(NativeDesktopTheme.muted)
            Button { model.showStyle = false; model.pasteObjects() } label: {
                HStack(spacing: 7) { Image(systemName: "square.and.pencil").font(.system(size: 14)); Text("붙여넣기").font(.system(size: 15, weight: .semibold)) }
                    .frame(maxWidth: .infinity).frame(height: 43).background(NativeGlass.tool, in: RoundedRectangle(cornerRadius: 12, style: .continuous)).contentShape(Rectangle())
            }.disabled(!model.canPaste).opacity(model.canPaste ? 1 : 0.4).accessibilityIdentifier("native-pdf-paste")
        }
    }
}

struct NativePDFTapeOptions: View {
    var model: NativePDFWorkspaceModel
    /// The band's thickness is not in the design: it opens from ⋯.
    @State private var showsWidth = false
    var body: some View {
        NativePDFToolPopover(model: model) {
            HStack(spacing: 8) {
                NativePDFPopoverTitle("테이프")
                Spacer(minLength: 0)
                Button { showsWidth.toggle() } label: {
                    Image(systemName: "ellipsis").font(.system(size: 15)).foregroundStyle(NativeDesktopTheme.secondary).frame(width: 44, height: 44).contentShape(Rectangle())
                }.frame(width: 26, height: 22).accessibilityLabel("테이프 굵기").accessibilityIdentifier("native-pdf-tape-more")
            }
            Text("필기 위에 붙이면 가려지고, 누르면 하나씩 벗겨져요").font(.system(size: 13)).foregroundStyle(NativeDesktopTheme.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("모두 보이기") { model.setAllTapes(revealed: true) }.accessibilityIdentifier("native-pdf-tape-reveal-all")
                Button("모두 가리기") { model.setAllTapes(revealed: false) }.accessibilityIdentifier("native-pdf-tape-cover-all")
            }.buttonStyle(BandalButtonStyle(kind: .outline, fills: true)).frame(height: 45).disabled(!model.hasTapes)
            NativePDFOptionToggle(title: "이 페이지만", id: "native-pdf-tape-page-only", isOn: model.palette.tapePageOnly) { model.setTapePageOnly($0) }
            if showsWidth {
                NativePDFPopoverCaption("굵기")
                NativePDFWidthSlots(model: model)
            }
        }
    }
}

struct NativePDFHighlighterOptions: View {
    var model: NativePDFWorkspaceModel
    var body: some View {
        NativePDFToolPopover(model: model) {
            NativePDFPopoverTitle("형광펜")
            HStack(spacing: 4) {
                // The same colours as the palette's highlighter slots, drawn the way the page draws them.
                ForEach(model.colorSlots, id: \.self) { name in
                    NativePDFColorCell(color: NativePDFPaletteLook.uiColor(name).opacity(0.7), chosen: model.color == name) { model.chooseColor(name) }
                        .accessibilityLabel(NativePDFPaletteLook.colorName(name) + " 색상").accessibilityIdentifier("native-pdf-color-" + name)
                }
            }
            NativePDFWidthSlider(model: model)
            NativePDFOpacitySlider(model: model)
            NativePDFOptionToggle(title: "곧게 긋기", id: "native-pdf-highlighter-straight", isOn: model.palette.highlighterStraight) { model.setHighlighterStraight($0) }
            // The highlighter always blends under the text. Drawing over it needs a second blend mode in the ink
            // renderer and a stored flag the desktop reads: the switch is drawn, on, and says 준비 중.
            if NativeReleaseFlags.showsUnbuiltFeatures {
                NativePDFOptionToggle(title: "글자 아래로 깔기", id: "native-pdf-highlighter-under-text", isOn: true) { _ in model.paletteNotice = "글자 위로 긋기는 준비 중이에요" }
            }
        }
    }
}

/// Where the memo popover opens from: a point in the upper middle of the page area.
struct NativePDFCommentAnchor: View {
    var model: NativePDFWorkspaceModel
    var body: some View {
        GeometryReader { geometry in
            Color.clear.frame(width: 1, height: 1)
                .bandalPopover(isPresented: Binding(get: { model.commentDraft != nil }, set: { if !$0, model.commentDraft != nil { model.saveComment() } }),
                               arrowEdge: nil, width: 320, radius: 22, padding: 18, dims: false) { NativePDFCommentPopover(model: model) }
                .position(x: geometry.size.width / 2, y: geometry.size.height * 0.3)
        }.allowsHitTesting(false)
    }
}

/// 메모 · p.N (Figma 260:8881): what the pin says, when it was written, and a field to go on writing.
/// A pin holds one text, so 이어서 메모하기 adds a line to it. Closing keeps the edit.
struct NativePDFCommentPopover: View {
    var model: NativePDFWorkspaceModel
    @FocusState private var focused: Bool
    @Environment(\.locale) private var locale
    var body: some View {
        let draft = model.commentDraft, existing = draft?.id != nil
        let text = Binding(get: { model.commentDraft?.text ?? "" }, set: { model.commentDraft?.text = $0 })
        let reply = Binding(get: { model.commentDraft?.reply ?? "" }, set: { model.commentDraft?.reply = $0 })
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("메모 · p.\(draft?.page ?? model.page)").font(.system(size: 16, weight: .bold))
                Spacer(minLength: 0)
                Button { model.saveComment() } label: {
                    HStack(spacing: 4) { Image("PDFIconCheck"); Text("완료").font(.system(size: 13, weight: .medium)) }
                        .foregroundStyle(NativeDesktopTheme.secondary).frame(minHeight: 44).contentShape(Rectangle())
                }.frame(height: 22).accessibilityIdentifier("native-pdf-save-comment")
            }
            if existing {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(verbatim: Self.stamp(draft?.written, locale)).font(.system(size: 13, weight: .semibold))
                        Button { model.deleteComment() } label: { Text("삭제").font(.system(size: 12)).foregroundStyle(NativeDesktopTheme.muted).frame(minHeight: 44).contentShape(Rectangle()) }
                            .frame(height: 18).accessibilityLabel("댓글 삭제").accessibilityIdentifier("native-pdf-delete-comment")
                    }
                    TextField("", text: text, axis: .vertical).font(.system(size: 14)).textFieldStyle(.plain).accessibilityLabel("메모").accessibilityIdentifier("native-pdf-comment-editor")
                }
            }
            HStack(spacing: 8) {
                TextField("", text: existing ? reply : text, prompt: Text("이어서 메모하기").foregroundStyle(NativeDesktopTheme.muted), axis: .vertical)
                    .font(.system(size: 14)).textFieldStyle(.plain).lineLimit(1...4).focused($focused)
                    .accessibilityLabel("이어서 메모하기").accessibilityIdentifier(existing ? "native-pdf-comment-input" : "native-pdf-comment-editor")
                Button { if existing { model.appendComment(reply.wrappedValue); reply.wrappedValue = "" } else { model.saveComment() } } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 16)).foregroundStyle(NativeDesktopTheme.muted).frame(width: 44, height: 44).contentShape(Rectangle())
                }.frame(width: 15, height: 20).accessibilityLabel("메모 남기기").accessibilityIdentifier("native-pdf-comment-send")
            }
            .padding(.horizontal, 14).padding(.vertical, 10).frame(minHeight: 42)
            .background(NativeDesktopTheme.bgApp, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(NativeDesktopTheme.border) }
        }
        .buttonStyle(.plain).foregroundStyle(NativeDesktopTheme.text).disabled(model.isBusy)
        .onAppear { if !existing { focused = true } }
    }
    /// "오늘 09:10", "어제 14:20", otherwise the date.
    static func stamp(_ date: Date?, _ locale: Locale, now: Date = Date()) -> String {
        guard let date else { return NativeAppLocale.string("메모", locale) }
        let calendar = Calendar.current, time = DateFormatter(); time.dateFormat = "HH:mm"
        let day = calendar.isDate(date, inSameDayAs: now) ? NativeAppLocale.string("오늘", locale)
            : calendar.isDate(date, inSameDayAs: now.addingTimeInterval(-86_400)) ? NativeAppLocale.string("어제", locale)
            : date.formatted(Date.FormatStyle(locale: locale).month().day())
        return day + " " + time.string(from: date)
    }
}
