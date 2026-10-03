import AVFoundation

@MainActor
protocol MicrophoneCapture: AnyObject {
    var elapsed: TimeInterval { get }
    var level: Float { get }
    func start() -> Bool
    func stop()
}

/// macOS 原生单次录音；回调只通知拥有它的那一轮测试。
@MainActor
final class SystemMicrophoneCapture: NSObject, MicrophoneCapture, AVAudioRecorderDelegate {
    private let recorder: AVAudioRecorder
    private let completion: @MainActor (Bool) -> Void
    private let maximumDuration: TimeInterval

    init(url: URL, maximumDuration: TimeInterval = 5, sampleRate: Double = 44_100,
         completion: @escaping @MainActor (Bool) -> Void) throws {
        recorder = try AVAudioRecorder(url: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ])
        self.completion = completion
        self.maximumDuration = maximumDuration
        super.init()
        recorder.delegate = self
        recorder.isMeteringEnabled = true
    }

    var elapsed: TimeInterval { recorder.currentTime }
    var level: Float {
        recorder.updateMeters()
        return min(1, max(0, pow(10, recorder.averagePower(forChannel: 0) / 20)))
    }

    func start() -> Bool { recorder.prepareToRecord() && recorder.record(forDuration: maximumDuration) }

    func stop() {
        recorder.delegate = nil
        recorder.stop()
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.completion(flag) }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor [weak self] in self?.completion(false) }
    }
}
