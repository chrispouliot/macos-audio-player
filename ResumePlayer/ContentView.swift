import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var playbackModel: PlaybackModel
    @State private var sliderValue = 0.0
    @State private var isEditingSlider = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label(playbackModel.selectedURL?.lastPathComponent ?? "No audio selected", systemImage: "waveform")
                    .font(.title3)
                    .lineLimit(1)

                Spacer()

                Button("Open…") {
                    playbackModel.presentOpenPanel()
                }

                if playbackModel.selectedURL != nil {
                    Button("Close") {
                        Task { await playbackModel.close() }
                    }
                }
            }

            if playbackModel.selectedURL != nil {
                VStack(spacing: 6) {
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

                    HStack {
                        Text(formatTime(isEditingSlider ? sliderValue : playbackModel.currentTime))
                        Spacer()
                        Text(formatTime(playbackModel.duration))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }

                HStack {
                    Spacer()
                    Button {
                        playbackModel.togglePlayback()
                    } label: {
                        Label(
                            playbackModel.isPlaying ? "Pause" : "Play",
                            systemImage: playbackModel.isPlaying ? "pause.fill" : "play.fill"
                        )
                    }
                    .keyboardShortcut(.space, modifiers: [])
                    Spacer()
                }
            } else {
                ContentUnavailableView(
                    "No Audio Selected",
                    systemImage: "waveform",
                    description: Text("Open a local audio file to begin playback.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if playbackModel.isLoading {
                ProgressView("Loading audio…")
            }

            if let errorMessage = playbackModel.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let defaultPlayerStatusMessage = playbackModel.defaultPlayerStatusMessage {
                Label(defaultPlayerStatusMessage, systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(minWidth: 480, minHeight: 320)
        .padding()
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

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let totalSeconds = Int(seconds.rounded(.down))
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}
