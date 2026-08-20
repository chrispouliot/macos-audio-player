import AVFoundation
import AppKit
import Combine
import CoreMedia
import Foundation
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

    private static let supportedAudioContentTypes: [UTType] = [
        .mp3,
        .mpeg4Audio,
        UTType("com.apple.m4a-audio")!,
        .wav,
        .aiff
    ]

    init(resumeStore: ResumeStore = .production) {
        self.resumeStore = resumeStore
    }

    isolated deinit {
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
        playerItem = item
        player = newPlayer
        selectedURL = url
        currentTime = 0
        duration = 0
        isPlaying = false
        isLoading = true
        pendingResumePosition = nil
        resumePositionLoaded = false
        hasStartedPlayback = false
        lastPersistedTime = 0
        observe(item: item, player: newPlayer, loadID: newLoadID)

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
    }

    func togglePlayback() {
        guard let player, let item = playerItem else { return }

        if isPlaying {
            player.pause()
            isPlaying = false
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
            isPlaying = true
        }
    }

    func seek(to seconds: TimeInterval) {
        guard playerItem != nil else { return }
        let boundedTime = max(0, min(seconds, duration > 0 ? duration : seconds))
        let wasPlaying = isPlaying
        seekPlayer(to: boundedTime, resumeAfterSeek: wasPlaying)
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
                self.isPlaying = isPlaying
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
            isPlaying = false
            errorMessage = "Unable to play audio: \(item.error?.localizedDescription ?? "Unknown playback error")"
        case .unknown:
            isLoading = true
        @unknown default:
            isLoading = false
            errorMessage = "Unable to determine the audio file state."
        }
    }

    private func updateDuration(from item: AVPlayerItem) {
        let seconds = item.duration.seconds
        guard seconds.isFinite, seconds > 0 else { return }
        duration = seconds
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
            isPlaying = true
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
                    self.isPlaying = true
                } else if !resumeAfterSeek {
                    self.isPlaying = false
                }
            }
        }
    }

    private func updateCurrentTime(_ time: CMTime) {
        let seconds = time.seconds
        guard seconds.isFinite else { return }
        currentTime = max(0, seconds)

        if duration > 0, currentTime - lastPersistedTime >= 10 {
            lastPersistedTime = currentTime
            saveCurrentProgressInBackground()
        }
    }

    private func handlePlaybackEnded() {
        currentTime = duration > 0 ? duration : currentTime
        isPlaying = false
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

    private func stopPlaybackAndReleaseResource() {
        loadID = UUID()
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
