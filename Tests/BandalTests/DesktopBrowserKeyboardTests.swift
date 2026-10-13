import XCTest
import UIKit
import WebKit
@testable import Bandal

@MainActor
final class DesktopBrowserKeyboardTests: XCTestCase {
    func testUIKitCommandDispatchUsesVisibleOwnedGuestAndInvalidatesRemaps() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("browser-keyboard-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let host = DesktopBrowserHost(root: root)
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 600, height: 700))
        let shell = WKWebView(frame: container.bounds); container.addSubview(shell); host.attach(to: container, shell: shell)
        let page = try host.createPage(tabID: "guest", profileID: "default", isPrivate: true, courseID: "course")
        page.bounds = container.bounds; host.layoutPages()
        let view = try XCTUnwrap(page.webView as? DesktopBrowserWebView)
        host.applyShortcuts([["chord": "mod+shift+g", "action": "new-tab", "label": "새 탭"]])
        let command = try XCTUnwrap(view.keyCommands?.first { $0.action == #selector(DesktopBrowserWebView.forwardAppShortcut(_:)) })
        let action = try XCTUnwrap(command.action)
        XCTAssertEqual(command.input, "g"); XCTAssertEqual(command.modifierFlags, [.command, .shift])
        XCTAssertEqual(command.discoverabilityTitle, "새 탭")
        XCTAssertTrue(view.canPerformAction(action, withSender: command))
        var events: [[String: Any]] = []
        host.emit = { name, payload in if name == "shortcut:passthrough", let value = payload as? [String: Any] { events.append(value) } }
        XCTAssertTrue(UIApplication.shared.sendAction(action, to: view, from: command, for: nil))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?["action"] as? String, "new-tab")
        XCTAssertEqual(events.first?["webContentsId"] as? Int, page.id)
        host.applyShortcuts([["chord": "mod+j", "action": "close-tab", "label": "탭 닫기"]])
        XCTAssertFalse(view.canPerformAction(action, withSender: command))
        view.forwardAppShortcut(command); XCTAssertEqual(events.count, 1, "A cached UIKit command must respect the latest remap")
        let current = try XCTUnwrap(view.keyCommands?.first { $0.action == command.action })
        page.bounds = nil; host.layoutPages()
        XCTAssertFalse(view.canPerformAction(try XCTUnwrap(current.action), withSender: current))
        view.forwardAppShortcut(current); XCTAssertEqual(events.count, 1)
        page.bounds = container.bounds; host.layoutPages(); host.destroy(page.tabID)
        view.forwardAppShortcut(current); XCTAssertEqual(events.count, 1, "A destroyed guest cannot target another tab")
    }

    func testPlainTypingAndStandardEditingAreNotRegisteredAsAppCommands() {
        for chord in ["t", "shift+t", "alt+t", "mod+c", "mod+v", "mod+x", "mod+a", "mod+z", "mod+shift+z", "mod+mod+t", "mod+unknown"] {
            XCTAssertNil(BrowserShortcutBinding(["chord": chord, "action": "new-tab"]), chord)
        }
        XCTAssertEqual(BrowserShortcutBinding(["chord": "mod+alt+shift+r", "action": "reload"])?.modifiers, [.command, .alternate, .shift])
        XCTAssertEqual(BrowserShortcutBinding(["chord": "mod+arrowleft", "action": "browser-back"])?.input, UIKeyCommand.inputLeftArrow)
        XCTAssertEqual(BrowserShortcutBinding(["chord": "mod+f12", "action": "new-tab"])?.input, UIKeyCommand.f12)
        XCTAssertEqual(BrowserShortcutBinding(["chord": "mod+shift+space", "action": "open-assistant"])?.input, " ")
    }

    func testPrivateRuntimeResolvesOriginalGuestPolicyAndUserKeymap() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("browser-keymap-runtime-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = DesktopRuntime(root: root, legacyRoot: root.appendingPathComponent("Legacy")); try await runtime.start()
        let defaults = try await runtime.invokePrivate("nativeBrowser:shortcuts", request: [:]) as? [[String: Any]]
        XCTAssertTrue(defaults?.contains { $0["chord"] as? String == "mod+t" && $0["action"] as? String == "new-tab" } == true)
        XCTAssertTrue(defaults?.contains { $0["chord"] as? String == "mod+r" && $0["action"] as? String == "reload" } == true)
        XCTAssertFalse(defaults?.contains { $0["action"] as? String == "settings" } == true, "Original host-only actions stay with the web page")
        _ = try await runtime.invoke("settings:set", request: ["keybindings": ["new-tab": "mod+shift+g", "close-tab": NSNull()], "shortcutPriority": "site"])
        let changed = try await runtime.invokePrivate("nativeBrowser:shortcuts", request: [:]) as? [[String: Any]]
        XCTAssertTrue(changed?.contains { $0["chord"] as? String == "mod+shift+g" && $0["action"] as? String == "new-tab" } == true)
        XCTAssertFalse(changed?.contains { $0["action"] as? String == "close-tab" || $0["action"] as? String == "reload" } == true)
    }
}
