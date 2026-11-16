import XCTest
import UIKit
@testable import Bandal

/// 영상 PiP: the window's size and place, what a page's video report means, and the browser host handing a page to
/// the window and back.
@MainActor
final class NativeVideoPiPTests: XCTestCase {
    typealias Geometry = NativeVideoPiPGeometry
    private let area = CGRect(x: 0, y: 0, width: 1366, height: 1024)

    // MARK: Size and place

    func testSizeKeepsTheVideoShapeBetweenMinimumAndMaximum() {
        let wide = Geometry.size(width: 400, aspect: 16 / 9, in: area)
        XCTAssertEqual(wide.width, 400); XCTAssertEqual(wide.height, 225, accuracy: 0.01)
        XCTAssertEqual(Geometry.size(width: 50, aspect: 16 / 9, in: area).width, Geometry.minimumWidth, "Never smaller than the minimum")
        let largest = Geometry.size(width: 5000, aspect: 16 / 9, in: area)
        XCTAssertEqual(largest.width, (area.width - 2 * Geometry.margin) * Geometry.maximumShare, accuracy: 0.01, "At most 80 % of the width")
        // A tall clip is held by the height: 80 % of what is left above and below.
        let tall = Geometry.size(width: 5000, aspect: 9 / 16, in: area)
        XCTAssertEqual(tall.height, (area.height - 2 * Geometry.margin) * Geometry.maximumShare, accuracy: 0.5)
        XCTAssertEqual(tall.width / tall.height, 9 / 16, accuracy: 0.001)
        // A very narrow split view: the largest that fits wins over the minimum.
        let narrow = CGRect(x: 0, y: 0, width: 220, height: 400)
        XCTAssertLessThanOrEqual(Geometry.size(width: 300, aspect: 16 / 9, in: narrow).width, 220 - 2 * Geometry.margin)
        // A broken shape (a 1 px page video, NaN) falls back to sane bounds.
        XCTAssertEqual(Geometry.clampAspect(.nan), 16 / 9); XCTAssertEqual(Geometry.clampAspect(40), 3); XCTAssertEqual(Geometry.clampAspect(0.01), 0.5)
    }

    func testClampAndSnapKeepTheWindowInsideAndAgainstNearEdges() {
        let outside = Geometry.clamp(CGRect(x: -100, y: 2000, width: 300, height: 169), in: area)
        XCTAssertEqual(outside.minX, Geometry.margin); XCTAssertEqual(outside.maxY, area.maxY - Geometry.margin)
        let near = Geometry.snap(CGRect(x: 30, y: 500, width: 300, height: 169), in: area)
        XCTAssertEqual(near.minX, Geometry.margin, "Within the snap distance it sits against the left edge")
        XCTAssertEqual(near.minY, 500, "Far from the top and bottom it stays where it was put")
        let right = Geometry.snap(CGRect(x: area.maxX - 330, y: 20, width: 300, height: 169), in: area)
        XCTAssertEqual(right.maxX, area.maxX - Geometry.margin); XCTAssertEqual(right.minY, Geometry.margin)
        let thrown = Geometry.projected(CGRect(x: 600, y: 400, width: 300, height: 169), velocity: CGPoint(x: 6000, y: 0), in: area)
        XCTAssertEqual(thrown.maxX, area.maxX - Geometry.margin, "A flick carries it to the edge it was thrown at")
    }

    func testCornerDragResizesFromTheOppositeCornerAndPinchFromTheCentre() {
        let frame = CGRect(x: 100, y: 100, width: 320, height: 180)
        let grown = Geometry.resized(frame, corner: .bottomTrailing, by: CGPoint(x: 160, y: 10), aspect: 16 / 9, in: area)
        XCTAssertEqual(grown.origin, frame.origin, "The top-left corner stays")
        XCTAssertEqual(grown.width, 480, accuracy: 0.01); XCTAssertEqual(grown.width / grown.height, 16 / 9, accuracy: 0.001)
        let fromTopLeft = Geometry.resized(frame, corner: .topLeading, by: CGPoint(x: 80, y: 0), aspect: 16 / 9, in: area)
        XCTAssertEqual(fromTopLeft.maxX, frame.maxX, accuracy: 0.01); XCTAssertEqual(fromTopLeft.maxY, frame.maxY, accuracy: 0.01)
        XCTAssertEqual(fromTopLeft.width, 240, accuracy: 0.01, "Dragging the top-left corner inward makes it smaller")
        // The longer pull wins: mostly downward on a bottom corner grows by the height.
        let roomy = frame.offsetBy(dx: 500, dy: 0)
        let down = Geometry.resized(roomy, corner: .bottomLeading, by: CGPoint(x: 0, y: 90), aspect: 16 / 9, in: area)
        XCTAssertEqual(down.height, 270, accuracy: 0.01); XCTAssertEqual(down.maxX, roomy.maxX, accuracy: 0.01); XCTAssertEqual(down.minY, roomy.minY)
        // Near the left edge the same pull keeps the window on screen rather than the corner where it was.
        XCTAssertEqual(Geometry.resized(frame, corner: .bottomLeading, by: CGPoint(x: 0, y: 90), aspect: 16 / 9, in: area).minX, Geometry.margin)
        let pinched = Geometry.scaled(frame, by: 1.5, aspect: 16 / 9, in: area)
        XCTAssertEqual(pinched.midX, frame.midX, accuracy: 0.01); XCTAssertEqual(pinched.midY, frame.midY, accuracy: 0.01)
        XCTAssertEqual(pinched.width, 480, accuracy: 0.01)
        XCTAssertEqual(Geometry.scaled(frame, by: 0.1, aspect: 16 / 9, in: area).width, Geometry.minimumWidth)
        XCTAssertEqual(Geometry.corner(at: CGPoint(x: 4, y: 4), in: frame.size), .topLeading)
        XCTAssertEqual(Geometry.corner(at: CGPoint(x: 316, y: 176), in: frame.size), .bottomTrailing)
        XCTAssertNil(Geometry.corner(at: CGPoint(x: 160, y: 90), in: frame.size), "The middle moves the window")
    }

    func testPlacementIsRememberedAndFittedToANewArea() {
        let first = Geometry.frame(for: nil, aspect: 16 / 9, in: area)
        XCTAssertEqual(first.maxX, area.maxX - Geometry.margin); XCTAssertEqual(first.maxY, area.maxY - Geometry.margin, accuracy: 0.01)
        XCTAssertEqual(first.width, Geometry.defaultWidth, "The first time: the bottom-trailing corner, default width")
        let placed = CGRect(x: Geometry.margin, y: 300, width: 420, height: 236.25)
        let saved = Geometry.placement(of: placed, in: area)
        let data = try! JSONEncoder().encode(saved)
        let restored = Geometry.frame(for: try! JSONDecoder().decode(Geometry.Placement.self, from: data), aspect: 16 / 9, in: area)
        XCTAssertEqual(restored.minX, placed.minX, accuracy: 0.5); XCTAssertEqual(restored.minY, placed.minY, accuracy: 0.5)
        XCTAssertEqual(restored.width, 420, accuracy: 0.01)
        // Rotated to portrait: still on the left edge, at the same height share, inside the screen.
        let portrait = CGRect(x: 0, y: 0, width: 1024, height: 1366)
        let turned = Geometry.frame(for: saved, aspect: 16 / 9, in: portrait)
        XCTAssertEqual(turned.minX, Geometry.margin); XCTAssertTrue(portrait.insetBy(dx: Geometry.margin - 0.5, dy: Geometry.margin - 0.5).contains(turned))
        // The video's shape changes (another clip on the page): same width, same centre.
        let reshaped = Geometry.reshaped(CGRect(x: 500, y: 400, width: 320, height: 180), aspect: 4 / 3, in: area)
        XCTAssertEqual(reshaped.width, 320); XCTAssertEqual(reshaped.height, 240); XCTAssertEqual(reshaped.midY, 490)
    }

    func testTheKeyboardShrinksTheAreaAndTheWindowMovesAboveIt() {
        let keyboard = CGRect(x: 0, y: 700, width: 1366, height: 324)
        let free = Geometry.area(area, keyboard: keyboard)
        XCTAssertEqual(free.maxY, 700)
        let window = Geometry.reshaped(CGRect(x: 1000, y: 800, width: 340, height: 191.25), aspect: 16 / 9, in: free)
        XCTAssertLessThanOrEqual(window.maxY, 700 - Geometry.margin, "The window sits above the keyboard")
        XCTAssertEqual(Geometry.area(area, keyboard: nil), area)
        XCTAssertEqual(Geometry.area(area, keyboard: CGRect(x: 0, y: 2000, width: 1366, height: 300)), area, "A keyboard off screen (a hardware keyboard's bar elsewhere)")
        XCTAssertEqual(Geometry.area(area, keyboard: CGRect(x: 400, y: 500, width: 320, height: 260)), area, "A floating keyboard does not push the window up")
    }

    // MARK: Playback

    func testSkipStaysInsideTheVideo() {
        XCTAssertEqual(NativeVideoPiPPlayback.skipTarget(from: 5, by: -10, duration: 60), 0)
        XCTAssertEqual(NativeVideoPiPPlayback.skipTarget(from: 55, by: 10, duration: 60), 60)
        XCTAssertEqual(NativeVideoPiPPlayback.skipTarget(from: 20, by: 10, duration: 60), 30)
        XCTAssertEqual(NativeVideoPiPPlayback.skipTarget(from: 20, by: 10, duration: .nan), 30, "A live stream has no end")
        XCTAssertEqual(NativeVideoPiPPlayback.skipTarget(from: .nan, by: 10, duration: 60), 10)
        XCTAssertEqual(NativeVideoPiPControls.clock(75), "1:15"); XCTAssertEqual(NativeVideoPiPControls.clock(3725), "1:02:05")
        XCTAssertEqual(NativeVideoPiPControls.clock(.nan), "0:00")
    }

    // MARK: A page's video

    func testVideoReportsChooseThePlayingVideoWithSound() {
        XCTAssertNil(BrowserVideoState(["none": true]))
        let playing = BrowserVideoState(["playing": true, "muted": false, "time": 12.5, "duration": 600, "area": 360_000])!
        XCTAssertTrue(playing.continuesInPiP)
        let preview = BrowserVideoState(["playing": true, "muted": true, "area": 360_000])!
        XCTAssertTrue(preview.isWatchable); XCTAssertFalse(preview.continuesInPiP, "A muted preview stays when its tab is left")
        let thumbnail = BrowserVideoState(["playing": true, "area": 2_000])!
        XCTAssertFalse(thumbnail.isWatchable, "A thumbnail-sized loop gets no PiP button")
        let paused = BrowserVideoState(["playing": false, "area": 900_000])!
        XCTAssertFalse(paused.continuesInPiP)
        XCTAssertTrue(BrowserVideoState.preferred(playing, over: paused), "Playing beats bigger")
        XCTAssertTrue(BrowserVideoState.preferred(playing, over: preview), "Sound beats muted")
        XCTAssertEqual(BrowserVideoState(["playing": true, "time": Double.infinity])?.time, 0, "Non-finite numbers read as zero")
    }

    func testAVideoInAnIframeIsPlacedInTheIframesRectangle() {
        let inner = BrowserVideoFrame(["playing": true, "rect": ["x": 0.1, "y": 0.2, "w": 0.8, "h": 0.6]])!
        let placed = inner.placed(in: CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25))
        XCTAssertEqual(placed.rect.minX, 0.3, accuracy: 1e-9); XCTAssertEqual(placed.rect.minY, 0.55, accuracy: 1e-9)
        XCTAssertEqual(placed.rect.width, 0.4, accuracy: 1e-9); XCTAssertEqual(placed.rect.height, 0.15, accuracy: 1e-9)
        XCTAssertNil(BrowserVideoFrame(["playing": true, "rect": ["x": 0, "y": 0, "w": 0, "h": 0.5]]), "An empty rectangle is no video")
        XCTAssertNil(BrowserVideoFrame.rect(["x": 0, "y": 0, "w": Double.nan, "h": 1]))
    }

    // MARK: The browser host and the window

    private final class Window: DesktopBrowserPictureInPicture {
        var takes = true, keeps = true, returning = false
        var hidden: [String] = [], closed: [String] = []
        weak var holder: UIView?
        func browserPageWillHide(_ page: DesktopBrowserPage) -> Bool {
            hidden.append(page.tabID)
            guard takes, let holder else { return false }
            page.inPictureInPicture = true; holder.addSubview(page.webView)
            return true
        }
        func browserPageWillClose(_ page: DesktopBrowserPage) -> Bool { closed.append(page.tabID); return keeps && page.inPictureInPicture }
        func browserPage(_ page: DesktopBrowserPage, returnsTo target: UIView) -> Bool {
            guard returning else { return false }
            page.inPictureInPicture = false; target.addSubview(page.webView)
            return true
        }
    }

    func testTheHostHandsAPageToTheWindowKeepsItAfterItsTabClosesAndTakesItBack() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("browser-pip-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let host = DesktopBrowserHost(root: root)
        let screen = UIWindow(frame: CGRect(x: 0, y: 0, width: 1000, height: 800)); screen.isHidden = false
        defer { screen.isHidden = true }
        let surface = UIView(frame: CGRect(x: 0, y: 0, width: 800, height: 600)), holder = UIView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        screen.addSubview(surface); screen.addSubview(holder)
        let window = Window(); window.holder = holder
        host.pictureInPicture = window
        let page = try host.createPage(tabID: "video", profileID: "default", isPrivate: false, courseID: nil)
        _ = try host.createPage(tabID: "other", profileID: "default", isPrivate: false, courseID: nil)
        host.attachNative(to: surface, selectedTabID: "video")
        XCTAssertTrue(page.webView.superview === surface); XCTAssertNotNil(page.bounds)

        // Another tab chosen: the window is asked first and takes the web view, still on screen.
        host.attachNative(to: surface, selectedTabID: "other")
        XCTAssertEqual(window.hidden, ["video"])
        XCTAssertTrue(page.webView.superview === holder); XCTAssertNotNil(page.webView.window)
        XCTAssertFalse(page.webView.isHidden, "The page was not hidden under the window")
        XCTAssertNil(page.bounds)
        // Its tab shows again while the window still plays it: the web view stays in the window.
        window.takes = false
        host.attachNative(to: surface, selectedTabID: "video")
        XCTAssertTrue(page.webView.superview === holder)
        XCTAssertNil(page.bounds, "Its tab shows 'PiP에서 재생 중', not the page")

        // Its tab closes: the page lives on for the window, out of every tab.
        host.destroy("video")
        XCTAssertNil(host.pages["video"]); XCTAssertTrue(host.pictureInPicturePages["video"] === page)
        XCTAssertNotNil(page.liveWebView, "Not closed")
        // 돌아가기: the page becomes its scope's page again, and the tab's viewport takes the web view.
        host.adoptPictureInPicturePage(page)
        XCTAssertTrue(host.pages["video"] === page); XCTAssertNil(host.pictureInPicturePages["video"])
        window.returning = true
        host.layoutPages()
        XCTAssertTrue(page.webView.superview === surface); XCTAssertFalse(page.inPictureInPicture); XCTAssertNotNil(page.bounds)

        // Leaving the surface (a dock tab closing) offers the window the visible page before it goes.
        window.hidden = []; window.takes = false
        host.surfaceWillLeaveWindow(surface)
        XCTAssertEqual(window.hidden, ["video"])
        // A page the window does not hold closes with its tab; one it holds but released is closed for good.
        window.keeps = false
        host.destroy("other"); XCTAssertNil(host.pictureInPicturePages["other"])
        window.takes = true; window.keeps = true
        host.attachNative(to: surface, selectedTabID: "other") // `video` loses its viewport → the window takes it
        host.destroy("video"); XCTAssertTrue(host.pictureInPicturePages["video"] === page)
        host.releasePictureInPicturePage(page)
        XCTAssertNil(host.pictureInPicturePages["video"]); XCTAssertNil(page.liveWebView?.superview, "Closed with the window")
        XCTAssertFalse(page.inPictureInPicture)
    }

    func testAPrivatePageNeverOutlivesItsTab() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("browser-pip-private-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let host = DesktopBrowserHost(root: root)
        let window = Window(); host.pictureInPicture = window
        let page = try host.createPage(tabID: "private", profileID: "default", isPrivate: true, courseID: nil)
        page.inPictureInPicture = true
        host.destroy("private")
        XCTAssertEqual(window.closed, ["private"])
        XCTAssertNil(host.pictureInPicturePages["private"]); XCTAssertFalse(page.inPictureInPicture, "Closed")
    }
}
