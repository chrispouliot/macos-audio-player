import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var playbackModel: PlaybackModel
    @State private var sliderValue = 0.0
    @State private var isEditingSlider = false

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header

                if playbackModel.selectedURL == nil {
                    emptyState
                } else {
                    playerLayout
                }

                feedback
                volumeBar
            }
            .padding(.horizontal, 34)
            .padding(.top, 22)
            .padding(.bottom, 20)
        }
        .frame(minWidth: 860, minHeight: 620)
        .onChange(of: playbackModel.currentTime) { _, newValue in
            if !isEditingSlider {
                sliderValue = newValue
            }
        }
        .onChange(of: playbackModel.duration) { _, newValue in
            if !isEditingSlider {
                sliderValue = min(playbackModel.currentTime, newValue)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.circle.fill")
                .font(.title2)
                .foregroundStyle(Color.accentColor)

            Text("ResumePlayer")
                .font(.headline)

            Spacer()

            if playbackModel.selectedURL != nil {
                Button {
                    playbackModel.presentOpenPanel()
                } label: {
                    Label("Open Audio", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)

                Button {
                    Task { await playbackModel.close() }
                } label: {
                    Label("Close", systemImage: "xmark")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .help("Close the current audio file")
            }

            Menu {
                Button("Set as Default Audio Player…") {
                    playbackModel.requestDefaultAudioPlayer()
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .help("More audio player actions")
        }
        .frame(height: 38)
    }

    private var playerLayout: some View {
        HStack(alignment: .top, spacing: 42) {
            ArtworkView(image: playbackModel.artwork)
                .frame(width: 340, height: 340)

            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 18)

                Text(playbackModel.trackTitle ?? "Untitled Audio")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .lineLimit(2)
                    .minimumScaleFactor(0.72)

                Text(playbackModel.trackArtist ?? "Unknown Artist")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.top, 7)

                if let album = playbackModel.trackAlbum {
                    Text(album)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(.quaternary, in: Capsule())
                        .padding(.top, 13)
                }

                Spacer(minLength: 26)

                progressControl

                transportControls
                    .padding(.top, 27)

                Spacer(minLength: 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.top, 38)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var progressControl: some View {
        VStack(spacing: 7) {
            Slider(
                value: $sliderValue,
                in: 0...max(playbackModel.duration, 0.01),
                onEditingChanged: { editing in
                    isEditingSlider = editing
                    if !editing {
                        playbackModel.seek(to: sliderValue)
                    }
                }
            )
            .tint(Color.accentColor)

            HStack {
                Text(formatTime(isEditingSlider ? sliderValue : playbackModel.currentTime))
                Spacer()
                Text(remainingTime)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var transportControls: some View {
        HStack(spacing: 30) {
            Spacer()

            Button {
                playbackModel.skipBackward()
            } label: {
                Image(systemName: "gobackward.15")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Skip back 15 seconds")
            .help("Skip back 15 seconds")

            Button {
                playbackModel.togglePlayback()
            } label: {
                Image(systemName: playbackModel.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 27, weight: .bold))
                    .frame(width: 76, height: 76)
                    .background(Color.accentColor, in: Circle())
                    .foregroundStyle(.white)
                    .shadow(color: Color.black.opacity(0.16), radius: 8, y: 4)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])
            .accessibilityLabel(playbackModel.isPlaying ? "Pause" : "Play")

            Button {
                playbackModel.skipForward()
            } label: {
                Image(systemName: "goforward.15")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Skip forward 15 seconds")
            .help("Skip forward 15 seconds")

            Spacer()
        }
        .foregroundStyle(.primary)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Audio Selected", systemImage: "waveform")
        } description: {
            Text("Open a local audio file to begin playback.")
        } actions: {
            Button("Open Audio…") {
                playbackModel.presentOpenPanel()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var feedback: some View {
        VStack(alignment: .leading, spacing: 7) {
            if playbackModel.isLoading {
                Label("Loading audio…", systemImage: "hourglass")
                    .foregroundStyle(.secondary)
            }

            if let errorMessage = playbackModel.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let defaultPlayerStatusMessage = playbackModel.defaultPlayerStatusMessage {
                Label(defaultPlayerStatusMessage, systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 5)
    }

    private var volumeBar: some View {
        HStack(spacing: 10) {
            Button {
                playbackModel.toggleMute()
            } label: {
                Image(systemName: volumeSymbol)
                    .frame(width: 22)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playbackModel.isMuted ? "Unmute" : "Mute")
            .help(playbackModel.isMuted ? "Unmute" : "Mute")

            Slider(
                value: Binding(
                    get: { playbackModel.volume },
                    set: { playbackModel.setVolume($0) }
                ),
                in: 0...1
            )
            .frame(maxWidth: 190)
            .tint(Color.accentColor)

            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.top, 16)
    }

    private var volumeSymbol: String {
        if playbackModel.isMuted || playbackModel.volume == 0 {
            return "speaker.slash.fill"
        }
        if playbackModel.volume < 0.45 {
            return "speaker.wave.1.fill"
        }
        return "speaker.wave.2.fill"
    }

    private var remainingTime: String {
        guard playbackModel.duration > 0 else { return "--:--" }
        return "−" + formatTime(max(0, playbackModel.duration - (isEditingSlider ? sliderValue : playbackModel.currentTime)))
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let totalSeconds = Int(seconds.rounded(.down))
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

private struct ArtworkView: View {
    let image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    LinearGradient(
                        colors: [Color.accentColor.opacity(0.82), Color.accentColor.opacity(0.3)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )

                    Image(systemName: "waveform")
                        .font(.system(size: 76, weight: .light))
                        .foregroundStyle(.white.opacity(0.88))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: Color.black.opacity(0.18), radius: 16, y: 8)
    }
}
