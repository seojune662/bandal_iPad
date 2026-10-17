import SwiftUI
import UIKit
import XCTest
@testable import Bandal

final class NativeWorkspaceKeyboardTests: XCTestCase {
    func testNamedRemapsAcceptedBySettingsReachNativeKeyboardRegistration() throws {
        let expected: [String: KeyEquivalent] = [
            "tab": .tab, "enter": .return, "escape": .escape,
            "backspace": .delete, "delete": .deleteForward,
            "arrowleft": .leftArrow, "arrowright": .rightArrow,
            "arrowup": .upArrow, "arrowdown": .downArrow
        ]
        for (name, key) in expected {
            let chord = try NativeShortcutPreference.canonical("mod+shift+" + name)
            let resolved = NativeBrowserShortcuts.resolve(["keybindings": ["new-tab": chord]])
            let entry = try XCTUnwrap(resolved.first { $0["chord"] as? String == chord })
            XCTAssertEqual(entry["action"] as? String, "new-tab")
            let rawKey = try XCTUnwrap((entry["chord"] as? String)?.split(separator: "+").last)
            XCTAssertEqual(NativeWorkspaceKeyEquivalent.resolve(String(rawKey)), key, name)
        }
    }
    func testFunctionKeysCannotCreateInactiveGlobalRemapsButExistingBrowserBindingsRemainCompatible() throws {
        let inputs = [UIKeyCommand.f1, UIKeyCommand.f2, UIKeyCommand.f3, UIKeyCommand.f4, UIKeyCommand.f5, UIKeyCommand.f6,
                      UIKeyCommand.f7, UIKeyCommand.f8, UIKeyCommand.f9, UIKeyCommand.f10, UIKeyCommand.f11, UIKeyCommand.f12]
        for (index, input) in inputs.enumerated() {
            let name = "f\(index + 1)"
            XCTAssertThrowsError(try NativeShortcutPreference.canonical("mod+" + name))
            XCTAssertNil(NativeWorkspaceKeyEquivalent.resolve(name))
            XCTAssertEqual(BrowserShortcutBinding(["chord": "mod+" + name, "action": "new-tab"])?.input, input)
        }
        XCTAssertThrowsError(try NativeShortcutPreference.validateImport(Data(#"{"keybindings":{"new-tab":"mod+f1"}}"#.utf8)))
        for name in ["f0", "f13", "f24"] {
            XCTAssertThrowsError(try NativeShortcutPreference.canonical("mod+" + name))
            XCTAssertNil(NativeWorkspaceKeyEquivalent.resolve(name))
        }
    }
    func testUnknownKeysAreNotRegisteredAndCharacterRemapsSurvive() {
        XCTAssertNil(NativeWorkspaceKeyEquivalent.resolve("made-up-key"))
        XCTAssertNil(NativeWorkspaceKeyEquivalent.resolve(""))
        XCTAssertEqual(NativeWorkspaceKeyEquivalent.resolve("n")?.character, "n")
        XCTAssertEqual(NativeWorkspaceKeyEquivalent.resolve("[")?.character, "[")
    }
}
