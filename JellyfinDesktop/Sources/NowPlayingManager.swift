import Foundation
import MediaPlayer

final class NowPlayingManager {

    var onInputAction: (([String]) -> Void)?
    var onSeekPositionMs: ((Int64) -> Void)?

    private var info: [String: Any] = [:]
    private var commandsRegistered = false

    init() {
        setupRemoteCommands()
    }

    private func setupRemoteCommands() {
        guard !commandsRegistered else { return }
        commandsRegistered = true

        let center = MPRemoteCommandCenter.shared()

        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            self?.onInputAction?(["play"])
            return .success
        }

        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            self?.onInputAction?(["pause"])
            return .success
        }

        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.onInputAction?(["play_pause"])
            return .success
        }

        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.onInputAction?(["nexttrack"])
            return .success
        }

        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.onInputAction?(["previous"])
            return .success
        }

        center.skipForwardCommand.isEnabled = true
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipForwardCommand.addTarget { [weak self] _ in
            self?.onInputAction?(["seek_forward"])
            return .success
        }

        center.skipBackwardCommand.isEnabled = true
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            self?.onInputAction?(["seek_backward"])
            return .success
        }

        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let posEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let posMs = Int64(posEvent.positionTime * 1000.0)
            self?.onSeekPositionMs?(posMs)
            return .success
        }
    }

    func updateMetadata(_ metadata: [String: Any]) {
        if let name = metadata["Name"] as? String {
            info[MPMediaItemPropertyTitle] = name
        }
        if let seriesName = metadata["SeriesName"] as? String {
            info[MPMediaItemPropertyArtist] = seriesName
        } else if let artists = metadata["Artists"] as? [String], !artists.isEmpty {
            info[MPMediaItemPropertyArtist] = artists.joined(separator: ", ")
        }
        if let album = metadata["Album"] as? String {
            info[MPMediaItemPropertyAlbumTitle] = album
        }
        if let runTimeTicks = (metadata["RunTimeTicks"] as? NSNumber)?.doubleValue, runTimeTicks > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = runTimeTicks / 10_000_000.0
        }
        flush()
    }

    func updateDuration(ms: Int64) {
        if ms > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = Double(ms) / 1000.0
            flush()
        }
    }

    func updatePosition(ms: Int64) {
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(0.0, Double(ms) / 1000.0)
        flush()
    }

    func updateRate(_ rate: Double) {
        info[MPNowPlayingInfoPropertyPlaybackRate] = rate
        flush()
    }

    func updatePlaybackState(_ state: String) {
        let isPlaying = state.lowercased() == "playing"
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        flush()
    }

    func updateQueue(canNext: Bool, canPrevious: Bool) {
        let center = MPRemoteCommandCenter.shared()
        center.nextTrackCommand.isEnabled = canNext
        center.previousTrackCommand.isEnabled = canPrevious
    }

    func clear() {
        info.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func flush() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
