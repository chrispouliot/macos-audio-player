import AVFoundation
import AppKit
import Combine
import CoreMedia
import Foundation
import MediaPlayer
import UniformTypeIdentifiers

@MainActor
final class PlaybackModel: ObservableObject {
    @Published private(set) var selectedURL: URL?
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var defaultPlayerStatusMessage: String?
    @Published private(set) var trackTitle: String?
    @Published private(set) var trackArtist: String?
    @Published private(set) var trackAlbum: String?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var volume: Double = 0.72
    @Published private(set) var isMuted = false

    private let resumeStore: ResumeStore
    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var durationObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var securityScopedURL: URL?
    private var hasSecurityScope = false
    private var pendingResumePosition: TimeInterval?
    private var resumePositionLoaded = false
    private var hasStartedPlayback = false
    private var lastPersistedTime: TimeInterval = 0
    private var loadID = UUID()
    private var defaultPlayerRequestInFlight = false
    private var nowPlayingInfo: [String: Any]?
    private var lastPublishedElapsedTime: TimeInterval?
    private var remoteCommandHandlers: [(command: MPRemoteCommand, token: Any)] = []

    private static let supportedAudioContentTypes: [UTType] = [
        .mp3,
        .mpeg4Audio,
        UTType("com.apple.m4a-audio")!,
        .wav,
        .aiff
    ]

    init(resumeStore: ResumeStore = .production) {
        self.resumeStore = resumeStore
        registerRemoteCommands()
    }

    isolated deinit {
        unregisterRemoteCommands()
        clearNowPlaying()
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        if hasSecurityScope {
            securityScopedURL?.stopAccessingSecurityScopedResource()
        }
    }

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio]

        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor [weak self] in
            await self?.open(url: url)
        }
    }

    func requestDefaultAudioPlayer() {
        guard !defaultPlayerRequestInFlight else { return }

        defaultPlayerRequestInFlight = true
        defaultPlayerStatusMessage = "Requesting default audio player…"
        let contentTypes = Self.supportedAudioContentTypes
        let appURL = Bundle.main.bundleURL

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { defaultPlayerRequestInFlight = false }

            for contentType in contentTypes {
                do {
                    try await setDefaultApplication(at: appURL, for: contentType)
                } catch {
                    continue
                }
            }

            let appBundleIdentifier = Bundle.main.bundleIdentifier
            let successfulTypes = contentTypes.reduce(into: 0) { count, contentType in
                guard let effectiveApplicationURL = NSWorkspace.shared.urlForApplication(toOpen: contentType),
                      let effectiveBundleIdentifier = Bundle(url: effectiveApplicationURL)?.bundleIdentifier,
                      effectiveBundleIdentifier == appBundleIdentifier else { return }
                count += 1
            }

            switch successfulTypes {
            case contentTypes.count:
                defaultPlayerStatusMessage = "ResumePlayer is now the default audio player."
            case 0:
                defaultPlayerStatusMessage = "ResumePlayer could not become the default audio player."
            default:
                defaultPlayerStatusMessage =
                    "ResumePlayer is the default for \(successfulTypes) of \(contentTypes.count) audio types."
            }
        }
    }

    private func setDefaultApplication(at appURL: URL, for contentType: UTType) async throws {
        try await NSWorkspace.shared.setDefaultApplication(
            at: appURL,
            toOpen: contentType
        )
    }

    func open(url: URL) async {
        guard url.isFileURL else {
            errorMessage = "Only local audio files can be opened."
            return
        }

        errorMessage = nil
        await saveCurrentProgress()
        stopPlaybackAndReleaseResource()

        let newLoadID = UUID()
        loadID = newLoadID
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        securityScopedURL = url
        hasSecurityScope = didStartAccessing

        let item = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.volume = Float(volume)
        newPlayer.isMuted = isMuted
        playerItem = item
        player = newPlayer
        selectedURL = url
        trackTitle = Self.fallbackTitle(for: url)
        trackArtist = nil
        trackAlbum = nil
        artwork = nil
        currentTime = 0
        duration = 0
        setPlaybackState(false)
        isLoading = true
        pendingResumePosition = nil
        resumePositionLoaded = false
        hasStartedPlayback = false
        lastPersistedTime = 0
        updateRemoteCommandAvailability()
        refreshNowPlayingInfo(forceElapsedUpdate: true)
        observe(item: item, player: newPlayer, loadID: newLoadID)
        loadMetadata(for: url, loadID: newLoadID)

        do {
            pendingResumePosition = try await resumeStore.position(for: url)
        } catch {
            errorMessage = "Unable to load saved progress: \(error.localizedDescription)"
        }

        guard loadID == newLoadID else { return }
        resumePositionLoaded = true
        startPlaybackWhenReady()
    }

    func close() async {
        await saveCurrentProgress()
        stopPlaybackAndReleaseResource()
        selectedURL = nil
        currentTime = 0
        duration = 0
        isPlaying = false
        isLoading = false
        pendingResumePosition = nil
        resumePositionLoaded = false
        hasStartedPlayback = false
        trackTitle = nil
        trackArtist = nil
        trackAlbum = nil
        artwork = nil
    }

    func togglePlayback() {
        guard let player, let item = playerItem else { return }

        if isPlaying {
            player.pause()
            setPlaybackState(false)
            saveCurrentProgressInBackground()
            return
        }

        guard item.status == .readyToPlay else {
            isLoading = true
            return
        }

        if duration > 0, currentTime >= duration - 0.05 {
            seekPlayer(to: 0, resumeAfterSeek: true)
        } else {
            player.play()
            setPlaybackState(true)
        }
    }

    func seek(to seconds: TimeInterval) {
        guard playerItem != nil else { return }
        let boundedTime = max(0, min(seconds, duration > 0 ? duration : seconds))
        let wasPlaying = isPlaying
        seekPlayer(to: boundedTime, resumeAfterSeek: wasPlaying)
    }

    func skipBackward() {
        skip(by: -15)
    }

    func skipForward() {
        skip(by: 15)
    }

    func setVolume(_ value: Double) {
        volume = max(0, min(value, 1))
        player?.volume = Float(volume)
    }

    func toggleMute() {
        isMuted.toggle()
        player?.isMuted = isMuted
    }

    func saveForInactivity() {
        saveCurrentProgressInBackground()
    }

    func saveForTermination() async {
        await saveCurrentProgress()
    }

    private func observe(item: AVPlayerItem, player: AVPlayer, loadID: UUID) {
        statusObservation = item.observe(\AVPlayerItem.status, options: [.initial, .new]) {
            [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self, self.loadID == loadID, self.playerItem === item else { return }
                self.handleStatus(item)
            }
        }

        durationObservation = item.observe(\AVPlayerItem.duration, options: [.new]) {
            [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self, self.loadID == loadID, self.playerItem === item else { return }
                self.updateDuration(from: item)
            }
        }

        timeControlObservation = player.observe(\AVPlayer.timeControlStatus, options: [.new]) {
            [weak self] player, _ in
            let isPlaying = player.timeControlStatus == .playing
            Task { @MainActor [weak self] in
                guard let self, self.loadID == loadID, self.player === player else { return }
                self.setPlaybackState(isPlaying)
            }
        }

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, self.loadID == loadID else { return }
                self.updateCurrentTime(time)
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.loadID == loadID, self.playerItem === item else { return }
                self.handlePlaybackEnded()
            }
        }
    }

    private func handleStatus(_ item: AVPlayerItem) {
        switch item.status {
        case .readyToPlay:
            updateDuration(from: item)
            startPlaybackWhenReady()
        case .failed:
            isLoading = false
            setPlaybackState(false)
            errorMessage = "Unable to play audio: \(item.error?.localizedDescription ?? "Unknown playback error")"
        case .unknown:
            isLoading = true
        @unknown default:
            isLoading = false
            setPlaybackState(false)
            errorMessage = "Unable to determine the audio file state."
        }
    }

    private func updateDuration(from item: AVPlayerItem) {
        let seconds = item.duration.seconds
        guard seconds.isFinite, seconds > 0 else { return }
        duration = seconds
        updateRemoteCommandAvailability()
        refreshNowPlayingInfo(forceElapsedUpdate: true)
    }

    private func skip(by offset: TimeInterval) {
        guard playerItem != nil, duration > 0 else { return }
        seek(to: currentTime + offset)
    }

    private func loadMetadata(for url: URL, loadID: UUID) {
        let asset = AVURLAsset(url: url)
        Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                let metadataItems = try await asset.load(.commonMetadata)
                var title: String?
                var artist: String?
                var author: String?
                var album: String?
                var artworkData: Data?

                for item in metadataItems {
                    switch item.identifier {
                    case .commonIdentifierTitle:
                        title = try? await item.load(.stringValue)
                    case .commonIdentifierArtist:
                        artist = try? await item.load(.stringValue)
                    case .commonIdentifierAuthor:
                        author = try? await item.load(.stringValue)
                    case .commonIdentifierAlbumName:
                        album = try? await item.load(.stringValue)
                    case .commonIdentifierArtwork:
                        artworkData = try? await item.load(.dataValue)
                    default:
                        continue
                    }
                }

                guard self.loadID == loadID, self.selectedURL == url else { return }
                self.trackTitle = Self.nonEmpty(title) ?? Self.fallbackTitle(for: url)
                self.trackArtist = Self.nonEmpty(artist) ?? Self.nonEmpty(author)
                self.trackAlbum = Self.nonEmpty(album)
                self.artwork = artworkData.flatMap(NSImage.init(data:))
                self.refreshNowPlayingInfo(forceElapsedUpdate: true)
            } catch {
                guard self.loadID == loadID, self.selectedURL == url else { return }
                self.trackTitle = Self.fallbackTitle(for: url)
                self.trackArtist = nil
                self.trackAlbum = nil
                self.artwork = nil
                self.refreshNowPlayingInfo(forceElapsedUpdate: true)
            }
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }

    private static func fallbackTitle(for url: URL) -> String {
        let filename = url.deletingPathExtension().lastPathComponent
        return filename.isEmpty ? "Untitled Audio" : filename
    }

    private func startPlaybackWhenReady() {
        guard !hasStartedPlayback,
              resumePositionLoaded,
              let item = playerItem,
              let player,
              item.status == .readyToPlay
        else { return }

        hasStartedPlayback = true
        isLoading = true
        let resumeTime = pendingResumePosition.flatMap { position in
            guard position > 0, position < duration else { return nil }
            return position
        } ?? 0
        currentTime = resumeTime

        if resumeTime > 0 {
            seekPlayer(to: resumeTime, resumeAfterSeek: true)
        } else {
            player.play()
            isLoading = false
            setPlaybackState(true)
        }
    }

    private func seekPlayer(to seconds: TimeInterval, resumeAfterSeek: Bool) {
        guard let player else { return }
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) {
            [weak self, weak player] finished in
            Task { @MainActor [weak self] in
                guard let self, let player, self.player === player else { return }
                self.currentTime = seconds
                self.isLoading = false
                if finished, resumeAfterSeek {
                    player.play()
                    self.setPlaybackState(true)
                } else if !resumeAfterSeek {
                    self.setPlaybackState(false)
                } else {
                    self.refreshNowPlayingInfo(forceElapsedUpdate: true)
                }
            }
        }
    }

    private func updateCurrentTime(_ time: CMTime) {
        let seconds = time.seconds
        guard seconds.isFinite else { return }
        currentTime = max(0, seconds)
        refreshNowPlayingInfo()

        if duration > 0, currentTime - lastPersistedTime >= 10 {
            lastPersistedTime = currentTime
            saveCurrentProgressInBackground()
        }
    }

    private func handlePlaybackEnded() {
        currentTime = duration > 0 ? duration : currentTime
        setPlaybackState(false)
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        isLoading = false
        saveCurrentProgressInBackground()
    }

    private func saveCurrentProgressInBackground() {
        guard let url = selectedURL, duration > 0 else { return }
        let position = currentTime
        let duration = self.duration
        let store = resumeStore
        Task { @MainActor [weak self] in
            do {
                try await store.save(position: position, duration: duration, for: url)
            } catch {
                guard let self, self.selectedURL == url else { return }
                self.errorMessage = "Unable to save progress: \(error.localizedDescription)"
            }
        }
    }

    private func saveCurrentProgress() async {
        guard let url = selectedURL, duration > 0 else { return }
        do {
            try await resumeStore.save(position: currentTime, duration: duration, for: url)
        } catch {
            errorMessage = "Unable to save progress: \(error.localizedDescription)"
        }
    }

    private func setPlaybackState(_ playing: Bool) {
        isPlaying = playing
        guard selectedURL != nil else { return }
        MPNowPlayingInfoCenter.default().playbackState = playing ? .playing : .paused
        refreshNowPlayingInfo(forceElapsedUpdate: true)
    }

    private func refreshNowPlayingInfo(forceElapsedUpdate: Bool = false) {
        guard selectedURL != nil else {
            clearNowPlaying()
            return
        }

        let elapsedTimeChanged = lastPublishedElapsedTime.map {
            abs($0 - currentTime) >= 1
        } ?? true
        guard forceElapsedUpdate || elapsedTimeChanged || nowPlayingInfo == nil else { return }

        var info = nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyTitle] = trackTitle ?? "Untitled Audio"
        info[MPNowPlayingInfoPropertyMediaType] = NSNumber(value: MPNowPlayingInfoMediaType.audio.rawValue)

        if let trackArtist {
            info[MPMediaItemPropertyArtist] = trackArtist
        } else {
            info.removeValue(forKey: MPMediaItemPropertyArtist)
        }

        if let trackAlbum {
            info[MPMediaItemPropertyAlbumTitle] = trackAlbum
        } else {
            info.removeValue(forKey: MPMediaItemPropertyAlbumTitle)
        }

        if let artwork, artwork.size.width > 0, artwork.size.height > 0 {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
        } else {
            info.removeValue(forKey: MPMediaItemPropertyArtwork)
        }

        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        } else {
            info.removeValue(forKey: MPMediaItemPropertyPlaybackDuration)
        }

        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        nowPlayingInfo = info
        lastPublishedElapsedTime = currentTime
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func clearNowPlaying() {
        nowPlayingInfo = nil
        lastPublishedElapsedTime = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    private func registerRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()
        addRemoteHandler(to: commandCenter.playCommand) { [weak self] _ in
            guard let self else { return .noSuchContent }
            guard self.selectedURL != nil, let item = self.playerItem else { return .noSuchContent }
            guard item.status == .readyToPlay else { return .commandFailed }
            if !self.isPlaying {
                self.togglePlayback()
            }
            return .success
        }
        addRemoteHandler(to: commandCenter.pauseCommand) { [weak self] _ in
            guard let self else { return .noSuchContent }
            guard self.selectedURL != nil, self.playerItem != nil else { return .noSuchContent }
            if self.isPlaying {
                self.togglePlayback()
            }
            return .success
        }
        addRemoteHandler(to: commandCenter.togglePlayPauseCommand) { [weak self] _ in
            guard let self else { return .noSuchContent }
            guard self.selectedURL != nil, let item = self.playerItem else { return .noSuchContent }
            guard item.status == .readyToPlay else { return .commandFailed }
            self.togglePlayback()
            return .success
        }
        addRemoteHandler(to: commandCenter.changePlaybackPositionCommand) { [weak self] event in
            guard let self, let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            guard self.selectedURL != nil, self.playerItem != nil, self.duration > 0 else {
                return .noSuchContent
            }
            guard event.positionTime.isFinite else { return .commandFailed }
            self.seek(to: event.positionTime)
            return .success
        }
        commandCenter.skipBackwardCommand.preferredIntervals = [NSNumber(value: 15)]
        addRemoteHandler(to: commandCenter.skipBackwardCommand) { [weak self] _ in
            guard let self, self.selectedURL != nil, self.playerItem != nil, self.duration > 0 else {
                return .noSuchContent
            }
            self.skipBackward()
            return .success
        }
        commandCenter.skipForwardCommand.preferredIntervals = [NSNumber(value: 15)]
        addRemoteHandler(to: commandCenter.skipForwardCommand) { [weak self] _ in
            guard let self, self.selectedURL != nil, self.playerItem != nil, self.duration > 0 else {
                return .noSuchContent
            }
            self.skipForward()
            return .success
        }

        commandCenter.nextTrackCommand.isEnabled = false
        commandCenter.previousTrackCommand.isEnabled = false
        updateRemoteCommandAvailability(hasFile: false)
    }

    private func addRemoteHandler(
        to command: MPRemoteCommand,
        handler: @escaping @MainActor (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus
    ) {
        let token = command.addTarget(handler: handler)
        remoteCommandHandlers.append((command: command, token: token))
    }

    private func updateRemoteCommandAvailability(hasFile: Bool? = nil) {
        let hasFile = hasFile ?? (selectedURL != nil)
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.isEnabled = hasFile
        commandCenter.pauseCommand.isEnabled = hasFile
        commandCenter.togglePlayPauseCommand.isEnabled = hasFile
        commandCenter.changePlaybackPositionCommand.isEnabled = hasFile && duration > 0
        commandCenter.skipBackwardCommand.isEnabled = hasFile && duration > 0
        commandCenter.skipForwardCommand.isEnabled = hasFile && duration > 0
        commandCenter.nextTrackCommand.isEnabled = false
        commandCenter.previousTrackCommand.isEnabled = false
    }

    private func unregisterRemoteCommands() {
        for handler in remoteCommandHandlers {
            handler.command.removeTarget(handler.token)
        }
        remoteCommandHandlers.removeAll()
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.isEnabled = false
        commandCenter.pauseCommand.isEnabled = false
        commandCenter.togglePlayPauseCommand.isEnabled = false
        commandCenter.changePlaybackPositionCommand.isEnabled = false
        commandCenter.skipBackwardCommand.isEnabled = false
        commandCenter.skipForwardCommand.isEnabled = false
        commandCenter.nextTrackCommand.isEnabled = false
        commandCenter.previousTrackCommand.isEnabled = false
    }

    private func stopPlaybackAndReleaseResource() {
        loadID = UUID()
        clearNowPlaying()
        updateRemoteCommandAvailability(hasFile: false)
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        statusObservation = nil
        durationObservation = nil
        timeControlObservation = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        playerItem = nil
        if hasSecurityScope {
            securityScopedURL?.stopAccessingSecurityScopedResource()
        }
        securityScopedURL = nil
        hasSecurityScope = false
    }
}
