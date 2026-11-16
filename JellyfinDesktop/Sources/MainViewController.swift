import UIKit
import WebKit

final class MainViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {

    private let playerController = VLCPlayerController()
    private let systemBridge = SystemBridge()
    private let nowPlayingManager = NowPlayingManager()
    private var webBridge: WebChannelBridge!
    private var webView: WKWebView!

    override var prefersStatusBarHidden: Bool {
        return true
    }

    override var prefersHomeIndicatorAutoHidden: Bool {
        return true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        webBridge = WebChannelBridge(
            player: playerController,
            system: systemBridge,
            nowPlaying: nowPlayingManager
        )

        systemBridge.onNavigateToUrl = { [weak self] targetURL in
            self?.navigateToRemoteServer(targetURL)
        }

        systemBridge.onResetToConnectScreen = { [weak self] in
            SettingsStore.shared.userWebClient = ""
            self?.rebuildUserScriptsAndLoadConnectScreen()
        }

        setupVideoLayer()
        setupWebView()
        setupEmergencyMenuGesture()
        loadConnectScreen()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        playerController.updateContainerBounds()
    }

    // MARK: - View Hierarchy (VLC surface underneath transparent WKWebView, identical to jellyfin-desktop)

    private func setupVideoLayer() {
        let videoView = playerController.videoContainerView
        videoView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(videoView)

        NSLayoutConstraint.activate([
            videoView.topAnchor.constraint(equalTo: view.topAnchor),
            videoView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            videoView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    private func setupWebView() {
        let contentController = WKUserContentController()
        contentController.add(LeakFreeScriptMessageHandler(target: webBridge), name: WebChannelBridge.handlerName)

        let shellScript = SettingsStore.shared.buildNativeShellUserScript()
        let userScript = WKUserScript(
            source: shellScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        contentController.addUserScript(userScript)

        let config = WKWebViewConfiguration()
        config.userContentController = contentController
        config.allowsInlineMediaPlayback = true
        config.allowsAirPlayForMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.websiteDataStore = .default()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false

        // Enable file access from file:// for local WebResources assets
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.translatesAutoresizingMaskIntoConstraints = false
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.customUserAgent = SettingsStore.shared.userAgent

        // Transparent background so MobileVLCKit video renders cleanly underneath Jellyfin's OSD
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.backgroundColor = .clear
        wv.scrollView.contentInsetAdjustmentBehavior = .never
        wv.scrollView.bounces = false
        wv.allowsBackForwardNavigationGestures = false

        if #available(iOS 16.4, *) {
            #if DEBUG
            wv.isInspectable = true
            #endif
        }

        view.addSubview(wv)
        NSLayoutConstraint.activate([
            wv.topAnchor.constraint(equalTo: view.topAnchor),
            wv.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            wv.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            wv.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        self.webView = wv
        self.webBridge.webView = wv
    }

    private func rebuildUserScripts() {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        let shellScript = SettingsStore.shared.buildNativeShellUserScript()
        controller.addUserScript(
            WKUserScript(
                source: shellScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
    }

    private func loadConnectScreen() {
        guard let webDir = Bundle.main.resourceURL?.appendingPathComponent("WebResources") else {
            return
        }
        let htmlURL = webDir.appendingPathComponent("find-webclient.html")
        webView.loadFileURL(htmlURL, allowingReadAccessTo: webDir)
    }

    private func rebuildUserScriptsAndLoadConnectScreen() {
        rebuildUserScripts()
        loadConnectScreen()
    }

    private func navigateToRemoteServer(_ url: URL) {
        rebuildUserScripts()
        var request = URLRequest(url: url)
        request.cachePolicy = .useProtocolCachePolicy
        webView.load(request)
    }

    // MARK: - 3-Finger Long-Press Native Quick Menu (iPad Recovery & Layout Switcher)

    private func setupEmergencyMenuGesture() {
        let press = UILongPressGestureRecognizer(target: self, action: #selector(handleThreeFingerPress(_:)))
        press.numberOfTouchesRequired = 3
        press.minimumPressDuration = 1.0
        press.cancelsTouchesInView = false
        view.addGestureRecognizer(press)
    }

    @objc private func handleThreeFingerPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, presentedViewController == nil else { return }

        let alert = UIAlertController(
            title: "Jellyfin Desktop (iPadOS)",
            message: "Quick Service Menu (3-finger long press)",
            preferredStyle: .alert
        )

        alert.addAction(UIAlertAction(title: "Reload Page", style: .default) { [weak self] _ in
            self?.rebuildUserScripts()
            self?.webView.reload()
        })

        let nextLayout: String
        switch SettingsStore.shared.layoutMode {
        case "desktop": nextLayout = "mobile"
        case "mobile": nextLayout = "tv"
        default: nextLayout = "desktop"
        }
        alert.addAction(UIAlertAction(title: "Switch UI Layout to \(nextLayout.uppercased())", style: .default) { [weak self] _ in
            SettingsStore.shared.layoutMode = nextLayout
            self?.rebuildUserScripts()
            self?.webView.reload()
        })

        let sslEnabled = SettingsStore.shared.ignoreSSLErrors
        alert.addAction(UIAlertAction(
            title: sslEnabled ? "Disable Self-Signed SSL Trust" : "Allow Self-Signed SSL",
            style: .default
        ) { _ in
            SettingsStore.shared.ignoreSSLErrors = !sslEnabled
        })

        alert.addAction(UIAlertAction(title: "Change Jellyfin Server", style: .destructive) { [weak self] _ in
            self?.playerController.stop()
            SettingsStore.shared.userWebClient = ""
            self?.rebuildUserScriptsAndLoadConnectScreen()
        })

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    // MARK: - Hardware Keyboard Support for iPad

    override var keyCommands: [UIKeyCommand]? {
        return [
            UIKeyCommand(input: " ", modifierFlags: [], action: #selector(onKeyPlayPause)),
            UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(onKeySeekBack)),
            UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(onKeySeekForward)),
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(onKeyBack))
        ]
    }

    @objc private func onKeyPlayPause() { webBridge.sendInputActions(["play_pause"]) }
    @objc private func onKeySeekBack() { webBridge.sendInputActions(["seek_backward"]) }
    @objc private func onKeySeekForward() { webBridge.sendInputActions(["seek_forward"]) }
    @objc private func onKeyBack() { webBridge.sendInputActions(["back"]) }

    // MARK: - WKNavigationDelegate

    func webView(
        _ webView: WKWebView,
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

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        let nsErr = error as NSError
        if nsErr.code == NSURLErrorCancelled { return }
        NSLog("[JellyfinDesktop] Provisional navigation failed: \(error.localizedDescription)")
    }

    // MARK: - WKUIDelegate

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let targetURL = navigationAction.request.url {
            UIApplication.shared.open(targetURL, options: [:], completionHandler: nil)
        }
        return nil
    }
}

/// Prevents retain cycle between WKUserContentController and WebChannelBridge
private final class LeakFreeScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?

    init(target: WKScriptMessageHandler) {
        self.target = target
        super.init()
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
