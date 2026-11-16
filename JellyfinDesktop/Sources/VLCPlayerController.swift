import UIKit
import AVFoundation
#if canImport(MobileVLCKit)
import MobileVLCKit
#endif

final class VLCPlayerController: NSObject, VLCMediaPlayerDelegate {

    let videoContainerView: UIView = {
        let view = UIView()
        view.backgroundColor = .black
        view.clipsToBounds = true
        view.isUserInteractionEnabled = false
        view.isHidden = true
        return view
    }()

    private let videoDrawableView: UIView = {
        let view = UIView()
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        return view
    }()

    var onEmitSignal: ((String, [Any]) -> Void)?

    private let mediaPlayer = VLCMediaPlayer()

    private var isStoppingManually = false
    private var hasEmittedInitialPlaying = false
    private var isAudioOnlyMedia = false
    private var pendingStartMs: Int64 = 0
    private var pendingAudioStream: Any?
    private var pendingSubtitleStream: Any?
    private var lastReportedPositionMs: Int64 = -1
    private var lastKnownDurationMs: Int64 = 0
    private var currentVolume: Int = 100
    private var currentMuted: Bool = false

    override init() {
        super.init()
        videoContainerView.addSubview(videoDrawableView)
        mediaPlayer.delegate = self
        mediaPlayer.drawable = videoDrawableView

        SettingsStore.shared.onAspectChanged = { [weak self] _ in
            DispatchQueue.main.async {
                self?.layoutVideoDrawable()
            }
        }
    }

    func updateContainerBounds() {
        layoutVideoDrawable()
    }

    // MARK: - Playback Control

    func load(
        url rawUrl: String,
        options: [String: Any],
        metadata: [String: Any],
        audioStream: Any?,
        subtitleStream: Any?
    ) {
        stopInternal(silent: true)

        guard let streamURL = URL(string: rawUrl) else {
            onEmitSignal?("error", ["Invalid media URL"])
            return
        }

        try? AVAudioSession.sharedInstance().setActive(true)

        let mediaType = (metadata["type"] as? String)?.lowercased() ?? "video"
        isAudioOnlyMedia = (mediaType == "music" || mediaType == "audio")
        isStoppingManually = false
        hasEmittedInitialPlaying = false
        lastReportedPositionMs = -1
        lastKnownDurationMs = 0

        let startMs: Int64
        if let n = options["startMilliseconds"] as? NSNumber {
            startMs = n.int64Value
        } else {
            startMs = 0
        }
        pendingStartMs = startMs
        pendingAudioStream = audioStream
        pendingSubtitleStream = subtitleStream

        let media = VLCMedia(url: streamURL)

        // Network cache tuned for iPad Air 2 (2 GB RAM)
        let cacheSetting = SettingsStore.shared.intValue(section: "video", key: "cache", fallback: 25)
        let cachingMs: Int
        if cacheSetting <= 10 {
            cachingMs = 1500
        } else if cacheSetting >= 50 {
            cachingMs = 5000
        } else {
            cachingMs = 3000
        }
        media.addOption(":network-caching=\(cachingMs)")

        let userAgent = ((metadata["headers"] as? [String: Any])?["User-Agent"] as? String)
            ?? SettingsStore.shared.userAgent
        media.addOption(":http-user-agent=\(userAgent)")

        if SettingsStore.shared.stringValue(section: "video", key: "hardwareDecoding", fallback: "enabled") == "disabled" {
            media.addOption(":avcodec-hw=none")
        }

        if SettingsStore.shared.boolValue(section: "video", key: "deinterlace") {
            media.addOption(":deinterlace=1")
        }

        if SettingsStore.shared.ignoreSSLErrors {
            media.addOption(":gnutls-verify-trust=0")
        }

        if startMs > 0 {
            let startSeconds = String(format: "%.3f", Double(startMs) / 1000.0)
            media.addOption(":start-time=\(startSeconds)")
        }

        mediaPlayer.media = media

        if !isAudioOnlyMedia {
            videoContainerView.isHidden = false
            layoutVideoDrawable()
            UIApplication.shared.isIdleTimerDisabled = true
        }

        // Attach external subtitle slave immediately if provided as "#,https://..."
        if let subStr = subtitleStream as? String, subStr.hasPrefix("#,") {
            let extUrlStr = String(subStr.dropFirst(2))
            if let extURL = URL(string: extUrlStr) {
                mediaPlayer.addPlaybackSlave(extURL, type: .subtitle, enforce: true)
                pendingSubtitleStream = nil
            }
        }

        let autoplay = (options["autoplay"] as? Bool) ?? true
        mediaPlayer.play()
        if !autoplay {
            mediaPlayer.pause()
        }
    }

    func play() {
        if !isAudioOnlyMedia {
            UIApplication.shared.isIdleTimerDisabled = true
        }
        mediaPlayer.play()
    }

    func pause() {
        mediaPlayer.pause()
    }

    func stop() {
        stopInternal(silent: false)
    }

    private func stopInternal(silent: Bool) {
        isStoppingManually = true
        UIApplication.shared.isIdleTimerDisabled = false
        if mediaPlayer.isPlaying || mediaPlayer.media != nil {
            mediaPlayer.stop()
            mediaPlayer.media = nil
        }
        videoContainerView.isHidden = true
        if !silent {
            onEmitSignal?("canceled", [])
            onEmitSignal?("stopped", [])
        }
    }

    func seekTo(ms: Int64) {
        let clamped = max(Int64(0), ms)
        mediaPlayer.time = VLCTime(int: Int32(clamping: clamped))
        lastReportedPositionMs = clamped
        onEmitSignal?("positionUpdate", [clamped])
    }

    func currentPositionMs() -> Int64 {
        let raw = Int64(mediaPlayer.time.intValue)
        return max(0, raw)
    }

    func currentDurationMs() -> Int64 {
        let raw = Int64(mediaPlayer.media?.length.intValue ?? 0)
        return raw > 0 ? raw : lastKnownDurationMs
    }

    func setVolume(_ volume: Int) {
        currentVolume = min(100, max(0, volume))
        if !currentMuted {
            mediaPlayer.audio?.volume = Int32(currentVolume)
        }
    }

    func setMuted(_ muted: Bool) {
        currentMuted = muted
        mediaPlayer.audio?.isMuted = muted
        mediaPlayer.audio?.volume = muted ? 0 : Int32(currentVolume)
    }

    func setPlaybackRate(permille: Int) {
        let rate = max(0.25, min(4.0, Float(permille) / 1000.0))
        mediaPlayer.rate = rate
        onEmitSignal?("playbackRateChanged", [Double(rate)])
    }

    func setAudioStream(_ streamParam: Any?) {
        pendingAudioStream = streamParam
        applyAudioStreamIfReady(streamParam)
    }

    func setSubtitleStream(_ streamParam: Any?) {
        if let subStr = streamParam as? String, subStr.hasPrefix("#,") {
            let extUrlStr = String(subStr.dropFirst(2))
            if let extURL = URL(string: extUrlStr) {
                pendingSubtitleStream = nil
                mediaPlayer.addPlaybackSlave(extURL, type: .subtitle, enforce: true)
            }
            return
        }
        pendingSubtitleStream = streamParam
        applySubtitleStreamIfReady(streamParam)
    }

    func setSubtitleDelay(ms: Int64) {
        mediaPlayer.currentVideoSubTitleDelay = Int(ms) * 1000
    }

    func setAudioDelay(ms: Int64) {
        mediaPlayer.currentAudioPlaybackDelay = Int(ms) * 1000
    }

    func setVideoRectangle(x: Int, y: Int, w: Int, h: Int) {
        if x < 0 {
            videoContainerView.isHidden = true
        } else if !isAudioOnlyMedia && mediaPlayer.media != nil {
            videoContainerView.isHidden = false
            layoutVideoDrawable()
        }
    }

    // MARK: - Track Mapping (1-based relative index from mpvVideoPlayer.js -> libVLC track IDs)

    private func parseRelativeTrackIndex(_ param: Any?) -> Int? {
        if let num = param as? NSNumber {
            return num.intValue
        }
        if let str = param as? String {
            let cleaned = str.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
            if cleaned.isEmpty { return -1 }
            return Int(cleaned)
        }
        return nil
    }

    private func applyAudioStreamIfReady(_ param: Any?) {
        guard let relIndex = parseRelativeTrackIndex(param) else { return }
        if relIndex <= 0 {
            mediaPlayer.currentAudioTrackIndex = -1
            return
        }
        let rawIds = (mediaPlayer.audioTrackIndexes as? [NSNumber])?.map { $0.int32Value } ?? []
        let validIds = rawIds.filter { $0 >= 0 }
        guard !validIds.isEmpty else { return }
        let targetIdx = min(max(0, relIndex - 1), validIds.count - 1)
        mediaPlayer.currentAudioTrackIndex = validIds[targetIdx]
    }

    private func applySubtitleStreamIfReady(_ param: Any?) {
        guard let relIndex = parseRelativeTrackIndex(param) else { return }
        if relIndex <= 0 {
            mediaPlayer.currentVideoSubTitleIndex = -1
            return
        }
        let rawIds = (mediaPlayer.videoSubTitlesIndexes as? [NSNumber])?.map { $0.int32Value } ?? []
        let validIds = rawIds.filter { $0 >= 0 }
        guard !validIds.isEmpty else { return }
        let targetIdx = min(max(0, relIndex - 1), validIds.count - 1)
        mediaPlayer.currentVideoSubTitleIndex = validIds[targetIdx]
    }

    // MARK: - Aspect Ratio Layout (4:3 iPad Air 2 Retina display support)

    func layoutVideoDrawable() {
        let bounds = videoContainerView.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }

        let aspectSetting = SettingsStore.shared.stringValue(section: "video", key: "aspect", fallback: "normal")
        let videoSize = mediaPlayer.videoSize
        let sourceAspect: CGFloat = (videoSize.width > 0 && videoSize.height > 0)
            ? (videoSize.width / videoSize.height)
            : (16.0 / 9.0)
        let containerAspect = bounds.width / bounds.height

        switch aspectSetting {
        case "zoom":
            // Proportionally scale up so video fills the entire 4:3 iPad screen with no black bars
            var drawW = bounds.width
            var drawH = bounds.height
            if sourceAspect > containerAspect {
                drawW = bounds.height * sourceAspect
            } else {
                drawH = bounds.width / sourceAspect
            }
            videoDrawableView.frame = CGRect(
                x: (bounds.width - drawW) * 0.5,
                y: (bounds.height - drawH) * 0.5,
                width: drawW,
                height: drawH
            )

        case "stretch":
            // Stretch video to fill 4:3 container
            var drawW = bounds.width
            var drawH = bounds.height
            if sourceAspect > containerAspect {
                drawH = bounds.height * (sourceAspect / containerAspect)
            } else {
                drawW = bounds.width * (containerAspect / sourceAspect)
            }
            videoDrawableView.frame = CGRect(
                x: (bounds.width - drawW) * 0.5,
                y: (bounds.height - drawH) * 0.5,
                width: drawW,
                height: drawH
            )

        case "force_16_9":
            let targetH = bounds.width * (9.0 / 16.0)
            videoDrawableView.frame = CGRect(
                x: 0,
                y: (bounds.height - targetH) * 0.5,
                width: bounds.width,
                height: targetH
            )

        case "force_4_3":
            let targetW = min(bounds.width, bounds.height * (4.0 / 3.0))
            let targetH = targetW * (3.0 / 4.0)
            videoDrawableView.frame = CGRect(
                x: (bounds.width - targetW) * 0.5,
                y: (bounds.height - targetH) * 0.5,
                width: targetW,
                height: targetH
            )

        default:
            videoDrawableView.frame = bounds
        }
    }

    // MARK: - VLCMediaPlayerDelegate

    func mediaPlayerStateChanged(_ aNotification: Notification) {
        let state = mediaPlayer.state

        switch state {
        case .playing:
            if !hasEmittedInitialPlaying {
                hasEmittedInitialPlaying = true

                if let audio = pendingAudioStream {
                    applyAudioStreamIfReady(audio)
                }
                if let sub = pendingSubtitleStream {
                    applySubtitleStreamIfReady(sub)
                }
                if pendingStartMs > 0 {
                    let currentPos = currentPositionMs()
                    if abs(currentPos - pendingStartMs) > 3000 {
                        mediaPlayer.time = VLCTime(int: Int32(clamping: pendingStartMs))
                    }
                    pendingStartMs = 0
                }
                layoutVideoDrawable()
            }

            let dur = currentDurationMs()
            if dur > 0 && dur != lastKnownDurationMs {
                lastKnownDurationMs = dur
                onEmitSignal?("updateDuration", [dur])
            }

            onEmitSignal?("playing", [])

        case .paused:
            onEmitSignal?("paused", [])

        case .buffering:
            onEmitSignal?("buffering", [50])

        case .ended:
            UIApplication.shared.isIdleTimerDisabled = false
            videoContainerView.isHidden = true
            if !isStoppingManually {
                onEmitSignal?("finished", [])
                onEmitSignal?("stopped", [])
            }

        case .stopped:
            UIApplication.shared.isIdleTimerDisabled = false

        case .error:
            UIApplication.shared.isIdleTimerDisabled = false
            videoContainerView.isHidden = true
            if !isStoppingManually {
                onEmitSignal?("error", ["MobileVLCKit failed to decode or stream media"])
            }

        case .opening, .esAdded:
            if state == .esAdded && hasEmittedInitialPlaying {
                if let audio = pendingAudioStream {
                    applyAudioStreamIfReady(audio)
                }
                if let sub = pendingSubtitleStream {
                    applySubtitleStreamIfReady(sub)
                }
                layoutVideoDrawable()
            }

        @unknown default:
            break
        }
    }

    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        let dur = currentDurationMs()
        if dur > 0 && dur != lastKnownDurationMs {
            lastKnownDurationMs = dur
            onEmitSignal?("updateDuration", [dur])
        }

        let pos = currentPositionMs()
        if lastReportedPositionMs < 0 || abs(pos - lastReportedPositionMs) >= 150 {
            lastReportedPositionMs = pos
            onEmitSignal?("positionUpdate", [pos])
        }
    }
}
