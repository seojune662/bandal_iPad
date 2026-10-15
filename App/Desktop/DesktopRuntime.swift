import Foundation
import JavaScriptCore

/// A single JavaScriptCore queue runs the original desktop repositories. The
/// renderer keeps Electron's asynchronous IPC contract; SQL/file operations
/// inside each repository retain their synchronous, atomic semantics.
final class DesktopRuntime: @unchecked Sendable {
    let root: URL
    let legacyRoot: URL
    let log: DesktopLog
    var onEmit: ((String, Any) -> Void)?
    var onNativeCall: ((String, [String: Any]) async throws -> Any)?
    private let queue = DispatchQueue(label: "app.bandal.desktop-repositories", qos: .userInitiated)
    private var context: JSContext?
    private var primitives: DesktopNativePrimitives?
    private var continuations: [String: CheckedContinuation<Any, Error>] = [:]
    private var timers: [Int: DispatchWorkItem] = [:]
    private var timerSequence = 0
    private var initialization: Task<Void, Error>?

    init(root: URL, legacyRoot: URL) { self.root = root; self.legacyRoot = legacyRoot; log = DesktopLog(root: root) }

    @MainActor
    func start(bundleURL: URL? = nil) async throws {
        if let initialization { return try await initialization.value }
        let task = Task { try await load(bundleURL: bundleURL) }
        initialization = task
        try await task.value
    }

    private func load(bundleURL: URL?) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    let native = try DesktopNativePrimitives(root: self.root, legacyRoot: self.legacyRoot)
                    native.onEmit = { [weak self] channel, payload in self?.onEmit?(channel, payload) }
                    guard let context = JSContext() else { throw DesktopRuntimeError("JavaScriptCore could not start") }
                    self.context = context
                    self.primitives = native
                    context.setObject(native, forKeyedSubscript: "__bandalNative" as NSString)
                    self.installEnvironment(context)
                    guard let url = bundleURL ?? Bundle.main.resourceURL?.appendingPathComponent("Desktop/backend.js"), FileManager.default.fileExists(atPath: url.path) else {
                        throw DesktopRuntimeError("The desktop backend bundle is missing. Run the DesktopRuntime build.")
                    }
                    context.evaluateScript(try String(contentsOf: url, encoding: .utf8), withSourceURL: url)
                    if let error = context.exception { throw DesktopRuntimeError(error.toString()) }
                    guard context.objectForKeyedSubscript("BandalBackend")?.isObject == true else { throw DesktopRuntimeError("BandalBackend was not exported") }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
        _ = try await call(method: "initialize", args: [])
        log.record("runtime.started")
    }

    func invoke(_ channel: String, request: Any = [:]) async throws -> Any {
        try await call(method: "invoke", args: [channel, request])
    }

    /// Native orchestration only. This dispatcher is never exposed through the
    /// renderer's IPC registry or an external web view.
    func invokePrivate(_ channel: String, request: Any = [:]) async throws -> Any {
        try await call(method: "invokePrivate", args: [channel, request])
    }

    func readMaterial(courseID: String, relativePath: String) async throws -> Data {
        let response = try await invoke("materials:readFile", request: ["courseId": courseID, "relPath": relativePath])
        if let object = response as? [String: Any] {
            if let encoded = object["__bandalBytes"] as? String, let bytes = Data(base64Encoded: encoded) { return bytes }
            if let encoded = object["data"] as? String {
                if object["encoding"] as? String == "base64", let bytes = Data(base64Encoded: encoded) { return bytes }
                return Data(encoded.utf8)
            }
        }
        throw DesktopRuntimeError("Material response has no file data")
    }

    private func call(method: String, args: [Any]) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard let context = self.context else { continuation.resume(throwing: DesktopRuntimeError("Desktop runtime has not started")); return }
                let identifier = UUID().uuidString
                self.continuations[identifier] = continuation
                context.exception = nil
                context.objectForKeyedSubscript("__bandalCall")?.call(withArguments: [identifier, method, args])
                if let exception = context.exception, let waiting = self.continuations.removeValue(forKey: identifier) {
                    waiting.resume(throwing: DesktopRuntimeError(exception.toString()))
                    context.exception = nil
                }
            }
        }
    }

    private func installEnvironment(_ context: JSContext) {
        let requestNative: @convention(block) (String, String, String) -> Void = { [weak self] identifier, channel, payload in
            guard let self else { return }
            Task {
                let envelope: [String: Any]
                do {
                    guard let handler = self.onNativeCall else { throw DesktopRuntimeError("Native service is unavailable: \(channel)", code: "ENOSYS") }
                    let input = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] ?? [:]
                    envelope = ["ok": true, "value": try await handler(channel, input)]
                } catch { envelope = ["ok": false, "error": ["message": error.localizedDescription, "code": (error as? DesktopRuntimeError)?.code ?? "ERR_NATIVE_SERVICE"]] }
                let encoded = (try? JSONSerialization.data(withJSONObject: envelope, options: .fragmentsAllowed)).map { String(decoding: $0, as: UTF8.self) } ?? "{\"ok\":false,\"error\":{\"message\":\"Invalid native response\"}}"
                self.queue.async { self.context?.objectForKeyedSubscript("__bandalNativeComplete")?.call(withArguments: [identifier, encoded]) }
            }
        }
        context.setObject(requestNative, forKeyedSubscript: "__bandalNativeRequest" as NSString)
        let complete: @convention(block) (String, String) -> Void = { [weak self] identifier, payload in
            guard let self, let continuation = self.continuations.removeValue(forKey: identifier) else { return }
            do {
                // A backend reply crosses into WKWebView again. Preserve the
                // JSON number's binary value instead of NSDecimalNumber's
                // lossy doubleValue conversion (notably final Pencil force).
                let result = try DesktopJSON.decode(Data(payload.utf8)) as? [String: Any]
                if result?["ok"] as? Bool == true { continuation.resume(returning: result?["value"] ?? NSNull()) }
                else {
                    let error = result?["error"] as? [String: Any]
                    continuation.resume(throwing: DesktopRuntimeError(error?["message"] as? String ?? "Desktop operation failed", code: error?["code"] as? String ?? "ERR_DESKTOP_RUNTIME"))
                }
            } catch { continuation.resume(throwing: error) }
        }
        context.setObject(complete, forKeyedSubscript: "__bandalComplete" as NSString)
        let schedule: @convention(block) (JSValue, Double) -> Int = { [weak self] callback, delay in
            guard let self else { return 0 }
            self.timerSequence += 1
            let identifier = self.timerSequence
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.timers.removeValue(forKey: identifier) != nil else { return }
                callback.call(withArguments: [])
            }
            self.timers[identifier] = work
            self.queue.asyncAfter(deadline: .now() + min(max(delay.isFinite ? delay : 0, 0), 2_147_483_647) / 1000, execute: work)
            return identifier
        }
        let cancel: @convention(block) (Int) -> Void = { [weak self] identifier in self?.timers.removeValue(forKey: identifier)?.cancel() }
        context.setObject(schedule, forKeyedSubscript: "__bandalSchedule" as NSString)
        context.setObject(cancel, forKeyedSubscript: "__bandalCancel" as NSString)
        context.evaluateScript("""
        globalThis.console = Object.fromEntries(['log','info','warn','error','debug'].map(level => [level, (...args) => __bandalNative.log(level, args.map(x => typeof x === 'string' ? x : JSON.stringify(x)).join(' '))]));
        globalThis.performance = { now: () => Date.now() };
        globalThis.setTimeout = (fn, delay = 0, ...args) => __bandalSchedule(() => fn(...args), Number(delay));
        globalThis.clearTimeout = id => __bandalCancel(Number(id));
        const intervals = new Map(); let intervalSequence = 0;
        globalThis.setInterval = (fn, delay = 0, ...args) => { const id = ++intervalSequence; const tick = () => { if (!intervals.has(id)) return; fn(...args); if (intervals.has(id)) intervals.set(id, setTimeout(tick, delay)); }; intervals.set(id, setTimeout(tick, delay)); return id; };
        globalThis.clearInterval = id => { clearTimeout(intervals.get(id)); intervals.delete(id); };
        globalThis.queueMicrotask = fn => Promise.resolve().then(fn);
        const nativePending = new Map(); let nativeSequence = 0;
        globalThis.__bandalPlatform = { invoke: (channel, request = {}) => new Promise((resolve, reject) => { const id = String(++nativeSequence); nativePending.set(id, {resolve,reject}); __bandalNativeRequest(id, channel, JSON.stringify(request)); }) };
        globalThis.__bandalNativeComplete = (id, raw) => { const pending = nativePending.get(id); if (!pending) return; nativePending.delete(id); try { const result = JSON.parse(raw); if (result.ok) pending.resolve(result.value); else { const error = new Error(result.error?.message ?? 'Native service failed'); error.code = result.error?.code; pending.reject(error); } } catch (error) { pending.reject(error); } };
        globalThis.__bandalCall = (id, method, args) => {
          Promise.resolve().then(() => BandalBackend[method](...args)).then(value => {
            __bandalComplete(id, JSON.stringify({ok:true,value:value === undefined ? null : value}));
          }, error => __bandalComplete(id, JSON.stringify({ok:false,error:{message:String(error?.message ?? error),code:error?.code}})));
        };
        """)
    }
}
