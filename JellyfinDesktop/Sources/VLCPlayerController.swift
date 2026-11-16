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

    var onEmitSignal: ((String, [Any]) -> Void)?

    private var mediaPlayer: VLCMediaPlayer?
    private var videoDrawableView: UIView?

    private var currentStreamUrl: String = ""
    private var currentOptions: [String: Any] = [:]
    private var currentMetadata: [String: Any] = [:]
    private var usingSoftwareFallback = false
    private var didCheckDisplayedFrames = false
    private var playbackPlayingStartPosMs: Int64 = -1

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
    private var currentRatePermille: Int = 1000
    private var currentSubtitleDelayMs: Int64 = 0
    private var currentAudioDelayMs: Int64 = 0

    override init() {
        super.init()
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
        startPlaybackSession(
            url: rawUrl,
            options: options,
            metadata: metadata,
            audioStream: audioStream,
            subtitleStream: subtitleStream,
            forceSoftwareDecoding: false
        )
    }

    private func startPlaybackSession(
        url rawUrl: String,
        options: [String: Any],
        metadata: [String: Any],
        audioStream: Any?,
        subtitleStream: Any?,
        forceSoftwareDecoding: Bool
    ) {
        tearDownActivePlayer(silent: true)

        guard let streamURL = URL(string: rawUrl) else {
            onEmitSignal?("error", ["Invalid media URL"])
            return
        }

        try? AVAudioSession.sharedInstance().setActive(true)

        currentStreamUrl = rawUrl
        currentOptions = options
        currentMetadata = metadata

        let userDisabledHwDec = SettingsStore.shared.stringValue(
            section: "video",
            key: "hardwareDecoding",
            fallback: "enabled"
        ) == "disabled"
        usingSoftwareFallback = forceSoftwareDecoding || userDisabledHwDec
        didCheckDisplayedFrames = false
        playbackPlayingStartPosMs = -1

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

        // Prepare non-zero drawable view BEFORE creating VLCMediaPlayer and calling play()
        if !isAudioOnlyMedia {
            videoContainerView.isHidden = false
            videoContainerView.superview?.layoutIfNeeded()
            videoContainerView.layoutIfNeeded()
            UIApplication.shared.isIdleTimerDisabled = true
        }

        let initialBounds = videoContainerView.bounds.width > 0
            ? videoContainerView.bounds
            : UIScreen.main.bounds
        let drawable = UIView(frame: initialBounds)
        drawable.backgroundColor = .black
        drawable.isUserInteractionEnabled = false
        videoContainerView.addSubview(drawable)
        self.videoDrawableView = drawable

        var vlcOptions: [String] = []
        if usingSoftwareFallback {
            vlcOptions.append("--no-videotoolbox")
        }

        let player = vlcOptions.isEmpty ? VLCMediaPlayer() : VLCMediaPlayer(options: vlcOptions)
        player.delegate = self
        player.drawable = drawable
        self.mediaPlayer = player

        let media = VLCMedia(url: streamURL)

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

        if usingSoftwareFallback {
            media.addOption(":no-videotoolbox")
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

        player.media = media
        layoutVideoDrawable()

        // Attach external subtitle slave if provided as "#,https://..."
        if let subStr = subtitleStream as? String, subStr.hasPrefix("#,") {
            let extUrlStr = String(subStr.dropFirst(2))
            if let extURL = URL(string: extUrlStr) {
                player.addPlaybackSlave(extURL, type: .subtitle, enforce: true)
            }
        }

        let autoplay = (options["autoplay"] as? Bool) ?? true
        player.play()
        if !autoplay {
            player.pause()
        }
    }

    func play() {
        if !isAudioOnlyMedia {
            UIApplication.shared.isIdleTimerDisabled = true
            videoContainerView.isHidden = false
        }
        mediaPlayer?.play()
    }

    func pause() {
        mediaPlayer?.pause()
    }

    func stop() {
        tearDownActivePlayer(silent: false)
    }

    /// Detaches drawable & delegate immediately on main thread and stops libVLC asynchronously
    /// so tearing down OpenGL ES vout never races with the next movie's drawable view.
    private func tearDownActivePlayer(silent: Bool) {
        isStoppingManually = true
        UIApplication.shared.isIdleTimerDisabled = false

        let oldPlayer = self.mediaPlayer
        let oldDrawable = self.videoDrawableView
        self.mediaPlayer = nil
        self.videoDrawableView = nil

        oldPlayer?.delegate = nil
        oldPlayer?.drawable = nil
        oldDrawable?.removeFromSuperview()
        videoContainerView.isHidden = true

        if let playerToStop = oldPlayer {
            DispatchQueue.global(qos: .userInitiated).async {
                playerToStop.stop()
                playerToStop.media = nil
            }
        }

        if !silent {
            onEmitSignal?("canceled", [])
            onEmitSignal?("stopped", [])
        }
    }

    func seekTo(ms: Int64) {
        guard let player = mediaPlayer else { return }
        let clamped = max(Int64(0), ms)
        player.time = VLCTime(int: Int32(clamping: clamped))
        lastReportedPositionMs = clamped
        playbackPlayingStartPosMs = -1
        onEmitSignal?("positionUpdate", [clamped])
    }

    func currentPositionMs() -> Int64 {
        guard let player = mediaPlayer else { return 0 }
        return max(0, Int64(player.time.intValue))
    }

    func currentDurationMs() -> Int64 {
        let raw = Int64(mediaPlayer?.media?.length.intValue ?? 0)
        return raw > 0 ? raw : lastKnownDurationMs
    }

    func setVolume(_ volume: Int) {
        currentVolume = min(100, max(0, volume))
        if !currentMuted {
            mediaPlayer?.audio?.volume = Int32(currentVolume)
        }
    }

    func setMuted(_ muted: Bool) {
        currentMuted = muted
        mediaPlayer?.audio?.isMuted = muted
        mediaPlayer?.audio?.volume = muted ? 0 : Int32(currentVolume)
    }

    func setPlaybackRate(permille: Int) {
        currentRatePermille = permille
        let rate = max(0.25, min(4.0, Float(permille) / 1000.0))
        mediaPlayer?.rate = rate
        onEmitSignal?("playbackRateChanged", [Double(rate)])
    }

    func setAudioStream(_ streamParam: Any?) {
        pendingAudioStream = streamParam
        applyAudioStreamIfReady(streamParam)
    }

    func setSubtitleStream(_ streamParam: Any?) {
        pendingSubtitleStream = streamParam
        if let subStr = streamParam as? String, subStr.hasPrefix("#,") {
            let extUrlStr = String(subStr.dropFirst(2))
            if let extURL = URL(string: extUrlStr) {
                mediaPlayer?.addPlaybackSlave(extURL, type: .subtitle, enforce: true)
            }
            return
        }
        applySubtitleStreamIfReady(streamParam)
    }

    func setSubtitleDelay(ms: Int64) {
        currentSubtitleDelayMs = ms
        mediaPlayer?.currentVideoSubTitleDelay = Int(ms) * 1000
    }

    func setAudioDelay(ms: Int64) {
        currentAudioDelayMs = ms
        mediaPlayer?.currentAudioPlaybackDelay = Int(ms) * 1000
    }

    func setVideoRectangle(x: Int, y: Int, w: Int, h: Int) {
        if x < 0 {
            videoContainerView.isHidden = true
        } else if !isAudioOnlyMedia && mediaPlayer != nil {
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
            if str.hasPrefix("#,") { return nil }
            let cleaned = str.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
            if cleaned.isEmpty { return -1 }
            return Int(cleaned)
        }
        return nil
    }

    private func ensurePrimaryVideoTrackSelected() {
        guard !isAudioOnlyMedia, let player = mediaPlayer else { return }
        if player.currentVideoTrackIndex < 0 {
            let rawVideoIds = (player.videoTrackIndexes as? [NSNumber])?.map { $0.int32Value } ?? []
            if let firstValidVideoId = rawVideoIds.first(where: { $0 >= 0 }) {
                player.currentVideoTrackIndex = firstValidVideoId
            }
        }
    }

    private func applyAudioStreamIfReady(_ param: Any?) {
        guard let player = mediaPlayer, let relIndex = parseRelativeTrackIndex(param) else { return }
        if relIndex <= 0 {
            player.currentAudioTrackIndex = -1
            return
        }
        let rawIds = (player.audioTrackIndexes as? [NSNumber])?.map { $0.int32Value } ?? []
        let validIds = rawIds.filter { $0 >= 0 }
        guard !validIds.isEmpty else { return }
        let targetIdx = min(max(0, relIndex - 1), validIds.count - 1)
        player.currentAudioTrackIndex = validIds[targetIdx]
    }

    private func applySubtitleStreamIfReady(_ param: Any?) {
        guard let player = mediaPlayer, let relIndex = parseRelativeTrackIndex(param) else { return }
        if relIndex <= 0 {
            player.currentVideoSubTitleIndex = -1
            return
        }
        let rawIds = (player.videoSubTitlesIndexes as? [NSNumber])?.map { $0.int32Value } ?? []
        let validIds = rawIds.filter { $0 >= 0 }
        guard !validIds.isEmpty else { return }
        let targetIdx = min(max(0, relIndex - 1), validIds.count - 1)
        player.currentVideoSubTitleIndex = validIds[targetIdx]
    }

    // MARK: - Aspect Ratio Layout (4:3 iPad Air 2 Retina display support)

    func layoutVideoDrawable() {
        guard let drawable = videoDrawableView else { return }
        let bounds = videoContainerView.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }

        let aspectSetting = SettingsStore.shared.stringValue(section: "video", key: "aspect", fallback: "normal")
        let videoSize = mediaPlayer?.videoSize ?? .zero
        let sourceAspect: CGFloat = (videoSize.width > 0 && videoSize.height > 0)
            ? (videoSize.width / videoSize.height)
            : (16.0 / 9.0)
        let containerAspect = bounds.width / bounds.height

        switch aspectSetting {
        case "zoom":
            var drawW = bounds.width
            var drawH = bounds.height
            if sourceAspect > containerAspect {
                drawW = bounds.height * sourceAspect
            } else {
                drawH = bounds.width / sourceAspect
            }
            drawable.frame = CGRect(
                x: (bounds.width - drawW) * 0.5,
                y: (bounds.height - drawH) * 0.5,
                width: drawW,
                height: drawH
            )

        case "stretch":
            var drawW = bounds.width
            var drawH = bounds.height
            if sourceAspect > containerAspect {
                drawH = bounds.height * (sourceAspect / containerAspect)
            } else {
                drawW = bounds.width * (containerAspect / sourceAspect)
            }
            drawable.frame = CGRect(
                x: (bounds.width - drawW) * 0.5,
                y: (bounds.height - drawH) * 0.5,
                width: drawW,
                height: drawH
            )

        case "force_16_9":
            let targetH = bounds.width * (9.0 / 16.0)
            drawable.frame = CGRect(
                x: 0,
                y: (bounds.height - targetH) * 0.5,
                width: bounds.width,
                height: targetH
            )

        case "force_4_3":
            let targetW = min(bounds.width, bounds.height * (4.0 / 3.0))
            let targetH = targetW * (3.0 / 4.0)
            drawable.frame = CGRect(
                x: (bounds.width - targetW) * 0.5,
                y: (bounds.height - targetH) * 0.5,
                width: targetW,
                height: targetH
            )

        default:
            drawable.frame = bounds
        }
    }

    // MARK: - Self-Healing VideoToolbox -> Software FFmpeg Fallback

    private func checkVideoOutputHealth(atPositionMs posMs: Int64) {
        guard !isAudioOnlyMedia,
              !usingSoftwareFallback,
              !didCheckDisplayedFrames,
              let player = mediaPlayer,
              let media = player.media else {
            return
        }

        if playbackPlayingStartPosMs < 0 {
            playbackPlayingStartPosMs = posMs
            return
        }

        let elapsedPlayingMs = posMs - playbackPlayingStartPosMs
        guard elapsedPlayingMs >= 2200 else { return }

        didCheckDisplayedFrames = true
        let displayed = Int(media.numberOfDisplayedPictures)
        if displayed == 0 {
            NSLog("[JellyfinDesktop] VideoToolbox displayed 0 frames after \(elapsedPlayingMs)ms; switching to software FFmpeg (--no-videotoolbox) at \(posMs)ms")
            var retryOptions = currentOptions
            retryOptions["startMilliseconds"] = posMs
            retryOptions["autoplay"] = true
            let savedAudio = pendingAudioStream
            let savedSub = pendingSubtitleStream
            let savedUrl = currentStreamUrl
            let savedMeta = currentMetadata

            startPlaybackSession(
                url: savedUrl,
                options: retryOptions,
                metadata: savedMeta,
                audioStream: savedAudio,
                subtitleStream: savedSub,
                forceSoftwareDecoding: true
            )
        }
    }

    // MARK: - VLCMediaPlayerDelegate

    func mediaPlayerStateChanged(_ aNotification: Notification) {
        guard let player = aNotification.object as? VLCMediaPlayer,
              player === self.mediaPlayer else {
            return
        }

        let state = player.state

        switch state {
        case .playing:
            if !hasEmittedInitialPlaying {
                hasEmittedInitialPlaying = true

                ensurePrimaryVideoTrackSelected()
                if let audio = pendingAudioStream {
                    applyAudioStreamIfReady(audio)
                }
                if let sub = pendingSubtitleStream, !(sub is String && (sub as! String).hasPrefix("#,")) {
                    applySubtitleStreamIfReady(sub)
                }
                if currentSubtitleDelayMs != 0 {
                    player.currentVideoSubTitleDelay = Int(currentSubtitleDelayMs) * 1000
                }
                if currentAudioDelayMs != 0 {
                    player.currentAudioPlaybackDelay = Int(currentAudioDelayMs) * 1000
                }
                if currentRatePermille != 1000 {
                    player.rate = max(0.25, min(4.0, Float(currentRatePermille) / 1000.0))
                }
                setMuted(currentMuted)
                if pendingStartMs > 0 {
                    let currentPos = currentPositionMs()
                    if abs(currentPos - pendingStartMs) > 3000 {
                        player.time = VLCTime(int: Int32(clamping: pendingStartMs))
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
            if !isAudioOnlyMedia && !usingSoftwareFallback && !isStoppingManually {
                NSLog("[JellyfinDesktop] VLCMediaPlayer hardware decode error; retrying with software FFmpeg (--no-videotoolbox)")
                var retryOptions = currentOptions
                if lastReportedPositionMs > 0 {
                    retryOptions["startMilliseconds"] = lastReportedPositionMs
                }
                startPlaybackSession(
                    url: currentStreamUrl,
                    options: retryOptions,
                    metadata: currentMetadata,
                    audioStream: pendingAudioStream,
                    subtitleStream: pendingSubtitleStream,
                    forceSoftwareDecoding: true
                )
                return
            }
            UIApplication.shared.isIdleTimerDisabled = false
            videoContainerView.isHidden = true
            if !isStoppingManually {
                onEmitSignal?("error", ["MobileVLCKit failed to decode or stream media"])
            }

        case .opening, .esAdded:
            if state == .esAdded && hasEmittedInitialPlaying {
                ensurePrimaryVideoTrackSelected()
                if let audio = pendingAudioStream {
                    applyAudioStreamIfReady(audio)
                }
                if let sub = pendingSubtitleStream, !(sub is String && (sub as! String).hasPrefix("#,")) {
                    applySubtitleStreamIfReady(sub)
                }
                layoutVideoDrawable()
            }

        @unknown default:
            break
        }
    }

    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        guard let player = aNotification.object as? VLCMediaPlayer,
              player === self.mediaPlayer else {
            return
        }

        let dur = currentDurationMs()
        if dur > 0 && dur != lastKnownDurationMs {
            lastKnownDurationMs = dur
            onEmitSignal?("updateDuration", [dur])
        }

        let pos = currentPositionMs()
        checkVideoOutputHealth(atPositionMs: pos)

        if lastReportedPositionMs < 0 || abs(pos - lastReportedPositionMs) >= 150 {
            lastReportedPositionMs = pos
            onEmitSignal?("positionUpdate", [pos])
        }
    }
}
