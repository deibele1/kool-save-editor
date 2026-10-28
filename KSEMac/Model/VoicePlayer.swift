import AVFoundation
import KotORSave

/// Plays random lines of voice sets, one at a time.
@Observable
final class VoicePlayer {
    /// The voice set last played and its line (nil when none of its sounds could be found).
    private(set) var played: (soundset: Int, sample: VoiceSample?)?

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var request: Task<Void, Never>?

    func play(_ soundset: Int, from gameData: GameData) {
        stop()
        let previous = played?.soundset == soundset ? played?.sample : nil
        request = Task {
            let sample = await Task.detached(priority: .userInitiated) {
                gameData.randomVoiceSample(soundset: soundset, after: previous)
            }.value
            guard !Task.isCancelled else { return }
            played = (soundset, sample)
            guard let sample else { return }
            player = try? AVAudioPlayer(data: Data(sample.audio),
                                        fileTypeHint: sample.format == .mp3 ? AVFileType.mp3.rawValue : AVFileType.wav.rawValue)
            player?.play()
        }
    }

    func stop() {
        request?.cancel()
        player?.stop()
    }

    /// What the last line of `soundset` said, for a caption.
    func caption(for soundset: Int?) -> String? {
        guard let played, played.soundset == soundset else { return nil }
        guard let sample = played.sample else { return "None of its sound files were found." }
        return sample.text.map { "\(sample.slotName): “\($0)”" } ?? sample.slotName
    }
}
