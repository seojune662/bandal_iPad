import XCTest
import UIKit
import Metal
@testable import Bandal

/// Actual MixedScene + object texture cache with a controlled asynchronous
/// raster boundary. These tests inspect draw/hit lists and resource identities;
/// texture pixels and physical presentation are qualified by separate suites.
@MainActor
final class NativePDFRetainedMixedSceneTests: XCTestCase {
    private typealias Scene = NativePDFRetainedMixedScene
    private typealias Textures = NativePDFRetainedObjectTextures
    private typealias Renderer = NativePDFRetainedInkRenderer
    private let size = CGSize(width: 120, height: 180)

    func testOriginalMeshTextureAndMultiplyOrderIsAdoptedOnlyWhenEveryTextureIsReady() async throws {
        let f = try fixture()
        let rows = [ink("pen"), object("text"), ink("marker", highlighter: true), legacyMarker("legacy")]
        XCTAssertEqual(update(f.scene, rows), .preparing)
        XCTAssertFalse(f.scene.hasAcceptedScene); XCTAssertTrue(items(f.scene).isEmpty)
        try await release(f, job: 0, expectedUploads: 1)
        XCTAssertEqual(update(f.scene, rows), .preparing)
        XCTAssertFalse(f.scene.hasAcceptedScene); XCTAssertTrue(items(f.scene).isEmpty,
            "The first ready texture cannot publish a partial initial scene")
        try await release(f, job: 1, expectedUploads: 2)
        XCTAssertEqual(update(f.scene, rows), .supported)
        let draw = items(f.scene)
        XCTAssertEqual(kinds(draw), ["mesh","texture","mesh","texture"])
        XCTAssertEqual(draw.map(\.multiply), [false,false,true,true])
        XCTAssertEqual(hitIDs(f.scene), ["pen","text","marker","legacy"])
        XCTAssertEqual(f.scene.objectCount, 2); XCTAssertEqual(f.renderer.meshUploadCount, 2)
        let meshes = draw.compactMap(\.mesh), textures = draw.compactMap(\.texture)
        for _ in 0..<3 { XCTAssertEqual(update(f.scene, rows), .supported) }
        let repeated = items(f.scene)
        XCTAssertTrue(repeated[0].mesh === meshes[0]); XCTAssertTrue(repeated[2].mesh === meshes[1])
        XCTAssertTrue(repeated[1].texture === textures[0]); XCTAssertTrue(repeated[3].texture === textures[1])
        XCTAssertEqual(f.renderer.meshUploadCount, 2); XCTAssertEqual(f.renderer.textureUploadCount, 2)
    }

    func testWaitingReplacementKeepsAcceptedSceneThenAtomicallyAdoptsNewOrder() async throws {
        let f = try fixture(), pen = ink("pen"), oldText = object("text", text: "old")
        try await accept(f, rows: [pen,oldText], job: 0)
        let old = items(f.scene), revision = f.scene.acceptedRevision
        let rows = [object("text", text: "new"),pen,ink("remote")]
        XCTAssertEqual(update(f.scene, rows), .preparing)
        XCTAssertTrue(f.scene.hasAcceptedScene); XCTAssertEqual(f.scene.acceptedRevision, revision)
        XCTAssertEqual(hitIDs(f.scene), ["pen","text"], "Unconfirmed remote rows are not an optimistic local tail")
        XCTAssertTrue(items(f.scene)[0].mesh === old[0].mesh)
        XCTAssertTrue(items(f.scene)[1].texture === old[1].texture)
        try await release(f, job: 1, expectedUploads: 2)
        XCTAssertEqual(update(f.scene, rows), .supported)
        XCTAssertEqual(kinds(items(f.scene)), ["texture","mesh","mesh"])
        XCTAssertEqual(hitIDs(f.scene), ["text","pen","remote"])
        XCTAssertFalse(items(f.scene)[0].texture === old[1].texture)
        XCTAssertGreaterThan(f.scene.acceptedRevision, revision)
    }

    func testNativeLocalTailAndACKAliasDoNotDuplicateOrDisappearWhileTextureWaits() async throws {
        let f = try fixture(), old = object("text", text: "old")
        try await accept(f, rows: [old], job: 0)
        f.scene.rememberLocalMutation("M")
        let local = ink("M", alias: "M"), changed = object("text", text: "changed")
        XCTAssertEqual(update(f.scene, [changed,local]), .preparing)
        let first = items(f.scene)
        XCTAssertEqual(kinds(first), ["texture","mesh"]); XCTAssertEqual(hitIDs(f.scene), ["text","M"])
        let mesh = try XCTUnwrap(first.last?.mesh)
        f.scene.rememberNativeAlias(mutationID: "M", drawingID: "D")
        let canonical = ink("D", alias: "M")
        XCTAssertEqual(update(f.scene, [changed,canonical]), .preparing)
        XCTAssertEqual(hitIDs(f.scene), ["text","D"])
        XCTAssertTrue(items(f.scene).last?.mesh === mesh, "ACK changes identity, not native geometry")
        XCTAssertEqual(items(f.scene, excluding: ["M"]).count, 1)
        XCTAssertEqual(items(f.scene, excluding: ["D"]).count, 1)
        // The editor can later omit the mutation alias; native-owned D association
        // still identifies this row as locally completed while a texture waits.
        let editor = ink("D")
        XCTAssertEqual(update(f.scene, [changed,editor]), .preparing)
        XCTAssertEqual(hitIDs(f.scene), ["text","D"])
        try await release(f, job: 1, expectedUploads: 2)
        XCTAssertEqual(update(f.scene, [changed,editor]), .supported)
        XCTAssertEqual(hitIDs(f.scene), ["text","D"]); XCTAssertEqual(items(f.scene).count, 2)
    }

    func testStructuralDeletionIsImmediateAndUndoNewIDWaitsWithoutResurrectingOldID() async throws {
        let f = try fixture(), a = ink("A"), b = ink("B"), oldText = object("text", text: "old")
        try await accept(f, rows: [a,oldText,b], job: 0)
        let changed = object("text", text: "changed")
        XCTAssertEqual(update(f.scene, [changed,b]), .preparing)
        XCTAssertEqual(hitIDs(f.scene), ["text","B"])
        let undo = ink("A-undo")
        XCTAssertEqual(update(f.scene, [undo,changed,b]), .preparing)
        XCTAssertEqual(hitIDs(f.scene), ["text","B"], "Undo is not native local completion and must wait for the complete candidate")
        XCTAssertEqual(items(f.scene, excluding: ["A"]).count, 2)
        try await release(f, job: 1, expectedUploads: 2)
        XCTAssertEqual(update(f.scene, [undo,changed,b]), .supported)
        XCTAssertEqual(hitIDs(f.scene), ["A-undo","text","B"])
        XCTAssertEqual(items(f.scene, excluding: ["A"]).count, 3, "Old tombstone cannot hide a new undo ID")
        XCTAssertEqual(items(f.scene, excluding: ["A-undo"]).count, 2)
    }

    func testInvalidCandidateDoesNotPartiallyUploadOrReplaceAcceptedScene() async throws {
        let f = try fixture(), accepted = ink("accepted")
        XCTAssertEqual(update(f.scene, [accepted]), .supported)
        let mesh = try XCTUnwrap(items(f.scene).first?.mesh), revision = f.scene.acceptedRevision
        var bad = object("bad"); bad["kind"] = "unknown"
        let invalid: [[[String: Any]]] = [[ink("new"),bad], [accepted,accepted],
            [accepted,ink("other", alias: "accepted")], [object("locationless", data: [:])]]
        for rows in invalid {
            XCTAssertEqual(update(f.scene, rows), .unsupported)
            XCTAssertEqual(f.scene.acceptedRevision, revision)
            XCTAssertEqual(f.renderer.meshUploadCount, 1)
            XCTAssertEqual(f.renderer.textureUploadCount, 0)
        }
        // The caller explicitly chooses fallback on .unsupported. A subsequent
        // valid original scene must recover without a partially changed cache.
        XCTAssertEqual(update(f.scene, [accepted]), .supported)
        XCTAssertTrue(items(f.scene).first?.mesh === mesh)
        let jobs = await f.gate.count; XCTAssertEqual(jobs, 0)
    }

    func testNewPageGeometryBlocksOldDrawAndHitListsUntilFreshTextureIsReady() async throws {
        let f = try fixture(), rows = [ink("pen"),object("text")]
        try await accept(f, rows: rows, job: 0)
        let oldTexture = try XCTUnwrap(items(f.scene).last?.texture)
        let rotated = CGSize(width: size.height, height: size.width)
        XCTAssertEqual(update(f.scene, rows, pageSize: rotated), .preparing)
        XCTAssertFalse(f.scene.hasAcceptedScene)
        XCTAssertTrue(items(f.scene).isEmpty, "An old page basis is not a valid visible stand-in")
        XCTAssertTrue(hitIDs(f.scene).isEmpty, "Never delete using geometry from the old page basis")
        try await release(f, job: 1, expectedUploads: 2)
        XCTAssertEqual(update(f.scene, rows, pageSize: rotated), .supported)
        XCTAssertEqual(hitIDs(f.scene), ["pen","text"])
        XCTAssertFalse(items(f.scene).last?.texture === oldTexture)
        // Texture UV is normalized by the matching Source.pageSize once before
        // the caller's current viewport transform, including rotated geometry.
        let transform = CGAffineTransform(a: 0,b: 300,c: -200,d: 0,tx: 250,ty: 10)
        let projected = f.scene.items(transform: transform, excludingIDs: [])
        XCTAssertEqual(projected[0].transform, transform)
        let identity = items(f.scene)[1].transform
        XCTAssertEqual(projected[1].transform, identity.concatenating(transform))
    }

    func testExactUTF8IDsSurviveMixedSceneAndAliasExclusion() async throws {
        let f = try fixture(), a = "\u{00e9}", b = "e\u{0301}"
        let rows = [ink(a, alias: "native-a"),object(b)]
        try await accept(f, rows: rows, job: 0)
        XCTAssertEqual(hitIDs(f.scene).map { Data($0.utf8) }, [Data(a.utf8),Data(b.utf8)])
        XCTAssertEqual(items(f.scene, excluding: [a]).count, 1)
        XCTAssertNotNil(items(f.scene, excluding: [a])[0].texture)
        XCTAssertEqual(items(f.scene, excluding: [b]).count, 1)
        XCTAssertNotNil(items(f.scene, excluding: [b])[0].mesh)
        XCTAssertEqual(items(f.scene, excluding: ["native-a"]).count, 1)
    }

    func testResetDiscardsInFlightTextureAndPriorGenerationLocalAliases() async throws {
        let f = try fixture()
        XCTAssertEqual(update(f.scene, [ink("old")]), .supported)
        f.scene.rememberLocalMutation("reused-M")
        f.scene.rememberNativeAlias(mutationID: "reused-M", drawingID: "reused-D")
        XCTAssertEqual(update(f.scene, [ink("old"),object("pending")]), .preparing)
        try await wait { await f.gate.count == 1 }
        let oldWork = await f.gate.work(0)
        f.scene.reset()
        XCTAssertFalse(f.scene.hasAcceptedScene); XCTAssertFalse(f.scene.preparing)
        XCTAssertTrue(items(f.scene).isEmpty); XCTAssertTrue(hitIDs(f.scene).isEmpty)
        XCTAssertEqual(f.scene.retainedGeometryCount, 0)
        let fresh = ink("fresh")
        XCTAssertEqual(update(f.scene, [fresh]), .supported)
        await f.gate.finish(0, try XCTUnwrap(Textures.rasterize(oldWork)))
        try await wait { f.textures.accountedBytes == 0 }
        XCTAssertEqual(f.renderer.textureUploadCount, 0, "Old generation raster completion cannot publish")
        let rows = [fresh,object("new-text"),ink("reused-D", alias: "reused-M")]
        XCTAssertEqual(update(f.scene, rows), .preparing)
        XCTAssertEqual(hitIDs(f.scene), ["fresh"], "Old generation mutation IDs must not authorize a new optimistic tail")
        try await release(f, job: 1, expectedUploads: 1)
        XCTAssertEqual(update(f.scene, rows), .supported)
        XCTAssertEqual(hitIDs(f.scene), ["fresh","new-text","reused-D"])
    }

    func testUnavailableTextureReturnsExplicitUnsupportedRatherThanEndlessPreparing() async throws {
        let f = try fixture(byteLimit: 0), row = ink("accepted")
        XCTAssertEqual(update(f.scene, [row]), .supported)
        for _ in 0..<3 { XCTAssertEqual(update(f.scene, [row,object("no-budget")]), .unsupported) }
        XCTAssertFalse(f.scene.preparing)
        XCTAssertEqual(f.renderer.textureUploadCount, 0)
        let jobs = await f.gate.count; XCTAssertEqual(jobs, 0)
        XCTAssertEqual(update(f.scene, [row]), .supported)
        XCTAssertEqual(hitIDs(f.scene), ["accepted"])
    }

    func testDeletedPendingSourcesDoNotReserveBudgetAgainstReplacementScene() async throws {
        try await pendingReplacement(sameIDs: false)
    }

    func testSameIDPendingAppearanceReplacementRecoversAfterObsoleteWorker() async throws {
        try await pendingReplacement(sameIDs: true)
    }

    private func pendingReplacement(sameIDs: Bool) async throws {
        func padded(_ id: String, text: String) -> [String: Any] {
            var row = object(id, text: text)
            var data = row["data"] as! [String: Any]
            // Retained metadata dominates the tiny raster without a huge GPU allocation.
            data["syntheticPadding"] = String(repeating: "x", count: 32_768)
            row["data"] = data
            return row
        }
        let a = [padded("A1", text: "old-1"), padded("A2", text: "old-2")]
        let b = [padded(sameIDs ? "A1" : "B1", text: "new-1"),
                 padded(sameIDs ? "A2" : "B2", text: "new-2")]
        let sourceA = try a.map { try XCTUnwrap(Textures.capture(object: $0, pageSize: size)) }
        let sourceB = try b.map { try XCTUnwrap(Textures.capture(object: $0, pageSize: size)) }
        let worksA = try sourceA.map { try XCTUnwrap(Textures.work(source: $0, scale: 1)) }
        let worksB = try sourceB.map { try XCTUnwrap(Textures.work(source: $0, scale: 1)) }
        let bytesA = sourceA.reduce(0) { $0 + $1.byteCost }, bytesB = sourceB.reduce(0) { $0 + $1.byteCost }
        let jobsA = zip(sourceA, worksA).map { $0.0.byteCost + 2*$0.1.byteCount }
        let jobsB = zip(sourceB, worksB).map { $0.0.byteCost + 2*$0.1.byteCount }
        let limit = max(bytesA + (jobsA.max() ?? 0),
                        bytesB + (jobsB.max() ?? 0) + worksB.reduce(0) { $0 + $1.byteCount }) + 4096
        XCTAssertLessThan(bytesA, limit); XCTAssertLessThan(bytesB, limit)
        XCTAssertGreaterThan(bytesA + bytesB, limit, "Previous pending recordings must actually exceed the injected budget together")
        let f = try fixture(byteLimit: limit), accepted = ink("accepted")
        XCTAssertEqual(update(f.scene, [accepted]), .supported)
        let oldMesh = try XCTUnwrap(items(f.scene).first?.mesh)
        var desired = [accepted] + a
        var notifications = 0
        var lastResult = Scene.UpdateResult.supported
        f.scene.onResourcesChanged = {
            notifications += 1
            lastResult = self.update(f.scene, desired)
        }
        defer { f.scene.onResourcesChanged = nil; f.scene.reset(); Task { await f.gate.close() } }
        XCTAssertEqual(update(f.scene, desired), .preparing)
        try await wait { await f.gate.count == 1 }
        desired = [accepted] + b
        XCTAssertEqual(update(f.scene, desired), .preparing)
        XCTAssertTrue(items(f.scene).first?.mesh === oldMesh)
        XCTAssertEqual(f.scene.acceptedRevision, 1)
        let oldWork = await f.gate.work(0)
        await f.gate.finish(0, try XCTUnwrap(Textures.rasterize(oldWork)))
        try await wait { notifications > 0 }
        XCTAssertEqual(f.renderer.textureUploadCount, 0, "Obsolete A must never publish a texture")
        try await release(f, job: 1, expectedUploads: 1)
        try await release(f, job: 2, expectedUploads: 2)
        try await wait { lastResult == .supported && !f.scene.preparing }
        XCTAssertEqual(hitIDs(f.scene), ["accepted"] + (sameIDs ? ["A1", "A2"] : ["B1", "B2"]))
        XCTAssertTrue(items(f.scene).first?.mesh === oldMesh)
        XCTAssertEqual(f.scene.objectCount, 2)
        XCTAssertEqual(f.renderer.meshUploadCount, 1)
        XCTAssertLessThanOrEqual(f.textures.accountedBytes, limit)
        let totalJobs = await f.gate.count
        XCTAssertEqual(totalJobs, 3, "One obsolete job and exactly two latest object rasters")
    }

    private struct Fixture {
        let renderer: Renderer, textures: Textures, scene: Scene, gate: Gate
    }
    private func fixture(byteLimit: Int = 64 * 1024 * 1024) throws -> Fixture {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let renderer = try XCTUnwrap(Renderer(device: device)), gate = Gate()
        let textures = Textures(renderer: renderer, byteLimit: byteLimit, rasterize: { await gate.capture($0) })
        return Fixture(renderer: renderer, textures: textures, scene: Scene(renderer: renderer, textures: textures), gate: gate)
    }
    private func update(_ scene: Scene, _ rows: [[String: Any]], pageSize: CGSize? = nil) -> Scene.UpdateResult {
        scene.update(objects: rows, visualTokens: nil, pageSize: pageSize ?? size, scale: 1, image: { _ in nil })
    }
    private func items(_ scene: Scene, excluding: [String] = []) -> [Renderer.Item] {
        scene.items(transform: .identity, excludingIDs: excluding)
    }
    private func kinds(_ items: [Renderer.Item]) -> [String] { items.map { $0.mesh == nil ? "texture" : "mesh" } }
    private func hitIDs(_ scene: Scene) -> [String] {
        scene.hits(points: [CGPoint(x: 0.5,y: 0.5)], previous: nil).compactMap(\.drawingID)
    }
    private func release(_ f: Fixture, job: Int, expectedUploads: Int) async throws {
        try await wait { await f.gate.count > job }
        let work = await f.gate.work(job)
        let bitmap = try XCTUnwrap(Textures.rasterize(work))
        await f.gate.finish(job, bitmap)
        try await wait { f.textures.uploadCount == expectedUploads }
    }
    private func accept(_ f: Fixture, rows: [[String: Any]], job: Int) async throws {
        XCTAssertEqual(update(f.scene, rows), .preparing)
        try await release(f, job: job, expectedUploads: job + 1)
        XCTAssertEqual(update(f.scene, rows), .supported)
    }
    private func wait(_ predicate: @MainActor () async -> Bool) async throws {
        let deadline = CACurrentMediaTime() + 3
        while !(await predicate()), CACurrentMediaTime() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        guard await predicate() else { XCTFail("MixedScene texture boundary timed out"); throw NSError(domain: "MixedSceneTests", code: 1) }
    }
    private func ink(_ id: String, alias: String? = nil, highlighter: Bool = false) -> [String: Any] {
        var row: [String: Any] = ["id": id, "kind": highlighter ? "highlighter" : "ink",
            "data": ["inkVersion": 4,"points": [["x": 0.2,"y": 0.5,"p": 0.5],["x": 0.8,"y": 0.5,"p": 0.5]]],
            "style": ["color": "blue","width": 0.02,"opacity": 0.5]]
        if let alias { row["clientMutationId"] = alias }; return row
    }
    private func object(_ id: String, text: String = "Synthetic text", data: [String: Any]? = nil) -> [String: Any] {
        ["id": id,"kind": "textbox", "data": data ?? ["box": ["x": 0.2,"y": 0.3,"width": 0.6,"height": 0.4],"text": text],
         "style": ["color": "red","width": 0.004,"opacity": 0.6,"fontSizePt": 12]]
    }
    private func legacyMarker(_ id: String) -> [String: Any] {
        ["id": id,"kind": "highlighter", "data": ["points": [["x": 0.2,"y": 0.5,"p": 0.5],["x": 0.8,"y": 0.5,"p": 0.5]]],
         "nativePath": "M 0.2 0.45 L 0.8 0.45 L 0.8 0.55 L 0.2 0.55 Z",
         "style": ["color": "yellow","width": 0.1,"opacity": 0.3]]
    }
    private actor Gate {
        struct Pending { let work: Textures.Work; var reply: CheckedContinuation<Textures.Bitmap?, Never>? }
        private var jobs: [Pending] = []
        private var closed = false
        var count: Int { jobs.count }
        func work(_ index: Int) -> Textures.Work { jobs[index].work }
        func capture(_ work: Textures.Work) async -> Textures.Bitmap? {
            guard !closed else { return nil }
            return await withCheckedContinuation { jobs.append(Pending(work: work, reply: $0)) }
        }
        func close() {
            closed = true
            for index in jobs.indices { finish(index, nil) }
        }
        func finish(_ index: Int, _ bitmap: Textures.Bitmap?) {
            let reply = jobs[index].reply; jobs[index].reply = nil; reply?.resume(returning: bitmap)
        }
    }
}
