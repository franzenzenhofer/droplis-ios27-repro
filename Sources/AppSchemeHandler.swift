import Foundation
import WebKit
import UniformTypeIdentifiers

/// Serves the bundled web app at app://local.
///
/// WebKit calls the handler on the main actor (the protocol is declared
/// `@MainActor protocol WKURLSchemeHandler`,
/// https://developer.apple.com/documentation/webkit/wkurlschemehandler). The
/// file read is this app's own work and runs on a background queue, so no
/// read holds the main thread while a page starts. The task's callbacks go
/// back to the main actor: Apple documents no other thread for them
/// (https://developer.apple.com/documentation/webkit/wkurlschemetask), and a
/// task that was stopped must get none at all ("An exception will be thrown
/// if any callbacks are made on the URL scheme handler task after your app has
/// been told to stop loading for it", WKURLSchemeHandler.h, iOS 26.2 SDK;
/// https://developer.apple.com/documentation/webkit/wkurlschemehandler/webview(_:stop:)),
/// so the live tasks are kept by identity and a stopped one leaves the table
/// before its data arrives.
@MainActor
final class AppSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "app"
    static let host = "local"

    private let rootURL: URL
    /// the tasks still wanted, by identity; a stopped one is removed and never answered
    private var live: [ObjectIdentifier: any WKURLSchemeTask] = [:]
    private static let reads = DispatchQueue(label: "com.franzai.droplis.scheme-reads", qos: .userInitiated, attributes: .concurrent)

    init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }

        let path = url.path == "/" || url.path.isEmpty ? "/index.html" : url.path
        let relative = String(path.dropFirst())
        let fileURL = rootURL.appendingPathComponent(relative).standardizedFileURL

        guard fileURL.path.hasPrefix(rootURL.path + "/") || fileURL.path == rootURL.path else {
            urlSchemeTask.didFailWithError(URLError(.noPermissionsToReadFile))
            return
        }

        let id = ObjectIdentifier(urlSchemeTask)
        live[id] = urlSchemeTask
        let mime = mimeType(for: fileURL)
        Self.reads.async { [weak self] in
            let data = try? Data(contentsOf: fileURL)
            Task { @MainActor [weak self] in self?.finish(id, url: url, data: data, mimeType: mime) }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        live[ObjectIdentifier(urlSchemeTask)] = nil
    }

    /// The read is back: answer the task if WebKit still wants it.
    private func finish(_ id: ObjectIdentifier, url: URL, data: Data?, mimeType: String) {
        guard let task = live.removeValue(forKey: id) else { return }
        guard let data else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": mimeType,
                "Content-Length": String(data.count),
                "Cache-Control": "no-store",
                "Access-Control-Allow-Origin": "*"
            ]
        ) else {
            task.didFailWithError(URLError(.badServerResponse))
            return
        }

        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        case "ico": return "image/x-icon"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        default:
            return UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        }
    }
}
