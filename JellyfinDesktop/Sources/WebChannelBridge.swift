import UIKit
import WebKit

final class WebChannelBridge: NSObject, WKScriptMessageHandler {

    static let handlerName = "jmpBridge"

    weak var webView: WKWebView?
    private let player: VLCPlayerController
    private let system: SystemBridge
    private let nowPlaying: NowPlayingManager

    init(
        player: VLCPlayerController,
        system: SystemBridge,
        nowPlaying: NowPlayingManager
    ) {
        self.player = player
        self.system = system
        self.nowPlaying = nowPlaying
        super.init()

        player.onEmitSignal = { [weak self] signalName, args in
            self?.emitSignal(component: "player", signal: signalName, args: args)
        }

        system.onEmitSignal = { [weak self] signalName, args in
            self?.emitSignal(component: "system", signal: signalName, args: args)
        }

        SettingsStore.shared.onSectionUpdated = { [weak self] section, changed in
            self?.emitSignal(component: "settings", signal: "sectionValueUpdate", args: [section, changed])
        }

        nowPlaying.onInputAction = { [weak self] actions in
            self?.emitSignal(component: "input", signal: "hostInput", args: [actions])
        }

        nowPlaying.onSeekPositionMs = { [weak self] posMs in
            self?.emitSignal(component: "input", signal: "positionSeek", args: [posMs])
        }
    }

    func sendInputActions(_ actions: [String]) {
        emitSignal(component: "input", signal: "hostInput", args: [actions])
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == Self.handlerName,
              let body = message.body as? [String: Any],
              let component = body["component"] as? String,
              let method = body["method"] as? String else {
            return
        }

        let args = (body["args"] as? [Any]) ?? []
        let callbackId = (body["callbackId"] as? NSNumber)?.intValue

        let result = handleCall(component: component, method: method, args: args)
        if let cbId = callbackId {
            resolveCallback(id: cbId, result: result)
        }
    }

    private func handleCall(component: String, method: String, args: [Any]) -> Any? {
        switch component {
        case "player":
            return handlePlayerCall(method: method, args: args)
        case "settings":
            return handleSettingsCall(method: method, args: args)
        case "system":
            return handleSystemCall(method: method, args: args)
        case "input":
            if method == "executeActions", let actions = args.first as? [String] {
                sendInputActions(actions)
            }
            return nil
        case "window":
            return nil
        default:
            return nil
        }
    }

    private func handlePlayerCall(method: String, args: [Any]) -> Any? {
        switch method {
        case "load", "queueMedia":
            let url = (args.count > 0 ? args[0] as? String : nil) ?? ""
            let options = (args.count > 1 ? args[1] as? [String: Any] : nil) ?? [:]
            let metadata = (args.count > 2 ? args[2] as? [String: Any] : nil) ?? [:]
            let audioStream = args.count > 3 ? args[3] : nil
            let subtitleStream = args.count > 4 ? args[4] : nil
            player.load(
                url: url,
                options: options,
                metadata: metadata,
                audioStream: audioStream,
                subtitleStream: subtitleStream
            )
            return true

        case "stop":
            player.stop()
            nowPlaying.clear()
            return nil

        case "pause":
            player.pause()
            return nil

        case "play":
            player.play()
            return nil

        case "seekTo":
            if let ms = (args.first as? NSNumber)?.int64Value {
                player.seekTo(ms: ms)
            }
            return nil

        case "getPosition":
            return player.currentPositionMs()

        case "getDuration":
            return player.currentDurationMs()

        case "setVolume":
            if let vol = (args.first as? NSNumber)?.intValue {
                player.setVolume(vol)
            }
            return nil

        case "setMuted":
            if let muted = (args.first as? NSNumber)?.boolValue {
                player.setMuted(muted)
            }
            return nil

        case "setPlaybackRate":
            if let permille = (args.first as? NSNumber)?.intValue {
                player.setPlaybackRate(permille: permille)
            }
            return nil

        case "setAudioStream":
            player.setAudioStream(args.first)
            return nil

        case "setSubtitleStream":
            player.setSubtitleStream(args.first)
            return nil

        case "setSubtitleDelay":
            if let ms = (args.first as? NSNumber)?.int64Value {
                player.setSubtitleDelay(ms: ms)
            }
            return nil

        case "setAudioDelay":
            if let ms = (args.first as? NSNumber)?.int64Value {
                player.setAudioDelay(ms: ms)
            }
            return nil

        case "setVideoRectangle":
            let x = (args.count > 0 ? (args[0] as? NSNumber)?.intValue : nil) ?? 0
            let y = (args.count > 1 ? (args[1] as? NSNumber)?.intValue : nil) ?? 0
            let w = (args.count > 2 ? (args[2] as? NSNumber)?.intValue : nil) ?? 0
            let h = (args.count > 3 ? (args[3] as? NSNumber)?.intValue : nil) ?? 0
            player.setVideoRectangle(x: x, y: y, w: w, h: h)
            return nil

        case "notifyMetadata":
            if let meta = args.first as? [String: Any] {
                nowPlaying.updateMetadata(meta)
            }
            return nil

        case "notifyDurationChange":
            if let ms = (args.first as? NSNumber)?.int64Value {
                nowPlaying.updateDuration(ms: ms)
            }
            return nil

        case "notifyPosition", "notifySeek":
            if let ms = (args.first as? NSNumber)?.int64Value {
                nowPlaying.updatePosition(ms: ms)
            }
            return nil

        case "notifyRateChange":
            if let rate = (args.first as? NSNumber)?.doubleValue {
                nowPlaying.updateRate(rate)
            }
            return nil

        case "notifyPlaybackState":
            if let state = args.first as? String {
                nowPlaying.updatePlaybackState(state)
            }
            return nil

        case "notifyQueueChange":
            let canNext = (args.count > 0 ? (args[0] as? NSNumber)?.boolValue : nil) ?? false
            let canPrev = (args.count > 1 ? (args[1] as? NSNumber)?.boolValue : nil) ?? false
            nowPlaying.updateQueue(canNext: canNext, canPrevious: canPrev)
            return nil

        case "notifyPlaybackStop":
            let isNavigating = (args.first as? NSNumber)?.boolValue ?? false
            if !isNavigating {
                nowPlaying.clear()
            }
            return nil

        default:
            return nil
        }
    }

    private func handleSettingsCall(method: String, args: [Any]) -> Any? {
        switch method {
        case "allValues":
            return SettingsStore.shared.allValues()
        case "settingDescriptions":
            return SettingsStore.shared.settingDescriptions()
        case "orderedSections":
            return SettingsStore.shared.orderedSections()
        case "setValue":
            if args.count >= 3,
               let section = args[0] as? String,
               let key = args[1] as? String {
                SettingsStore.shared.setValue(section: section, key: key, value: args[2])
            }
            return true
        default:
            return nil
        }
    }

    private func handleSystemCall(method: String, args: [Any]) -> Any? {
        switch method {
        case "checkServerConnectivity":
            if let url = args.first as? String {
                system.checkServerConnectivity(url: url)
            }
            return nil

        case "cancelServerConnectivity":
            system.cancelServerConnectivity()
            return nil

        case "openExternalUrl":
            if let url = args.first as? String {
                system.openExternalUrl(url)
            }
            return nil

        case "navigateToUrl":
            if let urlStr = args.first as? String, let url = URL(string: urlStr) {
                player.stop()
                system.onNavigateToUrl?(url)
            }
            return nil

        case "resetToConnectScreen", "exit":
            player.stop()
            nowPlaying.clear()
            system.onResetToConnectScreen?()
            return nil

        case "hello":
            if let client = args.first as? String {
                NSLog("[JellyfinDesktop] Web client initialized: \(client)")
            }
            return nil

        default:
            return nil
        }
    }

    // MARK: - JS Dispatch

    private func resolveCallback(id: Int, result: Any?) {
        let jsonValue = Self.serializeToJSLiteral(result)
        let js = "window.__jmpNativeBridge && window.__jmpNativeBridge.resolveCallback(\(id), \(jsonValue));"
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    func emitSignal(component: String, signal: String, args: [Any]) {
        let jsonArgs = Self.serializeToJSLiteral(args)
        let js = "window.__jmpNativeBridge && window.__jmpNativeBridge.emitSignal(\(Self.serializeToJSLiteral(component)), \(Self.serializeToJSLiteral(signal)), \(jsonArgs));"
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    private static func serializeToJSLiteral(_ value: Any?) -> String {
        guard let value = value, !(value is NSNull) else {
            return "null"
        }
        if let str = value as? String {
            if let data = try? JSONSerialization.data(withJSONObject: [str]),
               let arrStr = String(data: data, encoding: .utf8),
               arrStr.count >= 2 {
                return String(arrStr.dropFirst().dropLast())
            }
            return "\"\""
        }
        if let boolVal = value as? Bool {
            return boolVal ? "true" : "false"
        }
        if let num = value as? NSNumber {
            if CFGetTypeID(num) == CFBooleanGetTypeID() {
                return num.boolValue ? "true" : "false"
            }
            return num.stringValue
        }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return "null"
    }
}
