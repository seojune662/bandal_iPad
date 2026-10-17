import Foundation

/// Persisted desktop key maps are interpreted by Swift. UIKit validates each
/// binding again before registering it, preserving normal website text input.
enum NativeBrowserShortcuts {
    struct Spec: Identifiable {
        let id: String, chord: String, action: String, label: String
        var lifetime: Bool = false
    }
    static let specs: [Spec] = [
        Spec(id:"new-tab",chord:"mod+t",action:"new-tab",label:"새 탭",lifetime:true),
        Spec(id:"new-markdown",chord:"mod+shift+m",action:"new-markdown",label:"새 마크다운",lifetime:true),
        Spec(id:"new-whiteboard",chord:"mod+alt+w",action:"new-whiteboard",label:"새 노트",lifetime:true),
        Spec(id:"new-browser-tab",chord:"mod+shift+b",action:"new-tab",label:"새 브라우저 탭",lifetime:true),
        Spec(id:"new-ai-tab",chord:"mod+shift+a",action:"new-ai-tab",label:"AI 열기",lifetime:true),
        Spec(id:"new-recording-tab",chord:"mod+alt+r",action:"new-recording-tab",label:"녹음 열기",lifetime:true),
        Spec(id:"open-study-board",chord:"mod+alt+d",action:"open-study-board",label:"할 일 열기",lifetime:true),
        Spec(id:"close-tab",chord:"mod+w",action:"close-tab",label:"탭 닫기",lifetime:true),
        Spec(id:"activate-last-tab",chord:"mod+9",action:"activate-last-tab",label:"마지막 탭",lifetime:true),
        Spec(id:"cycle-tab-prev",chord:"mod+shift+[",action:"prev-tab",label:"이전 탭",lifetime:true),
        Spec(id:"cycle-tab-next",chord:"mod+shift+]",action:"next-tab",label:"다음 탭",lifetime:true),
        Spec(id:"toggle-left-rail",chord:"mod+s",action:"toggle-left-rail",label:"사이드바 접기·펼치기",lifetime:true),
        Spec(id:"browser-back",chord:"mod+[",action:"browser-back",label:"뒤로"),
        Spec(id:"browser-forward",chord:"mod+]",action:"browser-forward",label:"앞으로"),
        Spec(id:"browser-reload",chord:"mod+r",action:"reload",label:"새로고침"),
        Spec(id:"browser-reload-hard",chord:"mod+shift+r",action:"reload-hard",label:"캐시 없이 새로고침"),
        Spec(id:"browser-focus-address",chord:"mod+l",action:"focus-address",label:"주소 입력"),
        Spec(id:"browser-find",chord:"mod+f",action:"find",label:"페이지에서 찾기"),
        Spec(id:"browser-zoom-in",chord:"mod+=",action:"zoom-in",label:"확대"),
        Spec(id:"browser-zoom-out",chord:"mod+-",action:"zoom-out",label:"축소"),
        Spec(id:"browser-zoom-reset",chord:"mod+0",action:"zoom-reset",label:"확대 초기화")
    ] + (1...8).map { Spec(id:"activate-tab-\($0)",chord:"mod+\($0)",action:"activate-tab-\($0)",label:"\($0)번째 탭",lifetime:true) }
    static func resolve(_ settings: [String:Any]) -> [[String:Any]] {
        let bindings = settings["keybindings"] as? [String:Any] ?? [:], site = settings["shortcutPriority"] as? String == "site"
        var result: [String:[String:Any]] = [:]
        // Explicit remaps take precedence over default chord conflicts.
        for spec in specs.sorted(by: { (bindings[$0.id] == nil ? 0 : 1) < (bindings[$1.id] == nil ? 0 : 1) }) {
            guard !(bindings[spec.id] is NSNull), !site || spec.lifetime else { continue }
            let chord = (bindings[spec.id] as? String ?? spec.chord).lowercased().split(separator:"+").map { $0.trimmingCharacters(in:.whitespaces) }
            guard let key = chord.last, chord.contains("mod"), Set(chord).count == chord.count,
                  chord.dropLast().allSatisfy({ ["mod","alt","shift"].contains($0) }),
                  chord.contains("alt") || !["c","v","x","z","a"].contains(key) else { continue }
            let canonical = (["mod","alt","shift"].filter { chord.contains($0) } + [key]).joined(separator:"+")
            result[canonical] = ["chord":canonical,"action":spec.action,"label":spec.label]
        }
        return result.keys.sorted().compactMap { result[$0] }
    }
}
