import UIKit

final class SettingsStore {

    static let shared = SettingsStore()

    private let defaultsKey = "org.jellyfin.desktop.ios.settings.v1"
    private var storage: [String: [String: Any]]

    var onSectionUpdated: ((String, [String: Any]) -> Void)?
    var onAspectChanged: ((String) -> Void)?

    private init() {
        var defaults = Self.defaultSettings()
        if let savedData = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONSerialization.jsonObject(with: savedData) as? [String: [String: Any]] {
            for (section, values) in decoded {
                var mergedSection = defaults[section] ?? [:]
                for (k, v) in values {
                    mergedSection[k] = v
                }
                defaults[section] = mergedSection
            }
        }
        self.storage = defaults
    }

    /// Tuned defaults for iPad Air 2 (Apple A8X: hardware 8-bit H.264 VideoToolbox, 2 GB RAM, SDR 2048x1536 4:3 screen)
    private static func defaultSettings() -> [String: [String: Any]] {
        return [
            "main": [
                "layout": "desktop",
                "fullscreen": true,
                "enableMPV": true,
                "ignoreSSLErrors": false,
                "allowBrowserZoom": false,
                "userWebClient": ""
            ],
            "audio": [
                "channels": "2.0",
                "normalize": true
            ],
            "video": [
                "hardwareDecoding": "enabled",
                "deinterlace": false,
                "prefer_transcode_to_h265": false,
                "allow_transcode_to_hevc": false,
                "force_transcode_hevc": true,
                "force_transcode_4k": true,
                "force_transcode_av1": true,
                "force_transcode_hdr": true,
                "force_transcode_hi10p": true,
                "force_transcode_dovi": true,
                "always_force_transcode": false,
                "cache": 25,
                "aspect": "normal",
                "default_playback_speed": 1.0
            ],
            "subtitles": [
                "size": -1
            ]
        ]
    }

    func allValues() -> [String: [String: Any]] {
        return storage
    }

    func value(section: String, key: String) -> Any? {
        return storage[section]?[key]
    }

    func boolValue(section: String, key: String, fallback: Bool = false) -> Bool {
        if let b = storage[section]?[key] as? Bool { return b }
        if let n = storage[section]?[key] as? NSNumber { return n.boolValue }
        return fallback
    }

    func stringValue(section: String, key: String, fallback: String = "") -> String {
        return (storage[section]?[key] as? String) ?? fallback
    }

    func intValue(section: String, key: String, fallback: Int = 0) -> Int {
        if let i = storage[section]?[key] as? Int { return i }
        if let n = storage[section]?[key] as? NSNumber { return n.intValue }
        return fallback
    }

    func setValue(section: String, key: String, value: Any) {
        var sec = storage[section] ?? [:]
        sec[key] = value
        storage[section] = sec
        persist()
        onSectionUpdated?(section, [key: value])
        if section == "video" && key == "aspect", let aspectStr = value as? String {
            onAspectChanged?(aspectStr)
        }
    }

    private func persist() {
        if JSONSerialization.isValidJSONObject(storage),
           let data = try? JSONSerialization.data(withJSONObject: storage) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    var userWebClient: String {
        get { stringValue(section: "main", key: "userWebClient") }
        set { setValue(section: "main", key: "userWebClient", value: newValue) }
    }

    var ignoreSSLErrors: Bool {
        get { boolValue(section: "main", key: "ignoreSSLErrors") }
        set { setValue(section: "main", key: "ignoreSSLErrors", value: newValue) }
    }

    var layoutMode: String {
        get { stringValue(section: "main", key: "layout", fallback: "desktop") }
        set { setValue(section: "main", key: "layout", value: newValue) }
    }

    func orderedSections() -> [[String: Any]] {
        return [
            ["key": "main", "order": 1],
            ["key": "video", "order": 2],
            ["key": "audio", "order": 3]
        ]
    }

    func settingDescriptions() -> [[String: Any]] {
        return [
            [
                "key": "main",
                "settings": [
                    [
                        "key": "layout",
                        "displayName": "UI Layout Mode (reload after change)",
                        "help": "Choose Desktop, Mobile/Touch, or TV interface mode for jellyfin-web.",
                        "options": [
                            ["value": "desktop", "title": "Desktop"],
                            ["value": "mobile", "title": "Mobile / Touch"],
                            ["value": "tv", "title": "TV"]
                        ]
                    ],
                    [
                        "key": "enableMPV",
                        "displayName": "Enable Native Direct Play Engine (MobileVLCKit)",
                        "help": "Uses embedded libVLC + VideoToolbox to Direct Play MKV, ASS/SSA, FLAC, AC3 without server transcoding."
                    ],
                    [
                        "key": "ignoreSSLErrors",
                        "displayName": "Allow Self-Signed SSL Certificates",
                        "help": "Enable only if your local Jellyfin server uses a self-signed HTTPS certificate."
                    ]
                ]
            ],
            [
                "key": "video",
                "settings": [
                    [
                        "key": "hardwareDecoding",
                        "displayName": "Hardware Decoding (VideoToolbox)",
                        "help": "Apple A8X accelerates 8-bit H.264 in hardware. Switch to Disabled to force multi-core FFmpeg software decoding.",
                        "options": [
                            ["value": "enabled", "title": "Enabled (VideoToolbox)"],
                            ["value": "disabled", "title": "Disabled (Software FFmpeg)"]
                        ]
                    ],
                    [
                        "key": "aspect",
                        "displayName": "Aspect Ratio",
                        "help": "Adjust how 16:9 / 21:9 video fits the iPad Air 2 4:3 Retina display.",
                        "options": [
                            ["value": "normal", "title": "Normal (Fit)"],
                            ["value": "zoom", "title": "Zoom (Fill 4:3 Screen)"],
                            ["value": "stretch", "title": "Stretch"],
                            ["value": "force_16_9", "title": "Force 16:9"],
                            ["value": "force_4_3", "title": "Force 4:3"]
                        ]
                    ],
                    [
                        "key": "default_playback_speed",
                        "displayName": "Default Playback Speed",
                        "options": [
                            ["value": 0.5, "title": "0.5x"],
                            ["value": 0.75, "title": "0.75x"],
                            ["value": 1.0, "title": "1x"],
                            ["value": 1.25, "title": "1.25x"],
                            ["value": 1.5, "title": "1.5x"],
                            ["value": 2.0, "title": "2x"]
                        ]
                    ],
                    [
                        "key": "cache",
                        "displayName": "Network Stream Cache",
                        "help": "Tuned for iPad Air 2 (2 GB RAM).",
                        "options": [
                            ["value": 10, "title": "Small (1.5s)"],
                            ["value": 25, "title": "Default (3s)"],
                            ["value": 50, "title": "Large (5s)"]
                        ]
                    ],
                    [
                        "key": "force_transcode_hevc",
                        "displayName": "Force Transcode HEVC (H.265)",
                        "help": "Recommended ON for iPad Air 2 (A8X lacks hardware HEVC). Turn OFF to try software Direct Play on 720p/low-bitrate 8-bit HEVC."
                    ],
                    [
                        "key": "force_transcode_hi10p",
                        "displayName": "Force Transcode 10-bit (Hi10P)",
                        "help": "Recommended ON for A8X. Turn OFF to decode 10-bit H.264 anime in software."
                    ],
                    [
                        "key": "force_transcode_4k",
                        "displayName": "Force Transcode 4K (>1080p)",
                        "help": "Caps Direct Play at 1080p to prevent overloading A8X CPU/RAM."
                    ],
                    [
                        "key": "force_transcode_av1",
                        "displayName": "Force Transcode AV1"
                    ],
                    [
                        "key": "force_transcode_hdr",
                        "displayName": "Force Transcode HDR to SDR"
                    ],
                    [
                        "key": "force_transcode_dovi",
                        "displayName": "Force Transcode Dolby Vision"
                    ],
                    [
                        "key": "always_force_transcode",
                        "displayName": "Always Force Server Transcode"
                    ],
                    [
                        "key": "deinterlace",
                        "displayName": "Deinterlace Video"
                    ]
                ]
            ],
            [
                "key": "audio",
                "settings": [
                    [
                        "key": "channels",
                        "displayName": "Audio Channels",
                        "options": [
                            ["value": "2.0", "title": "Stereo (2.0)"],
                            ["value": "5.1,2.0", "title": "5.1 Surround"],
                            ["value": "auto", "title": "Auto"]
                        ]
                    ]
                ]
            ]
        ]
    }

    var userAgent: String {
        let osVer = UIDevice.current.systemVersion.replacingOccurrences(of: ".", with: "_")
        return "Mozilla/5.0 (iPad; CPU OS \(osVer) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) JellyfinDesktopiOS/1.12.0 Version/15.6 Mobile/15E148 Safari/604.1"
    }

    func buildNativeShellUserScript() -> String {
        guard let webResourcesURL = Bundle.main.resourceURL?.appendingPathComponent("WebResources") else {
            return ""
        }

        var descriptionsMap: [String: Any] = [:]
        for entry in settingDescriptions() {
            if let key = entry["key"] as? String, let settings = entry["settings"] {
                descriptionsMap[key] = settings
            }
        }

        let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.12.0"
        let clientData: [String: Any] = [
            "deviceName": UIDevice.current.name,
            "version": appVersion,
            "userAgent": userAgent,
            "scriptPath": webResourcesURL.absoluteString,
            "mode": layoutMode,
            "sections": orderedSections(),
            "settingsDescriptions": descriptionsMap,
            "settings": allValues()
        ]

        let jsonData = (try? JSONSerialization.data(withJSONObject: clientData)) ?? Data("{}".utf8)
        let base64 = jsonData.base64EncodedString()

        var fullScript = """
        const jmpInfo = JSON.parse(window.atob("\(base64)"));
        window.jmpInfo = jmpInfo;
        """ + "\n"

        let extensionFiles = [
            "ios15Polyfills.js",
            "iosWebChannelShim.js",
            "mpvVideoPlayer.js",
            "mpvAudioPlayer.js",
            "inputPlugin.js",
            "connectivityHelper.js",
            "nativeshell.js"
        ]

        let extDir = webResourcesURL.appendingPathComponent("extension")
        for fileName in extensionFiles {
            let fileURL = extDir.appendingPathComponent(fileName)
            if let content = try? String(contentsOf: fileURL, encoding: .utf8) {
                fullScript += "\n// --- \(fileName) ---\n" + content + "\n"
            } else {
                NSLog("[JellyfinDesktop] Missing extension script: \(fileName)")
            }
        }

        return fullScript
    }
}
