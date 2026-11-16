import UIKit

final class SystemBridge: NSObject, URLSessionDelegate, URLSessionTaskDelegate {

    var onEmitSignal: ((String, [Any]) -> Void)?
    var onNavigateToUrl: ((URL) -> Void)?
    var onResetToConnectScreen: (() -> Void)?

    private var activeSession: URLSession?
    private var activeTask: URLSessionDataTask?

    func checkServerConnectivity(url rawUrl: String) {
        cancelServerConnectivity()

        guard let initialURL = URL(string: rawUrl) else {
            onEmitSignal?("serverConnectivityResult", [rawUrl, false, ""])
            return
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8.0
        config.timeoutIntervalForResource = 10.0
        config.requestCachePolicy = .reloadIgnoringLocalCacheData

        let session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        self.activeSession = session

        var headReq = URLRequest(url: initialURL)
        headReq.httpMethod = "GET"
        headReq.setValue(SettingsStore.shared.userAgent, forHTTPHeaderField: "User-Agent")

        let task = session.dataTask(with: headReq) { [weak self] _, response, error in
            guard let self = self else { return }
            if let nsErr = error as NSError?, nsErr.code == NSURLErrorCancelled {
                return
            }

            let resolvedURL = response?.url ?? initialURL
            let baseUrl = Self.extractBaseUrl(from: resolvedURL)
            guard let infoURL = URL(string: baseUrl + "/System/Info/Public") else {
                self.onEmitSignal?("serverConnectivityResult", [rawUrl, false, ""])
                return
            }

            var infoReq = URLRequest(url: infoURL)
            infoReq.setValue(SettingsStore.shared.userAgent, forHTTPHeaderField: "User-Agent")
            infoReq.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

            self.activeTask = session.dataTask(with: infoReq) { [weak self] data, _, infoErr in
                guard let self = self else { return }
                if let nsErr = infoErr as NSError?, nsErr.code == NSURLErrorCancelled {
                    return
                }

                var isValidJellyfin = false
                if infoErr == nil,
                   let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let serverId = json["Id"] as? String,
                   !serverId.isEmpty {
                    isValidJellyfin = true
                }

                let finalWebUrl: String
                if resolvedURL.path.lowercased().contains("/web") {
                    finalWebUrl = resolvedURL.absoluteString
                } else {
                    finalWebUrl = baseUrl + "/web/index.html"
                }

                self.onEmitSignal?(
                    "serverConnectivityResult",
                    [rawUrl, isValidJellyfin, isValidJellyfin ? finalWebUrl : ""]
                )
            }
            self.activeTask?.resume()
        }

        self.activeTask = task
        task.resume()
    }

    func cancelServerConnectivity() {
        activeTask?.cancel()
        activeTask = nil
        activeSession?.invalidateAndCancel()
        activeSession = nil
    }

    func openExternalUrl(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        DispatchQueue.main.async {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
    }

    private static func extractBaseUrl(from url: URL) -> String {
        let scheme = url.scheme ?? "http"
        let host = url.host ?? ""
        var origin = "\(scheme)://\(host)"
        if let port = url.port {
            let isDefaultPort = (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
            if !isDefaultPort {
                origin += ":\(port)"
            }
        }

        let path = url.path
        if let range = path.range(of: "/web", options: [.caseInsensitive, .backwards]) {
            let prefix = String(path[..<range.lowerBound])
            return origin + prefix
        }
        if path.isEmpty || path == "/" {
            return origin
        }
        return origin + path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).split(separator: "/").map { "/\($0)" }.joined()
    }

    // MARK: - URLSessionDelegate (Self-signed TLS support when opted-in)

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           SettingsStore.shared.ignoreSSLErrors,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }
}
