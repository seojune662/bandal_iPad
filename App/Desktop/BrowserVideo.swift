import Foundation
import WebKit

/// What a page's main video is doing, as the script in its frame last reported it.
struct BrowserVideoState: Equatable {
    var playing = false
    var muted = false
    var time = 0.0
    var duration = 0.0
    /// The element's size on screen in CSS pixels squared: the largest video is the one a person watches.
    var area = 0.0
    /// Where it was on the frame's visible area at the event (fractions), so a PiP window opens in its shape.
    var rect: CGRect?
    init(playing: Bool = false, muted: Bool = false, time: Double = 0, duration: Double = 0, area: Double = 0, rect: CGRect? = nil) {
        self.playing = playing; self.muted = muted; self.time = time; self.duration = duration; self.area = area; self.rect = rect
    }
    init?(_ body: [String: Any]) {
        guard body["none"] == nil, let playing = body["playing"] as? Bool else { return nil }
        func number(_ key: String) -> Double { ((body[key] as? NSNumber)?.doubleValue).flatMap { $0.isFinite ? $0 : nil } ?? 0 }
        self.init(playing: playing, muted: body["muted"] as? Bool ?? false, time: max(0, number("time")),
                  duration: max(0, number("duration")), area: max(0, number("area")), rect: BrowserVideoFrame.rect(body["rect"]))
    }
    /// Worth a PiP button: big enough to be the thing on the page (a 16:9 video about 130 pt wide or more).
    var isWatchable: Bool { area >= 9_000 }
    /// Leaving the tab moves it to PiP only while it plays with sound: a muted preview or a background loop stays.
    var continuesInPiP: Bool { isWatchable && playing && !muted }
    /// Playing first, then sound, then size.
    static func preferred(_ a: BrowserVideoState, over b: BrowserVideoState) -> Bool {
        if a.playing != b.playing { return a.playing }
        if a.muted != b.muted { return !a.muted }
        return a.area > b.area
    }
}

/// One frame's report. A video in an iframe (an embedded lecture player) is controlled in that frame; nil is the main frame.
struct BrowserVideoReport {
    let frame: WKFrameInfo?
    let key: String
    var state: BrowserVideoState
    var isMainFrame: Bool { frame?.isMainFrame ?? true }
    static func key(_ frame: WKFrameInfo?) -> String {
        guard let frame, !frame.isMainFrame else { return "main" }
        let origin = frame.securityOrigin
        return "\(origin.protocol)://\(origin.host):\(origin.port) " + (frame.request.url?.absoluteString ?? "")
    }
}

/// Where the chosen video sits, as fractions of the web view's visible area.
struct BrowserVideoFrame: Equatable {
    var rect: CGRect
    var state: BrowserVideoState
    init?(_ body: Any?) {
        guard let body = body as? [String: Any], let rect = Self.rect(body["rect"]), let state = BrowserVideoState(body) else { return nil }
        self.rect = rect; self.state = state
    }
    /// `{x, y, w, h}` from the script; nil when empty or not finite.
    static func rect(_ value: Any?) -> CGRect? {
        guard let rect = value as? [String: Any] else { return nil }
        func number(_ key: String) -> CGFloat? { (rect[key] as? NSNumber).map { CGFloat($0.doubleValue) }.flatMap { $0.isFinite ? $0 : nil } }
        guard let x = number("x"), let y = number("y"), let width = number("w"), let height = number("h"), width > 0, height > 0 else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }
    init(rect: CGRect, state: BrowserVideoState) { self.rect = rect; self.state = state }
    /// A video inside an iframe: its rectangle in the frame, placed in the iframe's rectangle on the page.
    func placed(in frame: CGRect) -> BrowserVideoFrame {
        BrowserVideoFrame(rect: CGRect(x: frame.minX + rect.minX * frame.width, y: frame.minY + rect.minY * frame.height,
                                       width: rect.width * frame.width, height: rect.height * frame.height), state: state)
    }
}

enum BrowserVideoScripts {
    static let world = WKContentWorld.world(name: "BandalVideo")
    static let handler = "bandalVideo"
    /// Runs in every frame, in its own world: the page cannot read or call it. Media events do not bubble, so
    /// the window listens while they travel down (capture); `composedPath` finds a video inside a shadow root.
    static let observe = """
    (()=>{if(globalThis.__bandalVideo)return;
    const known=new Set();let selected=null,timer=0;
    const post=m=>{try{webkit.messageHandlers.\(handler).postMessage(m)}catch(e){}};
    const all=()=>{const list=new Set(document.querySelectorAll('video'));for(const r of known){const v=r.deref();if(v&&v.isConnected)list.add(v);else known.delete(r)}return[...list]};
    const box=e=>{const r=e.getBoundingClientRect();return Math.max(0,r.width)*Math.max(0,r.height)};
    const playing=v=>!v.paused&&!v.ended;
    const muted=v=>v.muted||v.volume===0;
    const best=()=>{let pick=null,score=-1;for(const v of all()){const a=box(v);if(a<1)continue;const s=(playing(v)?4e12:0)+(muted(v)?0:2e12)+a;if(s>score){pick=v;score=s}}return pick};
    const state=v=>({playing:playing(v),muted:muted(v),time:v.currentTime||0,duration:isFinite(v.duration)?v.duration:0,area:box(v),rect:place(v)});
    const view=()=>{const p=globalThis.visualViewport;return p?{x:p.offsetLeft,y:p.offsetTop,w:p.width,h:p.height}:{x:0,y:0,w:innerWidth,h:innerHeight}};
    const place=e=>{const r=e.getBoundingClientRect(),p=view();return{x:(r.left-p.x)/p.w,y:(r.top-p.y)/p.h,w:r.width/p.w,h:r.height/p.h}};
    const current=()=>{if(!selected||!selected.isConnected)selected=best();return selected};
    const report=()=>{timer=0;const v=selected&&selected.isConnected?selected:best();post(v?state(v):{none:true})};
    const schedule=()=>{if(!timer)timer=setTimeout(report,120)};
    const note=e=>{const t=e.composedPath?e.composedPath()[0]:e.target;if(!(t instanceof HTMLVideoElement))return;let seen=false;for(const r of known)if(r.deref()===t)seen=true;if(!seen)known.add(new WeakRef(t));schedule()};
    for(const type of['play','playing','pause','ended','emptied','loadedmetadata','volumechange','seeked'])addEventListener(type,note,true);
    globalThis.__bandalVideo={
      select(){selected=best();return selected?state(selected):null},
      current(){const v=current();return v?state(v):null},
      play(){const v=current();if(!v)return false;const p=v.play();if(p&&p.catch)p.catch(()=>{});return true},
      pause(){const v=current();if(v)v.pause();return!!v},
      skip(s){const v=current();if(!v)return false;const end=isFinite(v.duration)?v.duration:Infinity;v.currentTime=Math.max(0,Math.min(end,(v.currentTime||0)+s));return true},
      release(){selected=null},
      frame(url,origin){const frames=[...document.querySelectorAll('iframe,frame')].filter(f=>box(f)>0);
        const path=s=>{try{const u=new URL(s,location.href);return u.origin+u.pathname}catch(e){return''}};
        const from=s=>{try{return new URL(s,location.href).origin}catch(e){return''}};
        const f=frames.find(f=>path(f.src)===path(url))||frames.filter(f=>from(f.src)===origin).sort((a,b)=>box(b)-box(a))[0];
        return f?place(f):null}
    };
    })();
    """
}

/// Messages from the video script. Pages a PiP window holds after their tab closed are still heard.
final class BrowserVideoRelay: NSObject, WKScriptMessageHandler {
    weak var host: DesktopBrowserHost?
    init(host: DesktopBrowserHost) { self.host = host }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard let view = message.webView, let host,
                  let page = host.pages.values.first(where: { $0.liveWebView === view }) ?? host.pictureInPicturePages.values.first(where: { $0.liveWebView === view }),
                  let body = message.body as? [String: Any] else { return }
            page.receiveVideo(BrowserVideoState(body), frame: message.frameInfo)
        }
    }
}

@MainActor
extension DesktopBrowserPage {
    /// The frame to control and what its video is doing: the best report across the page's frames.
    var video: BrowserVideoReport? {
        videoReports.max { BrowserVideoState.preferred($1.state, over: $0.state) }
    }
    func receiveVideo(_ state: BrowserVideoState?, frame: WKFrameInfo?) {
        let key = BrowserVideoReport.key(frame)
        let before = video?.state
        videoReports.removeAll { $0.key == key }
        if let state { videoReports.append(BrowserVideoReport(frame: frame, key: key, state: state)) }
        guard video?.state != before else { return }
        send("video-state", ["playing": video?.state.playing ?? false, "watchable": video?.state.isWatchable ?? false])
        host?.onVideoChange?(self)
    }
    func forgetVideo() {
        guard !videoReports.isEmpty else { return }
        videoReports = []
        send("video-state", ["playing": false, "watchable": false])
        host?.onVideoChange?(self)
    }
    @discardableResult
    func videoCall(_ body: String, arguments: [String: Any] = [:], frame: WKFrameInfo?) async throws -> Any? {
        guard let view = liveWebView else { return nil }
        return try await view.callAsyncJavaScript(body, arguments: arguments, in: frame, contentWorld: BrowserVideoScripts.world)
    }
    /// The video's rectangle in the web view, as fractions of its visible area. A video in an iframe is placed
    /// within the iframe's rectangle on the page.
    func videoFrame(select: Bool, in report: BrowserVideoReport) async throws -> BrowserVideoFrame? {
        guard let inner = BrowserVideoFrame(try await videoCall(select ? "return __bandalVideo.select()" : "return __bandalVideo.current()", frame: report.frame)) else { return nil }
        guard let frame = report.frame, !frame.isMainFrame else { return inner }
        let origin = frame.securityOrigin
        let originText = "\(origin.protocol)://\(origin.host)" + (origin.port == 0 ? "" : ":\(origin.port)")
        let outer = try await videoCall("return __bandalVideo.frame(url, origin)",
            arguments: ["url": frame.request.url?.absoluteString ?? "", "origin": originText], frame: nil)
        guard let rect = BrowserVideoFrame.rect(outer) else { return nil }
        return inner.placed(in: rect)
    }
}
