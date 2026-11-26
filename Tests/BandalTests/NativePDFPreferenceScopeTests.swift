import XCTest
@testable import Bandal

final class NativePDFPreferenceScopeTests: XCTestCase {
    private func legacyDocumentKey(_ root: URL, _ id: String) -> String {
        NativePDFWorkspacePreferences.key(root: root, documentID: id, documentsRoot: URL(fileURLWithPath: "/unrelated-preference-scope"))
    }
    private func legacyPaletteKey(_ root: URL) -> String {
        NativePDFPalettePreferences.key(root: root, documentsRoot: URL(fileURLWithPath: "/unrelated-preference-scope"))
    }
    private func defaults() -> (UserDefaults, String) {
        let suite = "NativePDFPreferenceScopeTests.\(UUID())"
        return (UserDefaults(suiteName: suite)!, suite)
    }
    private func documents(_ base: URL, _ uuid: String = UUID().uuidString) -> URL {
        base.appendingPathComponent("Containers/Data/Application/" + uuid + "/Documents", isDirectory: true)
    }
    private func settings(_ root: URL, previous: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: ["dataRoot": previous.appendingPathComponent("Courses").path])
        try data.write(to: root.appendingPathComponent("settings.json"))
    }
    private func preset(_ index: Int) -> NativePDFWorkspacePreferences {
        var value = NativePDFWorkspacePreferences()
        value.color = "blue"; value.width = 0.002 + Double(index) * 0.001; value.opacity = 0.6
        value.penStyle = .init(color: value.color, width: value.width, opacity: value.opacity)
        value.highlighterStyle = .init(color: "green", width: 0.009, opacity: 0.2)
        value.showPages = true
        return value
    }

    func testContainerUUIDChangeKeepsDocumentStylesViewportAndSharedPalette() throws {
        let (defaults, suite) = defaults(); defer { defaults.removePersistentDomain(forName: suite) }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let a = documents(base), b = documents(base)
        let old = a.appendingPathComponent("BandalDesktop"), new = b.appendingPathComponent("BandalDesktop")
        var saved = preset(3)
        saved.viewport = .init(revision: "r", values: ["page": 2, "zoom": 1.5, "progress": 0.7, "horizontalProgress": 0.2])
        saved.save(root: old, documentID: "course:note.pdf", defaults: defaults, documentsRoot: a)
        let palette = NativePDFPalettePreferences.update(root: old, defaults: defaults, documentsRoot: a) {
            $0.recentPen = .init(color: "violet", width: 0.0173, opacity: 0.55); $0.drawAndHold = false
        }
        XCTAssertEqual(NativePDFWorkspacePreferences.key(root: old, documentID: "course:note.pdf", documentsRoot: a), NativePDFWorkspacePreferences.key(root: new, documentID: "course:note.pdf", documentsRoot: b))
        XCTAssertEqual(NativePDFWorkspacePreferences.load(root: new, documentID: "course:note.pdf", defaults: defaults, documentsRoot: b), saved)
        XCTAssertEqual(NativePDFPalettePreferences.load(root: new, defaults: defaults, documentsRoot: b), palette)
    }

    func testFiveLegacyRootsUseImmediatelyPreviousSettingsRootAndPreserveEveryOldKey() throws {
        let (defaults, suite) = defaults(); defer { defaults.removePersistentDomain(forName: suite) }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let currentDocuments = documents(base), root = currentDocuments.appendingPathComponent("BandalDesktop")
        let oldRoots = (0..<5).map { _ in documents(base).appendingPathComponent("BandalDesktop") }
        var original: [String: Data] = [:]
        for (index, previous) in oldRoots.enumerated() {
            let data = try JSONEncoder().encode(preset(index)), key = legacyDocumentKey(previous, "same-document")
            original[key] = data; defaults.set(data, forKey: key)
            var palette = NativePDFPalettePreferences(); palette.recentPen = preset(index).penStyle
            let paletteData = try JSONEncoder().encode(palette), paletteKey = legacyPaletteKey(previous)
            original[paletteKey] = paletteData; defaults.set(paletteData, forKey: paletteKey)
        }
        try settings(root, previous: oldRoots[4])
        NativePDFPreferenceScope.registerPreviousRoot(root: root, documentsRoot: currentDocuments, defaults: defaults)
        XCTAssertTrue(NativePDFWorkspacePreferences.hasStored(root: root, documentID: "same-document", defaults: defaults, documentsRoot: currentDocuments))
        XCTAssertEqual(NativePDFWorkspacePreferences.load(root: root, documentID: "same-document", defaults: defaults, documentsRoot: currentDocuments), preset(4))
        XCTAssertEqual(NativePDFPalettePreferences.load(root: root, defaults: defaults, documentsRoot: currentDocuments).recentPen, preset(4).penStyle)
        for (key, data) in original { XCTAssertEqual(defaults.data(forKey: key), data) }
        XCTAssertNotNil(defaults.data(forKey: NativePDFWorkspacePreferences.key(root: root, documentID: "same-document", documentsRoot: currentDocuments)))
        // Relocation has since updated settings. It must not discard the
        // predecessor needed by a document first reopened on a later launch.
        defaults.set(try JSONEncoder().encode(preset(2)), forKey: legacyDocumentKey(oldRoots[4], "unopened-document"))
        try settings(root, previous: root)
        NativePDFPreferenceScope.registerPreviousRoot(root: root, documentsRoot: currentDocuments, defaults: defaults)
        XCTAssertEqual(NativePDFWorkspacePreferences.load(root: root, documentID: "unopened-document", defaults: defaults, documentsRoot: currentDocuments), preset(2))
    }

    func testCurrentAbsoluteLegacyKeyHasPriorityOverPreviousContainer() throws {
        let (defaults, suite) = defaults(); defer { defaults.removePersistentDomain(forName: suite) }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let currentDocuments = documents(base), root = currentDocuments.appendingPathComponent("BandalDesktop")
        let previous = documents(base).appendingPathComponent("BandalDesktop")
        try settings(root, previous: previous)
        NativePDFPreferenceScope.registerPreviousRoot(root: root, documentsRoot: currentDocuments, defaults: defaults)
        defaults.set(try JSONEncoder().encode(preset(1)), forKey: legacyDocumentKey(previous, "document"))
        defaults.set(try JSONEncoder().encode(preset(4)), forKey: legacyDocumentKey(root, "document"))
        XCTAssertEqual(NativePDFWorkspacePreferences.load(root: root, documentID: "document", defaults: defaults, documentsRoot: currentDocuments), preset(4))
        var oldPalette = NativePDFPalettePreferences(); oldPalette.recentPen = preset(1).penStyle
        var latestPalette = NativePDFPalettePreferences(); latestPalette.recentPen = preset(4).penStyle
        defaults.set(try JSONEncoder().encode(oldPalette), forKey: legacyPaletteKey(previous))
        defaults.set(try JSONEncoder().encode(latestPalette), forKey: legacyPaletteKey(root))
        XCTAssertEqual(NativePDFPalettePreferences.load(root: root, defaults: defaults, documentsRoot: currentDocuments), latestPalette)
    }

    func testUnopenedDocumentMigratesAfterTwoUpdatesUsingRegisteredPredecessorChain() throws {
        let (defaults, suite) = defaults(); defer { defaults.removePersistentDomain(forName: suite) }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let original = documents(base).appendingPathComponent("BandalDesktop")
        let middleDocuments = documents(base), middle = middleDocuments.appendingPathComponent("BandalDesktop")
        let newestDocuments = documents(base), newest = newestDocuments.appendingPathComponent("BandalDesktop")
        let initial = try JSONEncoder().encode(preset(1)), recent = try JSONEncoder().encode(preset(4))
        defaults.set(initial, forKey: legacyDocumentKey(original, "unopened"))
        defaults.set(initial, forKey: legacyDocumentKey(original, "opened-in-middle"))
        defaults.set(recent, forKey: legacyDocumentKey(middle, "opened-in-middle"))
        var palette = NativePDFPalettePreferences(); palette.recentPen = preset(3).penStyle
        defaults.set(try JSONEncoder().encode(palette), forKey: legacyPaletteKey(original))
        try settings(middle, previous: original)
        NativePDFPreferenceScope.registerPreviousRoot(root: middle, documentsRoot: middleDocuments, defaults: defaults)
        // Neither the document nor the palette was opened during this version.
        try settings(newest, previous: middle)
        NativePDFPreferenceScope.registerPreviousRoot(root: newest, documentsRoot: newestDocuments, defaults: defaults)
        XCTAssertTrue(NativePDFWorkspacePreferences.hasStored(root: newest, documentID: "unopened", defaults: defaults, documentsRoot: newestDocuments))
        XCTAssertEqual(NativePDFWorkspacePreferences.load(root: newest, documentID: "unopened", defaults: defaults, documentsRoot: newestDocuments), preset(1))
        XCTAssertEqual(NativePDFWorkspacePreferences.load(root: newest, documentID: "opened-in-middle", defaults: defaults, documentsRoot: newestDocuments), preset(4))
        XCTAssertEqual(NativePDFPalettePreferences.load(root: newest, defaults: defaults, documentsRoot: newestDocuments), palette)
        XCTAssertEqual(defaults.data(forKey: legacyDocumentKey(original, "unopened")), initial)
        XCTAssertEqual(defaults.data(forKey: legacyDocumentKey(middle, "opened-in-middle")), recent)
    }

    func testPrivateAliasesMigrateOnlyWhenTheirPayloadsAgree() throws {
        let (defaults, suite) = defaults(); defer { defaults.removePersistentDomain(forName: suite) }
        let currentDocuments = URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/" + UUID().uuidString + "/Documents")
        let root = currentDocuments.appendingPathComponent("BandalDesktop")
        let alias = URL(fileURLWithPath: "/private" + root.path)
        let data = try JSONEncoder().encode(preset(2))
        for value in [root, alias] { defaults.set(data, forKey: legacyDocumentKey(value, "agree")) }
        XCTAssertEqual(NativePDFWorkspacePreferences.load(root: root, documentID: "agree", defaults: defaults, documentsRoot: currentDocuments), preset(2))
        defaults.set(data, forKey: legacyDocumentKey(root, "conflict"))
        defaults.set(try JSONEncoder().encode(preset(4)), forKey: legacyDocumentKey(alias, "conflict"))
        XCTAssertFalse(NativePDFWorkspacePreferences.hasStored(root: root, documentID: "conflict", defaults: defaults, documentsRoot: currentDocuments))
        XCTAssertNil(defaults.data(forKey: NativePDFWorkspacePreferences.key(root: root, documentID: "conflict", documentsRoot: currentDocuments)))
        XCTAssertEqual(defaults.data(forKey: legacyDocumentKey(root, "conflict")), data)
    }

    func testExternalAndUITestRootsStayIsolatedAndWrongPredecessorsAreIgnored() throws {
        let (defaults, suite) = defaults(); defer { defaults.removePersistentDomain(forName: suite) }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let currentDocuments = documents(base), root = currentDocuments.appendingPathComponent("BandalDesktop")
        let test = currentDocuments.appendingPathComponent("BandalDesktop-Native-UI-Tests")
        let externalA = base.appendingPathComponent("external-a"), externalB = base.appendingPathComponent("external-b")
        XCTAssertEqual(NativePDFPreferenceScope.identity(root: externalA, documentsRoot: currentDocuments), externalA.standardizedFileURL.path)
        XCTAssertNotEqual(NativePDFWorkspacePreferences.key(root: root, documentID: "same", documentsRoot: currentDocuments), NativePDFWorkspacePreferences.key(root: test, documentID: "same", documentsRoot: currentDocuments))
        XCTAssertNotEqual(NativePDFPalettePreferences.key(root: externalA, documentsRoot: currentDocuments), NativePDFPalettePreferences.key(root: externalB, documentsRoot: currentDocuments))
        let wrongRelative = documents(base).appendingPathComponent("BandalDesktop-Native-UI-Tests")
        defaults.set(try JSONEncoder().encode(preset(4)), forKey: legacyDocumentKey(wrongRelative, "same"))
        try settings(root, previous: wrongRelative)
        NativePDFPreferenceScope.registerPreviousRoot(root: root, documentsRoot: currentDocuments, defaults: defaults)
        XCTAssertFalse(NativePDFWorkspacePreferences.hasStored(root: root, documentID: "same", defaults: defaults, documentsRoot: currentDocuments))
        defaults.set(try JSONEncoder().encode(preset(2)), forKey: legacyDocumentKey(externalA, "same"))
        try settings(root, previous: externalA)
        NativePDFPreferenceScope.registerPreviousRoot(root: root, documentsRoot: currentDocuments, defaults: defaults)
        XCTAssertFalse(NativePDFWorkspacePreferences.hasStored(root: root, documentID: "same", defaults: defaults, documentsRoot: currentDocuments))
    }

    /// The PDF tools' settings live in their own suite so a palette tap does not redraw every @AppStorage view. The first
    /// launch takes over what earlier builds left in the standard defaults, and only that once.
    func testPDFPreferencesAdoptStandardValuesOnce() {
        let (standard, standardSuite) = defaults(), (suite, suiteName) = defaults()
        defer { standard.removePersistentDomain(forName: standardSuite); suite.removePersistentDomain(forName: suiteName) }
        let root = URL(fileURLWithPath: "/adopt-preference-scope")
        let paletteKey = NativePDFPalettePreferences.key(root: root), documentKey = NativePDFWorkspacePreferences.key(root: root, documentID: "doc")
        standard.set(Data("palette".utf8), forKey: paletteKey)
        standard.set(Data("document".utf8), forKey: documentKey)
        standard.set("kept", forKey: "native.appearance")
        suite.set(Data("newer".utf8), forKey: documentKey)
        NativePDFPreferenceScope.adoptStandardValues(into: suite, from: standard)
        XCTAssertEqual(suite.data(forKey: paletteKey), Data("palette".utf8))
        XCTAssertEqual(suite.data(forKey: documentKey), Data("newer".utf8), "A value the suite already has is not overwritten")
        XCTAssertNil(suite.object(forKey: "native.appearance"), "Only the PDF tools' keys move")
        XCTAssertEqual(standard.data(forKey: paletteKey), Data("palette".utf8), "Earlier builds still find their copy")
        suite.removeObject(forKey: paletteKey)
        NativePDFPreferenceScope.adoptStandardValues(into: suite, from: standard)
        XCTAssertNil(suite.data(forKey: paletteKey), "The copy happens once")
    }
    func testPDFPreferencesDefaultToTheirOwnSuite() {
        XCTAssertFalse(NativePDFPreferenceScope.defaults === UserDefaults.standard)
        let root = URL(fileURLWithPath: "/own-suite-\(UUID().uuidString)")
        let key = NativePDFPalettePreferences.key(root: root)
        defer { NativePDFPreferenceScope.defaults.removeObject(forKey: key); UserDefaults.standard.removeObject(forKey: key) }
        NativePDFPalettePreferences.update(root: root) { $0.eraserMode = "partial" }
        XCTAssertNotNil(NativePDFPreferenceScope.defaults.data(forKey: key))
        XCTAssertNil(UserDefaults.standard.data(forKey: key), "A palette change writes nothing to the standard defaults")
    }
}
