import Foundation
import CoreFoundation

/// Portable desktop preferences. Unknown fields survive newer desktop versions.
enum NativeSettingsSchema {
    static func defaults(dataRoot: String) -> [String: Any] { [
        "theme":"system", "palette":"bandal", "fontScale":1.0, "editorFont":"sans", "density":"comfortable",
        "agentProvider":"claude-code", "dataRoot":dataRoot, "locale":"ko-KR",
        "openAdjacentTab":false, "restoreLastCourse":true, "browserSearchEngine":"google",
        "lastActiveCourseId":NSNull(), "keybindings":[:], "pluginSources":[], "pluginTheme":NSNull(),
        "tabs":["markdownTitlePrefix":"새 마크다운", "recordingModel":"whisper-large-v3-turbo", "recordingDeviceId":"default",
                "recordingSidebarOpen":true, "recordingFollowTranscript":true, "recordingPlaybackRate":1.0,
                "whiteboardBackground":"grid", "boardDefaultView":"calendar", "boardHideDone":false],
        "onboarding":["flowVersion":2,"closedAt":NSNull(),"lastCompletedStep":0],
        "tutorial":["seenVersion":0,"activeCourseId":NSNull()], "milestones":["pipUsedAt":NSNull()],
        "university":["universityId":NSNull(),"customUniversity":NSNull(),"hiddenServiceIds":[],"customServices":[],"openExternallyOverrides":[:],"serviceOrder":[]],
        "notifications":["enabled":true,"deadlines":true,"deadlineLeadDays":[3,1],"agentComplete":true,"downloads":true,"pluginNotices":true,"sound":true,"suppressWhileFocused":true,"sent":[:]],
        "browser":["swipeNavigation":true,"agentUse":true,"homePage":"","defaultZoomLevel":0.0,"linkRouting":"in-app","popupBehavior":"balanced","trackingProtection":"balanced","doNotTrack":true,"extensions":[]],
        "widgets":["collapsed":[],"enabled":[],"active":"todo","heightRatio":0.38,"mailServiceId":NSNull(),"mailUrl":"","lastMailOpenedAt":NSNull()],
        "experimental":["extensionRuntime":true], "shortcutPriority":"bandal",
        "calendar":["selectedCalendarIds":[],"destinationCalendarId":NSNull()]
    ] }
    static let patchGroups: Set<String> = ["tabs","browser","notifications","experimental","widgets","calendar","university"]
    static func merging(_ previous: [String: Any], patch: [String: Any]) -> [String: Any] {
        var result = previous
        for (key, value) in patch {
            if patchGroups.contains(key), let before = previous[key] as? [String: Any], let next = value as? [String: Any] {
                result[key] = before.merging(next) { _, value in value }
            } else { result[key] = value }
        }
        return result
    }
    static func normalized(_ raw: [String: Any], dataRoot: String) -> [String: Any] {
        let fallback = defaults(dataRoot:dataRoot)
        var result = fallback.merging(raw) { old, new in
            if let old = old as? [String:Any], let new = new as? [String:Any] { return old.merging(new) { _,new in new } }
            return new
        }
        func select(_ key: String, _ choices: [String]) {
            if !choices.contains(result[key] as? String ?? "") { result[key] = fallback[key] }
        }
        select("theme",["system","light","dark","sepia","high-contrast","midnight","graphite"])
        if result["editorFont"] as? String == "system" { result["editorFont"] = "sans" }
        select("editorFont",["sans","serif","mono"]); select("density",["comfortable","compact"])
        select("agentProvider",["claude-code","codex","gemini"]); select("locale",["ko-KR","en-US"])
        select("browserSearchEngine",["google","naver","daum","duckduckgo"]); select("shortcutPriority",["bandal","site"])
        if ![0.9,1,1.1,1.2].contains((result["fontScale"] as? NSNumber)?.doubleValue ?? -1) { result["fontScale"] = 1.0 }
        for key in ["openAdjacentTab","restoreLastCourse"] { if !isBool(result[key]) { result[key] = fallback[key] } }
        for group in patchGroups {
            guard var value = result[group] as? [String:Any], let base = fallback[group] as? [String:Any] else { result[group] = fallback[group]; continue }
            for (key,defaultValue) in base where isBool(defaultValue) { if !isBool(value[key]) { value[key] = defaultValue } }
            func choice(_ key: String, _ choices: [String]) { if !choices.contains(value[key] as? String ?? "") { value[key] = base[key] } }
            if group == "tabs" {
                choice("whiteboardBackground",["blank","grid","dots","lines"]); choice("boardDefaultView",["board","calendar"])
                choice("recordingModel",["whisper-large-v3-turbo","zipformer-ko","sensevoice"])
                if ![0.75,1,1.25,1.5,1.75,2].contains((value["recordingPlaybackRate"] as? NSNumber)?.doubleValue ?? 0) { value["recordingPlaybackRate"] = 1.0 }
                let title = (value["markdownTitlePrefix"] as? String ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
                value["markdownTitlePrefix"] = title.isEmpty ? base["markdownTitlePrefix"] : String(title.prefix(60))
                if (value["recordingDeviceId"] as? String ?? "").isEmpty { value["recordingDeviceId"] = "default" }
            } else if group == "browser" {
                choice("linkRouting",["in-app","system"]); choice("popupBehavior",["balanced","strict"]); choice("trackingProtection",["balanced","strict","off"])
                let zoom = (value["defaultZoomLevel"] as? NSNumber)?.doubleValue ?? 0
                if !zoom.isFinite || zoom < -5 || zoom > 5 { value["defaultZoomLevel"] = 0.0 }
                if let home = value["homePage"] as? String, !home.isEmpty, !webURL(home) { value["homePage"] = "" }
            } else if group == "notifications" {
                if let days = value["deadlineLeadDays"] as? [Int] { value["deadlineLeadDays"] = Array(Set(days.filter { [1,3,7].contains($0) })).sorted(by:>) }
                else { value["deadlineLeadDays"] = base["deadlineLeadDays"] }
            } else if group == "widgets" {
                for key in ["enabled","collapsed"] { var seen = Set<String>(); value[key] = (value[key] as? [String] ?? []).filter { ["todo","board","mail"].contains($0) && seen.insert($0).inserted } }
                let enabled = value["enabled"] as? [String] ?? []
                if !enabled.contains(value["active"] as? String ?? "") { value["active"] = enabled.first ?? "todo" }
                let ratio = (value["heightRatio"] as? NSNumber)?.doubleValue ?? 0.38
                value["heightRatio"] = ratio.isFinite ? min(0.65,max(0.25,ratio)) : 0.38
            } else if group == "calendar" {
                var seen = Set<String>(); value["selectedCalendarIds"] = (value["selectedCalendarIds"] as? [String] ?? []).filter { !$0.isEmpty && seen.insert($0).inserted }
            }
            result[group] = value
        }
        return result
    }
    static func isBool(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }
    static func webURL(_ raw: String) -> Bool {
        guard raw.count <= 2048, let url = URL(string:raw) else { return false }
        return ["https","http"].contains(url.scheme?.lowercased() ?? "") && url.host != nil && url.user == nil && url.password == nil
    }
}
