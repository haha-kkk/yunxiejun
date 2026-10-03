import AVFoundation

@MainActor
protocol MicrophonePlayback: AnyObject {
    func start() -> Bool
    func stop()
}

@MainActor
final class SystemMicrophonePlayback: NSObject, MicrophonePlayback, AVAudioPlayerDelegate {
    private let player: AVAudioPlayer
    private let completion: @MainActor (Bool) -> Void

    init(url: URL, completion: @escaping @MainActor (Bool) -> Void) throws {
        player = try AVAudioPlayer(contentsOf: url)
        self.completion = completion
        super.init()
        player.delegate = self
    }

    func start() -> Bool { player.prepareToPlay() && player.play() }
    func stop() { player.delegate = nil; player.stop() }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.completion(flag) }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        audioPlayerDidFinishPlaying(player, successfully: false)
    }
}
