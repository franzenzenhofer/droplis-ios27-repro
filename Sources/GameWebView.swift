import SwiftUI
import WebKit
import UIKit
import os
import AVFoundation

struct GameWebView: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let webContentURL = Bundle.main.url(forResource: "WebContent", withExtension: nil)
            ?? Bundle.main.bundleURL.appendingPathComponent("WebContent", isDirectory: true)

        let handler = AppSchemeHandler(rootURL: webContentURL)
        context.coordinator.handler = handler

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.setURLSchemeHandler(handler, forURLScheme: AppSchemeHandler.scheme)

        let userScriptSource = "(function(){\n  var bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.log;\n  if (!bridge) { return; }\n  function show(value) {\n    if (typeof value === 'string') { return value; }\n    if (value instanceof Error) { return value.stack || String(value); }\n    try { var json = JSON.stringify(value); return json === undefined ? String(value) : json; }\n    catch (error) { return String(value); }\n  }\n  ['info', 'warn', 'error'].forEach(function (level) {\n    var original = console[level];\n    console[level] = function () {\n      bridge.postMessage({ level: level, text: Array.prototype.map.call(arguments, show).join(' ') });\n      return original.apply(console, arguments);\n    };\n  });\n})();\n(function(){\n  var bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.haptic;\n  if (!bridge || navigator.vibrate) { return; }\n  navigator.vibrate = function (pattern) {\n    try { bridge.postMessage(pattern); } catch (error) { return false; }\n    return true;\n  };\n})();\n(function(){\n  var bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.share;\n  if (!bridge || navigator.share) { return; }\n  var pending = null;\n  var seq = 0;\n  window.__iosMakerShareDone = function (id, error) {\n    if (!pending || pending.id !== id) { return; }\n    var p = pending;\n    pending = null;\n    if (error) { p.reject(new DOMException(error === 'AbortError' ? 'Share canceled' : 'Share failed', error)); }\n    else { p.resolve(); }\n  };\n  function readFile(file) {\n    return new Promise(function (resolve, reject) {\n      var reader = new FileReader();\n      reader.onload = function () { resolve({ name: file.name, type: file.type, data: String(reader.result).split(',')[1] || '' }); };\n      reader.onerror = function () { reject(reader.error); };\n      reader.readAsDataURL(file);\n    });\n  }\n  navigator.canShare = function (data) {\n    if (!data) { return false; }\n    var files = data.files || [];\n    for (var i = 0; i < files.length; i++) { if (!/^image\\//.test(files[i].type)) { return false; } }\n    return !!(data.text || data.url || data.title || files.length);\n  };\n  navigator.share = function (data) {\n    data = data || {};\n    if (pending) { return Promise.reject(new DOMException('A share is already open', 'InvalidStateError')); }\n    if (!navigator.canShare(data)) { return Promise.reject(new TypeError('Nothing this device can share')); }\n    return Promise.all(Array.prototype.map.call(data.files || [], readFile)).then(function (files) {\n      return new Promise(function (resolve, reject) {\n        var id = ++seq;\n        pending = { id: id, resolve: resolve, reject: reject };\n        bridge.postMessage({ id: id, title: data.title || '', text: data.text || '', url: data.url || '', files: files });\n      });\n    });\n  };\n})();"
        if !userScriptSource.isEmpty {
            let userScript = WKUserScript(source: userScriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            config.userContentController.addUserScript(userScript)
        }
        config.userContentController.add(context.coordinator.console, name: ConsoleBridge.name)
        config.userContentController.add(context.coordinator.haptics, name: HapticBridge.name)
        config.userContentController.add(context.coordinator.share, name: ShareBridge.name)


        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true
        config.defaultWebpagePreferences = preferences

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        // the launch screen's colour (light and dark, the LaunchBackground colour set), so nothing flashes between it
        // and the page's first paint. make-app writes the set and preflight refuses a project without it, so a
        // missing one is a broken build, never a reason to stop a launch: it is logged, and the page paints a moment later
        let launchBackground = UIColor(named: "LaunchBackground")
        if launchBackground == nil { AppLog.webView.fault("the LaunchBackground colour set is missing from the asset catalog") }
        webView.isOpaque = false
        webView.backgroundColor = launchBackground
        webView.scrollView.backgroundColor = launchBackground
        webView.allowsLinkPreview = false
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.contentInset = .zero
        if #available(iOS 13.0, *) {
            webView.scrollView.automaticallyAdjustsScrollIndicatorInsets = false
        }
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }
        context.coordinator.audio.start(webView)

        var urlString = "\(AppSchemeHandler.scheme)://\(AppSchemeHandler.host)/index.html"
        var devURL: String? = nil
        for arg in CommandLine.arguments {
            if arg.hasPrefix("--ios-maker-shot=") {
                let spec = String(arg.dropFirst("--ios-maker-shot=".count))
                if let escaped = spec.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) {
                    urlString += "#ios-maker-shot=" + escaped
                }
            } else if arg.hasPrefix("--ios-maker-dev-url=") {
                devURL = String(arg.dropFirst("--ios-maker-dev-url=".count))
            }
        }

        if let devURL, let url = URL(string: devURL) {
            webView.load(URLRequest(url: url))
        } else {
            webView.load(URLRequest(url: URL(string: urlString)!))
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var handler: AppSchemeHandler?
        let audio = AudioSessionBridge()
        let console = ConsoleBridge()
        let haptics = HapticBridge()
        let share = ShareBridge()


        private func openExternally(_ url: URL?) -> Bool {
            guard let url, let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { return false }
            UIApplication.shared.open(url)
            return true
        }

        // A tap on an http(s) link leaves the offline app and opens in the system
        // browser, like a normal link. app:// navigations stay in the webview, and
        // the initial programmatic load (navigationType .other into the main frame)
        // is never redirected. The handler's type must match the SDK's exactly
        // (@MainActor @Sendable): in Swift 6 a near miss is only a warning, and
        // WebKit never calls the method.
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            if (navigationAction.navigationType == .linkActivated || navigationAction.targetFrame == nil),
               openExternally(navigationAction.request.url) {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        // target=_blank / window.open are routed here (no main-frame navigation),
        // so this is the path the visible share link actually takes. Open it in the
        // system browser and create no in-app window.
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            _ = openExternally(navigationAction.request.url)
            return nil
        }

        // WebKit ends the page's process under memory pressure or while the app
        // sits in the background ("WebKit calls this method when the process for
        // the specified web view terminates for any reason",
        // https://developer.apple.com/documentation/webkit/wknavigationdelegate/webviewwebcontentprocessdidterminate(_:)).
        // Left alone, the app shows an empty web view until it is killed and
        // relaunched; a reload brings the game back. A page whose process dies at
        // every load would reload for ever and look like a launch that hangs, so
        // the reloads are bounded: every termination is logged, and after
        // maxWebProcessReloads of them within the window the view is left as it is.
        private static let maxWebProcessReloads = 3
        private static let webProcessReloadWindow: TimeInterval = 300
        private var webProcessTerminations: [Date] = []

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            let now = Date()
            webProcessTerminations = webProcessTerminations.filter { now.timeIntervalSince($0) < Self.webProcessReloadWindow } + [now]
            let url = webView.url?.absoluteString ?? "(no url)"
            guard webProcessTerminations.count <= Self.maxWebProcessReloads else {
                AppLog.webView.fault("web content process terminated \(self.webProcessTerminations.count, privacy: .public) times in \(Self.webProcessReloadWindow, privacy: .public) s, not reloading again: \(url, privacy: .public)")
                return
            }
            AppLog.webView.error("web content process terminated (reload \(self.webProcessTerminations.count, privacy: .public) of \(Self.maxWebProcessReloads, privacy: .public)): \(url, privacy: .public)")
            webView.reload()
        }
    }
}

/// The app's unified log, under its bundle id. What the wrapper logs is marked
/// public on purpose: it is how a release build on a paired iPhone is read in
/// Console.app, where private values show as <private>.
enum AppLog {
    static let web = Logger(subsystem: "com.franzai.droplis", category: "web")
    static let webView = Logger(subsystem: "com.franzai.droplis", category: "webview")
    static let audio = Logger(subsystem: "com.franzai.droplis", category: "audio")
}

/// Apple's audio session guideline for games, and the page told about it.
///
/// WebKit plays Web Audio through the app's AVAudioSession. Left at its
/// default, the session is not active when the page first plays, and the
/// first launch is silent. So the category is set before the page loads, the
/// session is activated whenever the app becomes active, after an interruption
/// ends and after the media services reset - and each of those moments reaches
/// the page as `iosmaker:audio` with the secondary-audio hint, because only
/// the page knows which of its sounds is the soundtrack.
///
/// Every AVAudioSession call runs on one private serial queue, never on the
/// main thread: setActive is a round trip to the audio server that iOS 27
/// reports as a hang risk on the main thread ("This method can lead to UI
/// unresponsiveness if called on the main thread",
/// https://github.com/superuser404notfound/AetherEngine/issues/538), and a
/// launch that waits for mediaserverd is a launch the watchdog can kill. The
/// page's event follows the call it reports, from the main actor.
@MainActor
final class AudioSessionBridge {
    private weak var webView: WKWebView?
    private var observers: [any NSObjectProtocol] = []
    private static let queue = DispatchQueue(label: "com.franzai.droplis.audio-session", qos: .userInitiated)

    func start(_ webView: WKWebView) {
        self.webView = webView
        configure()
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        // The blocks run on the main queue ("The operation queue where the block runs",
        // https://developer.apple.com/documentation/foundation/notificationcenter/addobserver(forname:object:queue:using:)),
        // but the compiler cannot see that, and MainActor.assumeIsolated "will crash with a fatal error" when its
        // guess is wrong (https://developer.apple.com/documentation/swift/mainactor/assumeisolated(_:file:line:)).
        // A Task hops to the main actor instead: one more turn of the run loop, never a trap.
        observers = [
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.activate(then: "active") }
            },
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
                let raw = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
                Task { @MainActor [weak self] in self?.interrupted(raw) }
            },
            center.addObserver(forName: AVAudioSession.silenceSecondaryAudioHintNotification, object: session, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.send("secondary") }
            },
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.configure()
                    self?.activate(then: "reset")
                }
            }
        ]
        // an app that is already active when the view is made gets no
        // didBecomeActive for this launch
        if UIApplication.shared.applicationState == .active {
            activate(then: nil)
        }
    }

    private func interrupted(_ raw: UInt?) {
        guard let raw, let type = AVAudioSession.InterruptionType(rawValue: raw) else {
            AppLog.audio.error("interruption without a type: \(String(describing: raw), privacy: .public)")
            return
        }
        switch type {
        case .began:
            send("interruption-began")
        case .ended:
            // always, whatever shouldResume says: a game resumes its sound effects
            activate(then: "interruption-ended")
        @unknown default:
            AppLog.audio.error("unknown interruption type \(raw, privacy: .public)")
        }
    }

    /// The category, on the queue; "Typically, you set the category and mode before activating the session"
    /// (https://developer.apple.com/documentation/avfaudio/avaudiosession/setcategory(_:mode:options:)), and the
    /// serial queue keeps that order.
    private func configure() {
        Self.queue.async {
            do {
                try AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default)
            } catch {
                AppLog.audio.error("setCategory(.ambient) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Activates on the queue, then (when asked) tells the page which moment this was, with the hint as it stood
    /// right after the activation.
    private func activate(then kind: String?) {
        Self.queue.async { [weak self] in
            do {
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                AppLog.audio.error("setActive(true) failed: \(error.localizedDescription, privacy: .public)")
            }
            if let kind { Self.deliver(kind, to: self) }
        }
    }

    /// A moment that needs no activation, in line behind every call already queued.
    private func send(_ kind: String) {
        Self.queue.async { [weak self] in Self.deliver(kind, to: self) }
    }

    /// The hint is the session's and is read on its queue; the event reaches the page on the main actor.
    nonisolated private static func deliver(_ kind: String, to bridge: AudioSessionBridge?) {
        let otherAudio = AVAudioSession.sharedInstance().secondaryAudioShouldBeSilencedHint
        AppLog.audio.notice("\(kind, privacy: .public) otherAudio=\(otherAudio, privacy: .public)")
        Task { @MainActor in bridge?.dispatch(kind, otherAudio: otherAudio) }
    }

    private func dispatch(_ kind: String, otherAudio: Bool) {
        let script = "window.dispatchEvent(new CustomEvent('iosmaker:audio', {detail:{kind:'\(kind)', otherAudio:\(otherAudio)}}))"
        webView?.evaluateJavaScript(script) { _, error in
            if let error {
                AppLog.audio.error("iosmaker:audio \(kind, privacy: .public) not delivered: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

/// The other half of the console shim injected at document start: the page's
/// console.info, warn and error, in the unified log at a level Console.app
/// shows without extra switches (info as notice).
final class ConsoleBridge: NSObject, WKScriptMessageHandler {
    static let name = "log"

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let level = body["level"] as? String,
              let text = body["text"] as? String else {
            AppLog.web.error("unreadable console message: \(String(describing: message.body), privacy: .public)")
            return
        }
        switch level {
        case "error": AppLog.web.error("\(text, privacy: .public)")
        case "warn": AppLog.web.warning("\(text, privacy: .public)")
        default: AppLog.web.notice("\(text, privacy: .public)")
        }
    }
}

/// The native half of the page's haptics, behind `window.webkit.messageHandlers.haptic`.
///
/// A page that speaks haptics posts an intent, `{ s: style, i: intensity }`. The
/// styles are UIKit's own (soft, light, medium, rigid, heavy), played at the
/// given intensity (0...1) with `impactOccurred(intensity:)`, plus `selection`
/// and `success`, which are the system's patterns and keep the meaning Apple
/// documents for them: a choice moved, a task succeeded.
///
/// A page that only knows the web Vibration API reaches the same handler through
/// the `navigator.vibrate` shim injected at document start. That API asks for a
/// duration in milliseconds and iOS offers impact strengths instead, so the
/// length is read as an intent: a tick, a tap, or a knock. A pattern is a list
/// of buzzes and pauses; only its first buzz is played, because UIKit has
/// nothing to sustain a rhythm with and a burst of generators fires as one blur
/// anyway. Zero means cancel, and there is nothing running to cancel.
/// The generators are made the first time the page asks for a haptic, never at
/// launch: a launch touches nothing of the Taptic Engine. Each is tied to the
/// web view with init(style:view:) / init(view:) (iOS 17.5,
/// https://developer.apple.com/documentation/uikit/uiimpactfeedbackgenerator/init(style:view:)),
/// the replacement for init(style:), deprecated in iOS 27
/// (https://developer.apple.com/documentation/uikit/uiimpactfeedbackgenerator/init(style:)).
/// WKScriptMessageHandler runs on the main actor, and so does this class.
@MainActor
final class HapticBridge: NSObject, WKScriptMessageHandler {
    static let name = "haptic"

    enum Feedback: Equatable {
        case impact(UIImpactFeedbackGenerator.FeedbackStyle, CGFloat)
        case selection
        case success
    }

    static let styles: [String: UIImpactFeedbackGenerator.FeedbackStyle] = [
        "soft": .soft,
        "light": .light,
        "medium": .medium,
        "rigid": .rigid,
        "heavy": .heavy
    ]

    private var impacts: [UIImpactFeedbackGenerator.FeedbackStyle: UIImpactFeedbackGenerator] = [:]
    private var selection: UISelectionFeedbackGenerator?
    private var notification: UINotificationFeedbackGenerator?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let feedback = Self.feedback(message.body), let view = message.webView else { return }
        play(feedback, on: view)
    }

    /// Played, then prepared again: the Taptic Engine goes idle after feedback
    /// ("After feedback is triggered, the Taptic Engine returns to its idle state",
    /// https://developer.apple.com/documentation/uikit/uifeedbackgenerator/prepare()),
    /// and in a game the next haptic is rarely more than a moment away.
    private func play(_ feedback: Feedback, on view: UIView) {
        switch feedback {
        case .impact(let style, let intensity):
            let generator = impacts[style] ?? UIImpactFeedbackGenerator(style: style, view: view)
            impacts[style] = generator
            generator.impactOccurred(intensity: intensity)
            generator.prepare()
        case .selection:
            let generator = selection ?? UISelectionFeedbackGenerator(view: view)
            selection = generator
            generator.selectionChanged()
            generator.prepare()
        case .success:
            let generator = notification ?? UINotificationFeedbackGenerator(view: view)
            notification = generator
            generator.notificationOccurred(.success)
            generator.prepare()
        }
    }

    /// An intent object, or milliseconds from the Vibration API. Anything else is not a haptic.
    static func feedback(_ body: Any) -> Feedback? {
        if let intent = body as? [String: Any] { return intentFeedback(intent) }
        guard let milliseconds = firstBuzz(body), milliseconds > 0 else { return nil }
        return .impact(milliseconds <= 10 ? .light : (milliseconds <= 25 ? .medium : .heavy), 1)
    }

    /// `{ s, i }`: a style this bridge knows, at an intensity held inside 0...1
    /// (full when the page gives none). An unknown style is the page's bug and is logged.
    static func intentFeedback(_ intent: [String: Any]) -> Feedback? {
        guard let style = intent["s"] as? String else {
            AppLog.webView.error("haptic intent without a style")
            return nil
        }
        if style == "selection" { return .selection }
        if style == "success" { return .success }
        guard let impact = styles[style] else {
            AppLog.webView.error("haptic intent with an unknown style: \(style, privacy: .public)")
            return nil
        }
        let intensity = (intent["i"] as? NSNumber)?.doubleValue ?? 1
        return .impact(impact, CGFloat(min(max(intensity, 0), 1)))
    }

    /// A number, or the first entry of a pattern. Anything else is not a buzz.
    static func firstBuzz(_ body: Any) -> Double? {
        if let number = body as? NSNumber { return number.doubleValue }
        if let list = body as? [Any], let first = list.first as? NSNumber { return first.doubleValue }
        return nil
    }
}

/// The other half of the `navigator.share` shim injected at document start.
///
/// The page's images become image items and its text and url ONE message item
/// (the url appended unless the text already carries it), so every target -
/// Copy included - shows the link exactly once. The sheet is anchored to the web view (an iPad
/// presents it as a popover and needs a source), and its outcome goes back to
/// the page's promise: nil when shared, AbortError when dismissed.
final class ShareBridge: NSObject, WKScriptMessageHandler {
    static let name = "share"

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let id = (body["id"] as? NSNumber)?.intValue else { return }
        let items = Self.items(body)
        let webView = message.webView
        DispatchQueue.main.async { self.present(items, id: id, webView: webView) }
    }

    /// Images first (the picture leads the message), then the one message.
    static func items(_ body: [String: Any]) -> [Any] {
        var items: [Any] = []
        for file in body["files"] as? [[String: Any]] ?? [] {
            if let encoded = file["data"] as? String, let data = Data(base64Encoded: encoded), let image = UIImage(data: data) {
                items.append(image)
            }
        }
        let text = message(body["text"] as? String ?? "", url: body["url"] as? String ?? "")
        if !text.isEmpty { items.append(text) }
        return items
    }

    /// The text with the url in it, once.
    static func message(_ text: String, url: String) -> String {
        if url.isEmpty || text.contains(url) { return text }
        return text.isEmpty ? url : text + "\n" + url
    }

    private func present(_ items: [Any], id: Int, webView: WKWebView?) {
        guard let webView, !items.isEmpty, var top = webView.window?.rootViewController else {
            finish(id, error: "DataError", webView: webView)
            return
        }
        while let presented = top.presentedViewController { top = presented }
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = webView
        sheet.popoverPresentationController?.sourceRect = CGRect(x: webView.bounds.midX, y: webView.bounds.maxY - 1, width: 1, height: 1)
        sheet.completionWithItemsHandler = { [weak self] _, completed, _, error in
            self?.finish(id, error: completed ? nil : (error == nil ? "AbortError" : "DataError"), webView: webView)
        }
        top.present(sheet, animated: true)
    }

    private func finish(_ id: Int, error: String?, webView: WKWebView?) {
        let reason = error.map { "'\($0)'" } ?? "null"
        webView?.evaluateJavaScript("window.__iosMakerShareDone && window.__iosMakerShareDone(\(id), \(reason))")
    }
}
