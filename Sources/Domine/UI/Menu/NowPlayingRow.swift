import SwiftUI

/// Title, artist, and transport buttons. Shown only when something has a title.
struct NowPlayingRow: View {
    var model: NowPlayingModel

    var body: some View {
        if let info = model.info {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(info.title).lineLimit(1)
                    if !info.artist.isEmpty {
                        Text(info.artist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Button { model.togglePlayPause() } label: {
                    Image(systemName: info.isPlaying ? "pause.fill" : "play.fill").frame(width: 18)
                }
                .help(info.isPlaying ? "Pause" : "Play")
                .accessibilityLabel(info.isPlaying ? "Pause" : "Play")
                Button { model.nextTrack() } label: {
                    Image(systemName: "forward.fill").frame(width: 18)
                }
                .help("Next")
                .accessibilityLabel("Next")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }
}
