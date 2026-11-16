import UIKit
import AVFoundation
import CoreMedia
#if canImport(MobileVLCKit)
import MobileVLCKit
#endif

private final class AVPlayerContainerView: UIView {
    override static var layerClass: AnyClass {
        return AVPlayerLayer.self
    }

    var playerLayer: AVPlayerLayer {
        return layer as! AVPlayerLayer
    }
}

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

    // Active backend (either native AVPlayer for HLS/MP4, or MobileVLCKit for MKV/AVI/WebM/etc.)
    private var usingAVPlayer = false

    // AVPlayer state
    private var avPlayer: AVPlayer?
    private var avPlayerView: AVPlayerContainerView?
    private var avStatusObservation: NSKeyValueObservation?
    private var avTimeObserver: Any?
    private var avEndObserver: NSObjectProtocol?

    // MobileVLCKit state
    private var mediaPlayer: VLCMediaPlayer?
    private var videoDrawableView: UIView?
    private var vlcSeekDebounceWorkItem: DispatchWorkItem?
    private var vlcStallWatchdogWorkItem: DispatchWorkItem?

    // Shared session state
    private var currentStreamUrl: String = ""
    private var currentOptions: [String: Any] = [:]
    private var currentMetadata: [String: Any] = [:]
    private var usingSoftwareFallback = false
    private var didCheckDisplayedFrames = false
    private var playbackPlayingStartPosMs: Int64 = -1

    private var isStoppingManually = false
    private var isPausedByUser = false
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

    // MARK: - Engine Selection

    private func shouldUseNativeAVPlayer(
        url rawUrl: String,
        audioStream: Any?,
        forceVLC: Bool
    ) -> Bool {
        if forceVLC || SettingsStore.shared.ignoreSSLErrors {
            return false
        }
        let lower = rawUrl.lowercased()
        let parsedPath = URL(string: rawUrl)?.path.lowercased() ?? lower

        // Always use Apple's native AVPlayer for HLS (.m3u8) transcodes — instant start & zero seek freezes
        if parsedPath.hasSuffix(".m3u8") || lower.contains(".m3u8") {
            return true
        }

        // Also use AVPlayer for standard single-audio MP4/M4V/MOV when hardware decoding is enabled
        let hwEnabled = SettingsStore.shared.stringValue(section: "video", key: "hardwareDecoding", fallback: "enabled") != "disabled"
        let audioIdx = parseRelativeTrackIndex(audioStream) ?? 1
        if hwEnabled && audioIdx <= 1 && (parsedPath.hasSuffix(".mp4") || parsedPath.hasSuffix(".m4v") || parsedPath.hasSuffix(".mov")) {
            return true
        }

        return false
    }

    // MARK: - Playback Control

    func load(
        url rawUrl: String,
        options: [String: Any],
        metadata: [String: Any],
        audioStream: Any?,
        subtitleStream: Any?
    ) {
        let useAV = shouldUseNativeAVPlayer(url: rawUrl, audioStream: audioStream, forceVLC: false)
        if useAV {
            startAVPlayerSession(
                url: rawUrl,
                options: options,
                metadata: metadata,
                audioStream: audioStream,
                subtitleStream: subtitleStream
            )
        } else {
            startVLCPlaybackSession(
                url: rawUrl,
                options: options,
                metadata: metadata,
                audioStream: audioStream,
                subtitleStream: subtitleStream,
                forceSoftwareDecoding: false
            )
        }
    }

    // MARK: - Native AVPlayer Backend (HLS & MP4)

    private func startAVPlayerSession(
        url rawUrl: String,
        options: [String: Any],
        metadata: [String: Any],
        audioStream: Any?,
        subtitleStream: Any?
    ) {
        tearDownAllPlayers(silent: true)

        guard let streamURL = URL(string: rawUrl) else {
            onEmitSignal?("error", ["Invalid media URL"])
            return
        }

        try? AVAudioSession.sharedInstance().setActive(true)

        usingAVPlayer = true
        currentStreamUrl = rawUrl
        currentOptions = options
        currentMetadata = metadata
        pendingAudioStream = audioStream
        pendingSubtitleStream = subtitleStream

        let mediaType = (metadata["type"] as? String)?.lowercased() ?? "video"
        isAudioOnlyMedia = (mediaType == "music" || mediaType == "audio")
        isStoppingManually = false
        let autoplay = (options["autoplay"] as? Bool) ?? true
        isPausedByUser = !autoplay
        hasEmittedInitialPlaying = false
        lastReportedPositionMs = -1
        lastKnownDurationMs = 0

        let startMs = (options["startMilliseconds"] as? NSNumber)?.int64Value ?? 0
        pendingStartMs = startMs

        if !isAudioOnlyMedia {
            videoContainerView.isHidden = false
            videoContainerView.superview?.layoutIfNeeded()
            videoContainerView.layoutIfNeeded()
            UIApplication.shared.isIdleTimerDisabled = true
        }

        let initialBounds = videoContainerView.bounds.width > 0
            ? videoContainerView.bounds
            : UIScreen.main.bounds
        let playerView = AVPlayerContainerView(frame: initialBounds)
        playerView.backgroundColor = .black
        playerView.isUserInteractionEnabled = false
        videoContainerView.addSubview(playerView)
        self.avPlayerView = playerView

        let userAgent = ((metadata["headers"] as? [String: Any])?["User-Agent"] as? String)
            ?? SettingsStore.shared.userAgent
        let asset = AVURLAsset(
            url: streamURL,
            options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": userAgent]]
        )
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 8.0

        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        player.isMuted = currentMuted
        player.volume = currentMuted ? 0.0 : (Float(currentVolume) / 100.0)
        playerView.playerLayer.player = player
        self.avPlayer = player
        layoutVideoDrawable()

        avStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] observedItem, _ in
            DispatchQueue.main.async {
                self?.handleAVItemStatusChanged(observedItem)
            }
        }

        let interval = CMTime(seconds: 0.15, preferredTimescale: 600)
        avTimeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] cmTime in
            guard let self = self, self.usingAVPlayer, !self.isStoppingManually else { return }
            let secs = CMTimeGetSeconds(cmTime)
            guard secs.isFinite && secs >= 0 else { return }
            let posMs = Int64(secs * 1000.0)

            if let dur = self.avPlayer?.currentItem?.duration {
                let durSecs = CMTimeGetSeconds(dur)
                if durSecs.isFinite && durSecs > 0 {
                    let durMs = Int64(durSecs * 1000.0)
                    if durMs != self.lastKnownDurationMs {
                        self.lastKnownDurationMs = durMs
                        self.onEmitSignal?("updateDuration", [durMs])
                    }
                }
            }

            if self.lastReportedPositionMs < 0 || abs(posMs - self.lastReportedPositionMs) >= 150 {
                self.lastReportedPositionMs = posMs
                self.onEmitSignal?("positionUpdate", [posMs])
            }
        }

        avEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, self.usingAVPlayer, !self.isStoppingManually else { return }
            UIApplication.shared.isIdleTimerDisabled = false
            self.videoContainerView.isHidden = true
            self.onEmitSignal?("finished", [])
            self.onEmitSignal?("stopped", [])
        }
    }

    private func handleAVItemStatusChanged(_ item: AVPlayerItem) {
        guard usingAVPlayer, let player = avPlayer, !isStoppingManually else { return }

        switch item.status {
        case .readyToPlay:
            if !hasEmittedInitialPlaying {
                hasEmittedInitialPlaying = true

                let durSecs = CMTimeGetSeconds(item.duration)
                if durSecs.isFinite && durSecs > 0 {
                    let durMs = Int64(durSecs * 1000.0)
                    lastKnownDurationMs = durMs
                    onEmitSignal?("updateDuration", [durMs])
                }

                layoutVideoDrawable()

                let rate = max(0.25, min(4.0, Float(currentRatePermille) / 1000.0))
                if pendingStartMs > 0 {
                    let targetTime = CMTime(value: pendingStartMs, timescale: 1000)
                    pendingStartMs = 0
                    player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                        guard let self = self, !self.isStoppingManually else { return }
                        if !self.isPausedByUser {
                            player.playImmediately(atRate: rate)
                            self.onEmitSignal?("playing", [])
                        }
                    }
                } else {
                    if !isPausedByUser {
                        player.playImmediately(atRate: rate)
                        onEmitSignal?("playing", [])
                    }
                }
            }

        case .failed:
            NSLog("[JellyfinDesktop] AVPlayer failed (\(String(describing: item.error))); falling back to MobileVLCKit")
            var fallbackOptions = currentOptions
            if lastReportedPositionMs > 0 {
                fallbackOptions["startMilliseconds"] = lastReportedPositionMs
            }
            startVLCPlaybackSession(
                url: currentStreamUrl,
                options: fallbackOptions,
                metadata: currentMetadata,
                audioStream: pendingAudioStream,
                subtitleStream: pendingSubtitleStream,
                forceSoftwareDecoding: false
            )

        case .unknown:
            break
        @unknown default:
            break
        }
    }

    // MARK: - MobileVLCKit Backend (MKV / AVI / WebM / Multi-Track Direct Play)

    private func startVLCPlaybackSession(
        url rawUrl: String,
        options: [String: Any],
        metadata: [String: Any],
        audioStream: Any?,
        subtitleStream: Any?,
        forceSoftwareDecoding: Bool
    ) {
        tearDownAllPlayers(silent: true)

        guard let streamURL = URL(string: rawUrl) else {
            onEmitSignal?("error", ["Invalid media URL"])
            return
        }

        try? AVAudioSession.sharedInstance().setActive(true)

        usingAVPlayer = false
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
        let autoplay = (options["autoplay"] as? Bool) ?? true
        isPausedByUser = !autoplay
        hasEmittedInitialPlaying = false
        lastReportedPositionMs = -1
        lastKnownDurationMs = 0

        let startMs = (options["startMilliseconds"] as? NSNumber)?.int64Value ?? 0
        pendingStartMs = startMs
        pendingAudioStream = audioStream
        pendingSubtitleStream = subtitleStream

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

        var vlcOptions: [String] = ["--http-reconnect"]
        if usingSoftwareFallback {
            vlcOptions.append("--no-videotoolbox")
        }

        let player = VLCMediaPlayer(options: vlcOptions)
        player.delegate = self
        player.drawable = drawable
        self.mediaPlayer = player

        let media = VLCMedia(url: streamURL)

        let cacheSetting = SettingsStore.shared.intValue(section: "video", key: "cache", fallback: 25)
        let cachingMs: Int
        if cacheSetting <= 10 {
            cachingMs = 2000
        } else if cacheSetting >= 50 {
            cachingMs = 6000
        } else {
            cachingMs = 3500
        }
        media.addOption(":network-caching=\(cachingMs)")
        media.addOption(":http-reconnect")

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

        player.play()
        if !autoplay {
            player.pause()
        }

        scheduleVLCStallWatchdog(expectedAfterSeekMs: startMs)
    }

    private func scheduleVLCStallWatchdog(expectedAfterSeekMs: Int64) {
        vlcStallWatchdogWorkItem?.cancel()
        guard !isAudioOnlyMedia, !usingSoftwareFallback else { return }

        let baselinePos = lastReportedPositionMs
        let work = DispatchWorkItem { [weak self] in
            guard let self = self,
                  !self.usingAVPlayer,
                  !self.isStoppingManually,
                  !self.isPausedByUser,
                  !self.usingSoftwareFallback,
                  let player = self.mediaPlayer,
                  let media = player.media else {
                return
            }

            let currentPos = self.currentPositionMs()
            let displayed = Int(media.numberOfDisplayedPictures)
            let stuckWithoutFrames = (displayed == 0) && (currentPos == baselinePos || !self.hasEmittedInitialPlaying)

            if stuckWithoutFrames {
                let resumeMs = max(expectedAfterSeekMs, max(0, currentPos))
                NSLog("[JellyfinDesktop] VLC pipeline stalled (0 frames after 4.5s); switching to software FFmpeg (--no-videotoolbox) at \(resumeMs)ms")
                var retryOptions = self.currentOptions
                retryOptions["startMilliseconds"] = resumeMs
                retryOptions["autoplay"] = true
                self.startVLCPlaybackSession(
                    url: self.currentStreamUrl,
                    options: retryOptions,
                    metadata: self.currentMetadata,
                    audioStream: self.pendingAudioStream,
                    subtitleStream: self.pendingSubtitleStream,
                    forceSoftwareDecoding: true
                )
            }
        }
        vlcStallWatchdogWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5, execute: work)
    }

    // MARK: - Unified Controls

    func play() {
        isPausedByUser = false
        if !isAudioOnlyMedia {
            UIApplication.shared.isIdleTimerDisabled = true
            videoContainerView.isHidden = false
        }
        if usingAVPlayer {
            let rate = max(0.25, min(4.0, Float(currentRatePermille) / 1000.0))
            avPlayer?.playImmediately(atRate: rate)
            onEmitSignal?("playing", [])
        } else {
            mediaPlayer?.play()
        }
    }

    func pause() {
        isPausedByUser = true
        if usingAVPlayer {
            avPlayer?.pause()
            onEmitSignal?("paused", [])
        } else {
            mediaPlayer?.pause()
        }
    }

    func stop() {
        tearDownAllPlayers(silent: false)
    }

    private func tearDownAllPlayers(silent: Bool) {
        isStoppingManually = true
        UIApplication.shared.isIdleTimerDisabled = false

        vlcSeekDebounceWorkItem?.cancel()
        vlcSeekDebounceWorkItem = nil
        vlcStallWatchdogWorkItem?.cancel()
        vlcStallWatchdogWorkItem = nil

        // Tear down AVPlayer if active
        avStatusObservation?.invalidate()
        avStatusObservation = nil
        if let endObs = avEndObserver {
            NotificationCenter.default.removeObserver(endObs)
            avEndObserver = nil
        }
        if let timeObs = avTimeObserver, let player = avPlayer {
            player.removeTimeObserver(timeObs)
        }
        avTimeObserver = nil
        avPlayer?.pause()
        avPlayer?.replaceCurrentItem(with: nil)
        avPlayer = nil
        avPlayerView?.playerLayer.player = nil
        avPlayerView?.removeFromSuperview()
        avPlayerView = nil

        // Tear down VLCMediaPlayer if active
        let oldVLC = self.mediaPlayer
        let oldDrawable = self.videoDrawableView
        self.mediaPlayer = nil
        self.videoDrawableView = nil

        oldVLC?.delegate = nil
        oldVLC?.drawable = nil
        oldDrawable?.removeFromSuperview()

        if let playerToStop = oldVLC {
            DispatchQueue.global(qos: .userInitiated).async {
                playerToStop.stop()
                playerToStop.media = nil
            }
        }

        videoContainerView.isHidden = true

        if !silent {
            onEmitSignal?("canceled", [])
            onEmitSignal?("stopped", [])
        }
    }

    func seekTo(ms: Int64) {
        let clamped = max(Int64(0), ms)
        lastReportedPositionMs = clamped
        onEmitSignal?("positionUpdate", [clamped])

        if usingAVPlayer {
            guard let player = avPlayer, let item = player.currentItem else { return }
            item.cancelPendingSeeks()
            let target = CMTime(value: clamped, timescale: 1000)
            let tol = CMTime(seconds: 0.5, preferredTimescale: 600)
            player.seek(to: target, toleranceBefore: tol, toleranceAfter: tol) { [weak self] finished in
                guard let self = self, finished, !self.isStoppingManually else { return }
                if !self.isPausedByUser {
                    let rate = max(0.25, min(4.0, Float(self.currentRatePermille) / 1000.0))
                    player.playImmediately(atRate: rate)
                }
            }
            return
        }

        // Debounce rapid slider seeks on VLCMediaPlayer so HTTP Range sockets never deadlock
        vlcSeekDebounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self,
                  !self.usingAVPlayer,
                  !self.isStoppingManually,
                  let player = self.mediaPlayer else {
                return
            }
            self.playbackPlayingStartPosMs = -1
            player.time = VLCTime(int: Int32(clamping: clamped))
            if !self.isPausedByUser && !player.isPlaying {
                player.play()
            }
            self.scheduleVLCStallWatchdog(expectedAfterSeekMs: clamped)
        }
        vlcSeekDebounceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    func currentPositionMs() -> Int64 {
        if usingAVPlayer {
            guard let player = avPlayer else { return 0 }
            let secs = CMTimeGetSeconds(player.currentTime())
            return (secs.isFinite && secs > 0) ? Int64(secs * 1000.0) : max(0, lastReportedPositionMs)
        }
        guard let player = mediaPlayer else { return 0 }
        return max(0, Int64(player.time.intValue))
    }

    func currentDurationMs() -> Int64 {
        if usingAVPlayer {
            if let dur = avPlayer?.currentItem?.duration {
                let secs = CMTimeGetSeconds(dur)
                if secs.isFinite && secs > 0 {
                    return Int64(secs * 1000.0)
                }
            }
            return lastKnownDurationMs
        }
        let raw = Int64(mediaPlayer?.media?.length.intValue ?? 0)
        return raw > 0 ? raw : lastKnownDurationMs
    }

    func setVolume(_ volume: Int) {
        currentVolume = min(100, max(0, volume))
        if usingAVPlayer {
            avPlayer?.volume = currentMuted ? 0.0 : (Float(currentVolume) / 100.0)
        } else if !currentMuted {
            mediaPlayer?.audio?.volume = Int32(currentVolume)
        }
    }

    func setMuted(_ muted: Bool) {
        currentMuted = muted
        if usingAVPlayer {
            avPlayer?.isMuted = muted
            avPlayer?.volume = muted ? 0.0 : (Float(currentVolume) / 100.0)
        } else {
            mediaPlayer?.audio?.isMuted = muted
            mediaPlayer?.audio?.volume = muted ? 0 : Int32(currentVolume)
        }
    }

    func setPlaybackRate(permille: Int) {
        currentRatePermille = permille
        let rate = max(0.25, min(4.0, Float(permille) / 1000.0))
        if usingAVPlayer {
            if !isPausedByUser {
                avPlayer?.rate = rate
            }
        } else {
            mediaPlayer?.rate = rate
        }
        onEmitSignal?("playbackRateChanged", [Double(rate)])
    }

    func setAudioStream(_ streamParam: Any?) {
        pendingAudioStream = streamParam
        if !usingAVPlayer {
            applyAudioStreamIfReady(streamParam)
        }
    }

    func setSubtitleStream(_ streamParam: Any?) {
        pendingSubtitleStream = streamParam
        if !usingAVPlayer {
            applySubtitleStreamIfReady(streamParam)
        }
    }

    func setSubtitleDelay(ms: Int64) {
        currentSubtitleDelayMs = ms
        if !usingAVPlayer {
            mediaPlayer?.currentVideoSubTitleDelay = Int(ms) * 1000
        }
    }

    func setAudioDelay(ms: Int64) {
        currentAudioDelayMs = ms
        if !usingAVPlayer {
            mediaPlayer?.currentAudioPlaybackDelay = Int(ms) * 1000
        }
    }

    func setVideoRectangle(x: Int, y: Int, w: Int, h: Int) {
        if x < 0 {
            videoContainerView.isHidden = true
        } else if !isAudioOnlyMedia && (avPlayer != nil || mediaPlayer != nil) {
            videoContainerView.isHidden = false
            layoutVideoDrawable()
        }
    }

    // MARK: - Track Mapping (Embedded tracks in VLCMediaPlayer)

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
        let bounds = videoContainerView.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }

        let aspectSetting = SettingsStore.shared.stringValue(section: "video", key: "aspect", fallback: "normal")

        if usingAVPlayer, let playerView = avPlayerView {
            switch aspectSetting {
            case "zoom":
                playerView.frame = bounds
                playerView.playerLayer.videoGravity = .resizeAspectFill
            case "stretch":
                playerView.frame = bounds
                playerView.playerLayer.videoGravity = .resize
            case "force_16_9":
                let targetH = bounds.width * (9.0 / 16.0)
                playerView.frame = CGRect(x: 0, y: (bounds.height - targetH) * 0.5, width: bounds.width, height: targetH)
                playerView.playerLayer.videoGravity = .resize
            case "force_4_3":
                let targetW = min(bounds.width, bounds.height * (4.0 / 3.0))
                let targetH = targetW * (3.0 / 4.0)
                playerView.frame = CGRect(x: (bounds.width - targetW) * 0.5, y: (bounds.height - targetH) * 0.5, width: targetW, height: targetH)
                playerView.playerLayer.videoGravity = .resize
            default:
                playerView.frame = bounds
                playerView.playerLayer.videoGravity = .resizeAspect
            }
            return
        }

        guard let drawable = videoDrawableView else { return }
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
            drawable.frame = CGRect(x: (bounds.width - drawW) * 0.5, y: (bounds.height - drawH) * 0.5, width: drawW, height: drawH)

        case "stretch":
            var drawW = bounds.width
            var drawH = bounds.height
            if sourceAspect > containerAspect {
                drawH = bounds.height * (sourceAspect / containerAspect)
            } else {
                drawW = bounds.width * (containerAspect / sourceAspect)
            }
            drawable.frame = CGRect(x: (bounds.width - drawW) * 0.5, y: (bounds.height - drawH) * 0.5, width: drawW, height: drawH)

        case "force_16_9":
            let targetH = bounds.width * (9.0 / 16.0)
            drawable.frame = CGRect(x: 0, y: (bounds.height - targetH) * 0.5, width: bounds.width, height: targetH)

        case "force_4_3":
            let targetW = min(bounds.width, bounds.height * (4.0 / 3.0))
            let targetH = targetW * (3.0 / 4.0)
            drawable.frame = CGRect(x: (bounds.width - targetW) * 0.5, y: (bounds.height - targetH) * 0.5, width: targetW, height: targetH)

        default:
            drawable.frame = bounds
        }
    }

    // MARK: - Self-Healing VideoToolbox -> Software FFmpeg Fallback (VLC)

    private func checkVideoOutputHealth(atPositionMs posMs: Int64) {
        guard !usingAVPlayer,
              !isAudioOnlyMedia,
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
        if Int(media.numberOfDisplayedPictures) == 0 {
            NSLog("[JellyfinDesktop] VideoToolbox displayed 0 frames after \(elapsedPlayingMs)ms; switching to software FFmpeg (--no-videotoolbox) at \(posMs)ms")
            var retryOptions = currentOptions
            retryOptions["startMilliseconds"] = posMs
            retryOptions["autoplay"] = true
            startVLCPlaybackSession(
                url: currentStreamUrl,
                options: retryOptions,
                metadata: currentMetadata,
                audioStream: pendingAudioStream,
                subtitleStream: pendingSubtitleStream,
                forceSoftwareDecoding: true
            )
        }
    }

    // MARK: - VLCMediaPlayerDelegate

    func mediaPlayerStateChanged(_ aNotification: Notification) {
        guard !usingAVPlayer,
              let player = aNotification.object as? VLCMediaPlayer,
              player === self.mediaPlayer else {
            return
        }

        let state = player.state

        switch state {
        case .playing:
            vlcStallWatchdogWorkItem?.cancel()
            if !hasEmittedInitialPlaying {
                hasEmittedInitialPlaying = true

                ensurePrimaryVideoTrackSelected()
                if let audio = pendingAudioStream {
                    applyAudioStreamIfReady(audio)
                }
                if let sub = pendingSubtitleStream {
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
                startVLCPlaybackSession(
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
        guard !usingAVPlayer,
              let player = aNotification.object as? VLCMediaPlayer,
              player === self.mediaPlayer else {
            return
        }

        vlcStallWatchdogWorkItem?.cancel()

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
