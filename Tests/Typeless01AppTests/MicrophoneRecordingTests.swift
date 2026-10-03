import AppKit
import AVFoundation
import Darwin
import Testing
@testable import Typeless01App

@MainActor
private final class FakeCapture: MicrophoneCapture {
    var elapsed: TimeInterval = 0
    var level: Float = 0
    var startResult = true
    var starts = 0
    var stops = 0
    var completion: (@MainActor (Bool) -> Void)?
    func start() -> Bool { starts += 1; return startResult }
    func stop() { stops += 1 }
}

@Suite("集成 I01 可结束的真实录音")
@MainActor
struct DictationMicrophoneTests {
    private func writePCM(_ url: URL, seconds: Double, amplitude: Float = 0.1) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let frames = AVAudioFrameCount(seconds * 16_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) { buffer.floatChannelData![0][i] = amplitude * sin(Float(i) * 0.1) }
        let audio = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
        ])
        try audio.write(from: buffer)
    }

    @Test("录音超过五秒仍继续；主动结束后生成可被真实识别模块读取的 WAV")
    func manualFinish() async throws {
        var clock: TimeInterval = 0
        let capture = FakeCapture()
        let controller = MicrophoneRecordingController(mode: .dictation, requestPermission: { true }, makeCapture: { url, done in
            try writePCM(url, seconds: 7)
            capture.completion = done
            return capture
        }, uptime: { clock })
        defer { controller.deleteClip() }
        await controller.start()
        clock = 7; capture.elapsed = 7; controller.pollRecording()
        #expect(controller.state == .recording && controller.elapsed == 7)
        controller.finishRecording()
        #expect(controller.state == .ready && capture.stops == 1)
        #expect(controller.warnings.isEmpty && !controller.isVeryQuietClip)
        #expect(try BailianSpeechRecognitionService.loadAudio(#require(controller.clipURL)).count > 0)
        controller.finishRecording(); capture.completion?(false)
        #expect(controller.state == .ready && capture.stops == 1)
    }

    @Test("三分钟正式录音满足 6 MB 限制，到达上限有明确提示")
    func maximumDuration() async throws {
        let capture = FakeCapture()
        let controller = MicrophoneRecordingController(mode: .dictation, requestPermission: { true }, makeCapture: { url, done in
            try writePCM(url, seconds: 180); capture.completion = done; return capture
        })
        defer { controller.deleteClip() }
        await controller.start(); capture.completion?(true)
        #expect(controller.state == .ready)
        #expect(controller.clipBytes < 6_000_000 && abs(controller.clipDuration - 180) < 0.01)
        #expect(controller.warnings.contains { $0.contains("3 分钟上限") })
        #expect(try !BailianSpeechRecognitionService.loadAudio(#require(controller.clipURL)).isEmpty)
    }

    @Test("真实录音意外中断或看门狗超时，即使已有可读音频也不交付残片", arguments: [false, true])
    func interruption(_ timedOut: Bool) async throws {
        var clock: TimeInterval = 0
        let capture = FakeCapture()
        let controller = MicrophoneRecordingController(mode: .dictation, requestPermission: { true }, makeCapture: { url, done in
            try writePCM(url, seconds: 1); capture.completion = done; return capture
        }, uptime: { clock })
        await controller.start()
        let url = try #require(controller.clipURL)
        if timedOut { clock = 183; controller.pollRecording() } else { capture.completion?(false) }
        guard case .failed = controller.state else { Issue.record("真实会话不得把意外中断标为成功"); return }
        #expect(controller.clipURL == nil && !FileManager.default.fileExists(atPath: url.path))
        controller.finishRecording(); capture.completion?(true)
        #expect(!controller.isBusy)
    }

    @Test("短录音不会误报不足五秒；静音标记可供主流程阻止空录音上传")
    func shortSilence() async throws {
        let controller = MicrophoneRecordingController(mode: .dictation, requestPermission: { true }, makeCapture: { url, _ in
            try writePCM(url, seconds: 0.4, amplitude: 0); return FakeCapture()
        })
        defer { controller.deleteClip() }
        await controller.start(); controller.finishRecording()
        #expect(controller.state == .ready && controller.isVeryQuietClip)
        #expect(!controller.warnings.contains { $0.contains("不足 5 秒") })
        controller.deleteClip(); #expect(!controller.isVeryQuietClip)
    }
}

@Suite("T08 麦克风录音")
@MainActor
struct MicrophoneRecordingTests {
    @Test("拒绝麦克风权限不创建录音器，显示设置指引")
    func deniedPermission() async {
        var created = false
        let controller = MicrophoneRecordingController(requestPermission: { false }, makeCapture: { _, _ in
            created = true
            return FakeCapture()
        })
        await controller.start()
        #expect(!created)
        #expect(controller.status.contains("未获麦克风权限"))
        #expect(!controller.isBusy)
        #expect(controller.clipURL == nil)
    }

    @Test("授权尚未返回时取消，迟到的允许结果不会启动录音")
    func cancelPendingPermission() async {
        var continuation: CheckedContinuation<Bool, Never>?
        var created = false
        let controller = MicrophoneRecordingController(requestPermission: {
            await withCheckedContinuation { continuation = $0 }
        }, makeCapture: { _, _ in created = true; return FakeCapture() })
        let task = Task { await controller.start() }
        while continuation == nil { await Task.yield() }
        #expect(controller.state == .requestingPermission)
        controller.cancelIfActive()
        continuation?.resume(returning: true)
        await task.value
        #expect(controller.state == .cancelled)
        #expect(!created)
        #expect(controller.clipURL == nil)
    }

    @Test("录音中重复开始不创建第二个录音器；取消会停止并清理临时文件")
    func cancelRecording() async throws {
        let capture = FakeCapture()
        let controller = MicrophoneRecordingController(requestPermission: { true }, makeCapture: { url, done in
            try Data([1, 2, 3]).write(to: url)
            capture.completion = done
            return capture
        })
        await controller.start()
        let url = try #require(controller.clipURL)
        #expect(controller.state == .recording)
        await controller.start()
        #expect(capture.starts == 1)
        controller.cancelIfActive()
        #expect(capture.stops == 1)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        capture.completion?(true)
        #expect(controller.state == .cancelled)
    }

    @Test("录音器启动失败与初始化抛错均有错误提示并清理文件")
    func startFailure() async {
        for throwsOnCreate in [true, false] {
            let capture = FakeCapture()
            capture.startResult = false
            var recordedURL: URL?
            let controller = MicrophoneRecordingController(requestPermission: { true }, makeCapture: { url, _ in
                recordedURL = url
                if throwsOnCreate { throw CocoaError(.fileWriteUnknown) }
                return capture
            })
            await controller.start()
            guard case .failed = controller.state else { Issue.record("应显示失败"); return }
            #expect(!controller.isBusy)
            #expect(controller.clipURL == nil)
            if let folder = recordedURL?.deletingLastPathComponent() {
                #expect(!FileManager.default.fileExists(atPath: folder.path))
            }
        }
    }

    @Test("录音返回失败或无有效音频时不得显示录制成功")
    func invalidRecording() async {
        for success in [true, false] {
            let capture = FakeCapture()
            let controller = MicrophoneRecordingController(requestPermission: { true }, makeCapture: { _, done in
                capture.completion = done
                return capture
            })
            await controller.start()
            capture.completion?(success)
            guard case .failed = controller.state else { Issue.record("无音频不应成功"); return }
            #expect(controller.clipURL == nil)
        }
    }

    @Test("上一轮迟到的完成回调不能结束新录音")
    func staleCompletion() async {
        var captures: [FakeCapture] = []
        let controller = MicrophoneRecordingController(requestPermission: { true }, makeCapture: { _, done in
            let capture = FakeCapture()
            capture.completion = done
            captures.append(capture)
            return capture
        })
        await controller.start()
        controller.cancelIfActive()
        await controller.start()
        let newURL = controller.clipURL
        captures[0].completion?(false)
        #expect(controller.state == .recording)
        #expect(controller.clipURL == newURL)
        controller.deleteClip()
    }

    @Test("可读取的音频才进入可回放状态，重新录制及删除会清理旧文件")
    func validClipLifecycle() async throws {
        let capture = FakeCapture()
        let controller = MicrophoneRecordingController(requestPermission: { true }, makeCapture: { url, done in
            let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)!
            buffer.frameLength = 44_100
            buffer.floatChannelData![0].initialize(repeating: 0, count: 44_100)
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
            capture.completion = done
            return capture
        })
        await controller.start()
        capture.completion?(true)
        let oldURL = try #require(controller.clipURL)
        #expect(controller.state == .ready)
        #expect(abs(controller.clipDuration - 1) < 0.01)
        #expect(controller.clipBytes > 0)
        await controller.start()
        #expect(!FileManager.default.fileExists(atPath: oldURL.path))
        capture.completion?(true)
        let newURL = try #require(controller.clipURL)
        controller.deleteClip()
        #expect(controller.state == .idle)
        #expect(!FileManager.default.fileExists(atPath: newURL.path))
    }

    @Test("系统睡眠通知会停止正在进行的实际录音控制器")
    func systemInterruption() async {
        let center = NotificationCenter()
        let capture = FakeCapture()
        let recording = MicrophoneRecordingController(requestPermission: { true }, makeCapture: { _, _ in capture })
        let simulation = SessionValidationController()
        let keyboard = FnKeyMonitor()
        let observer = SessionInterruptionMonitor(session: simulation, keyboard: keyboard, center: center) {
            recording.cancelIfActive()
        }
        await recording.start()
        withExtendedLifetime(observer) { center.post(name: NSWorkspace.willSleepNotification, object: nil) }
        #expect(recording.state == .cancelled)
        #expect(capture.stops == 1)
        #expect(recording.clipURL == nil)
    }
}

@MainActor
private final class FakePlayback: MicrophonePlayback {
    var starts = 0
    var stops = 0
    var result = true
    var completion: (@MainActor (Bool) -> Void)?
    func start() -> Bool { starts += 1; return result }
    func stop() { stops += 1 }
}

@Suite("T08 边界修复")
@MainActor
struct MicrophoneRecordingBoundaryTests {
    private func writeAudio(_ url: URL, seconds: Double = 5, amplitude: Float = 0.1) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let frames = AVAudioFrameCount(44_100 * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            buffer.floatChannelData![0][i] = amplitude * sin(Float(i) * 0.1)
        }
        let audio = try AVAudioFile(forWriting: url, settings: format.settings)
        try audio.write(from: buffer)
    }

    @Test("点击后同步预留状态，立即离页不会在下一轮任务启动麦克风")
    func immediateCancellation() async {
        var requests = 0
        let controller = MicrophoneRecordingController(requestPermission: { requests += 1; return true })
        controller.beginRecording()
        #expect(controller.state == .requestingPermission)
        controller.cancelIfActive()
        for _ in 0..<10 { await Task.yield() }
        #expect(requests == 0)
        #expect(controller.state == .cancelled)
        #expect(controller.clipURL == nil)
    }

    @Test("同一控制器拒绝后重新检查权限，允许后能够录制")
    func permissionRecovery() async {
        var granted = false
        let capture = FakeCapture()
        let controller = MicrophoneRecordingController(requestPermission: { granted }, makeCapture: { _, _ in capture })
        await controller.start()
        #expect(controller.permissionDenied)
        granted = true
        await controller.start()
        #expect(!controller.permissionDenied)
        #expect(controller.state == .recording)
        controller.deleteClip()
    }

    @Test("权限等待超时退出，迟到授权不能偷偷录音")
    func permissionTimeout() async {
        var clock: TimeInterval = 0
        var continuation: CheckedContinuation<Bool, Never>?
        var created = false
        let controller = MicrophoneRecordingController(requestPermission: {
            await withCheckedContinuation { continuation = $0 }
        }, makeCapture: { _, _ in created = true; return FakeCapture() }, uptime: { clock })
        let task = Task { await controller.start() }
        while continuation == nil { await Task.yield() }
        clock = 30
        controller.pollRecording()
        #expect(controller.status.contains("权限等待超时"))
        #expect(controller.permissionDenied)
        #expect(!controller.isBusy)
        continuation?.resume(returning: true)
        await task.value
        #expect(!created)
    }

    @Test("8 秒没有结束回调时自动退出；迟到回调不能覆盖结果")
    func watchdog() async {
        var clock: TimeInterval = 100
        let capture = FakeCapture()
        let controller = MicrophoneRecordingController(requestPermission: { true }, makeCapture: { _, done in
            capture.completion = done
            return capture
        }, uptime: { clock })
        await controller.start()
        clock = 107.9
        controller.pollRecording()
        #expect(controller.state == .recording)
        clock = 108
        controller.pollRecording()
        guard case .failed = controller.state else { Issue.record("超时必须退出"); return }
        #expect(controller.status.contains("超时"))
        #expect(capture.stops == 1)
        let state = controller.state
        capture.completion?(true)
        #expect(controller.state == state)
        #expect(!controller.isBusy)
    }

    @Test("超时已有可读文件时保留音频并提示异常")
    func watchdogKeepsReadableAudio() async throws {
        var clock: TimeInterval = 0
        let controller = MicrophoneRecordingController(requestPermission: { true }, makeCapture: { url, _ in
            try writeAudio(url, seconds: 1)
            return FakeCapture()
        }, uptime: { clock })
        await controller.start()
        clock = 8
        controller.pollRecording()
        #expect(controller.state == .ready)
        #expect(controller.warnings.contains { $0.contains("超时") })
        #expect(controller.warnings.contains { $0.contains("不足 5 秒") })
        controller.deleteClip()
    }

    @Test("短录音和中断音频明确提示，正常五秒人声强度样本无提示")
    func partialAudio() async throws {
        for (seconds, success) in [(1.0, true), (5.0, false), (5.0, true)] {
            let capture = FakeCapture()
            let controller = MicrophoneRecordingController(requestPermission: { true }, makeCapture: { url, done in
                try writeAudio(url, seconds: seconds)
                capture.completion = done
                return capture
            })
            await controller.start()
            capture.completion?(success)
            #expect(controller.state == .ready)
            #expect(controller.warnings.isEmpty == (seconds == 5 && success))
            controller.deleteClip()
        }
    }

    @Test("静音与很低音量提示但仍允许回放")
    func quietAudio() async throws {
        for amplitude: Float in [0, 0.0001] {
            let capture = FakeCapture()
            let controller = MicrophoneRecordingController(requestPermission: { true }, makeCapture: { url, done in
                try writeAudio(url, amplitude: amplitude)
                capture.completion = done
                return capture
            })
            await controller.start()
            capture.completion?(true)
            #expect(controller.state == .ready)
            #expect(controller.warnings.contains { $0.contains("音量很低") })
            #expect(controller.clipURL != nil)
            controller.deleteClip()
        }
    }

    @Test("回放取消和失败保留音频，允许重试；旧回调不影响新播放")
    func playbackRecovery() async throws {
        let capture = FakeCapture()
        var players: [FakePlayback] = []
        let controller = MicrophoneRecordingController(requestPermission: { true }, makeCapture: { url, done in
            try writeAudio(url)
            capture.completion = done
            return capture
        }, makePlayback: { _, done in
            let player = FakePlayback()
            player.completion = done
            players.append(player)
            return player
        })
        await controller.start()
        capture.completion?(true)
        let url = try #require(controller.clipURL)
        controller.play()
        controller.cancelIfActive()
        #expect(controller.state == .ready)
        #expect(FileManager.default.fileExists(atPath: url.path))
        controller.play()
        players[0].completion?(false)
        #expect(controller.state == .playing)
        players[1].completion?(false)
        #expect(controller.state == .ready)
        #expect(controller.playbackMessage != nil)
        #expect(FileManager.default.fileExists(atPath: url.path))
        controller.play()
        #expect(controller.playbackMessage == nil)
        players[2].completion?(true)
        #expect(controller.state == .ready)
        controller.deleteClip()
    }

    @Test("回放创建抛错和启动失败也保留原文件")
    func playbackStartFailures() async throws {
        for shouldThrow in [true, false] {
            let capture = FakeCapture()
            let controller = MicrophoneRecordingController(requestPermission: { true }, makeCapture: { url, done in
                try writeAudio(url)
                capture.completion = done
                return capture
            }, makePlayback: { _, _ in
                if shouldThrow { throw CocoaError(.fileReadUnknown) }
                let player = FakePlayback()
                player.result = false
                return player
            })
            await controller.start()
            capture.completion?(true)
            controller.play()
            #expect(controller.state == .ready)
            #expect(controller.playbackMessage != nil)
            let url = try #require(controller.clipURL)
            #expect(FileManager.default.fileExists(atPath: url.path))
            controller.deleteClip()
        }
    }

    @Test("异常音量和时长不传入进度条")
    func invalidMeterValues() async {
        let capture = FakeCapture()
        let controller = MicrophoneRecordingController(requestPermission: { true }, makeCapture: { _, _ in capture })
        await controller.start()
        for value: Float in [.nan, .infinity, -5, 9] {
            capture.level = value
            capture.elapsed = Double(value)
            controller.pollRecording()
            #expect((0...1).contains(controller.level))
            #expect((0...5).contains(controller.elapsed))
        }
        controller.deleteClip()
    }

    @Test("菜单事件循环中也更新录音进度")
    func timerDuringMenuTracking() async {
        let capture = FakeCapture()
        capture.elapsed = 2
        let controller = MicrophoneRecordingController(requestPermission: { true }, makeCapture: { _, _ in capture })
        await controller.start()
        // 在菜单所用的模式内运行主循环，默认模式的 Timer 不会在这里触发。
        runMenuLoop()
        #expect(controller.elapsed == 2)
        controller.deleteClip()
    }

    private func runMenuLoop() {
        // 命令行测试没有 NSApplication；补上 AppKit 通常注册的菜单 common mode。
        CFRunLoopAddCommonMode(CFRunLoopGetMain(), CFRunLoopMode(RunLoop.Mode.eventTracking.rawValue as CFString))
        let deadline = Date().addingTimeInterval(0.3)
        while Date() < deadline { RunLoop.main.run(mode: .eventTracking, before: deadline) }
    }

    @Test("启动清理只移除失去文件锁的本应用录音，不删活跃实例及无关目录")
    func abandonedCleanup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let live = RecordingTemporaryStore(root: root)
        let liveURL = try live.create()
        try Data([1]).write(to: liveURL)
        var abandoned: RecordingTemporaryStore? = RecordingTemporaryStore(root: root)
        let oldURL = try abandoned!.create()
        try Data([1]).write(to: oldURL)
        abandoned = nil // 模拟异常退出：释放锁，但不主动删除。
        let unrelated = root.appendingPathComponent("do-not-delete")
        try Data([2]).write(to: unrelated)
        let linked = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: liveURL.deletingLastPathComponent())
        let cleaner = RecordingTemporaryStore(root: root)
        #expect(try cleaner.removeAbandoned() == 1)
        #expect(!FileManager.default.fileExists(atPath: oldURL.path))
        #expect(FileManager.default.fileExists(atPath: liveURL.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        #expect(FileManager.default.fileExists(atPath: linked.path))
        try live.remove()
    }

    @Test("目录创建和清理互斥，锁占用时安全失败且解锁后可重试")
    func directoryCoordination() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = RecordingTemporaryStore(root: root)
        try files.removeAbandoned()
        let fd = open(root.appendingPathComponent("coordination-lock").path, O_RDWR)
        #expect(fd >= 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
        #expect(throws: (any Error).self) { try files.create() }
        #expect(throws: (any Error).self) { try files.removeAbandoned() }
        #expect(files.directory == nil)
        #expect(flock(fd, LOCK_UN) == 0)
        let url = try files.create()
        try Data([1]).write(to: url)
        #expect(throws: (any Error).self) { try files.create() }
        #expect(FileManager.default.fileExists(atPath: url.path))
        try files.remove()
    }

    @Test("清理失败可见且重试可恢复")
    func cleanupFailureRecovery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([1]).write(to: root) // 应为目录的位置被文件占用。
        let controller = MicrophoneRecordingController(files: RecordingTemporaryStore(root: root))
        controller.cleanAbandonedRecordings()
        #expect(controller.cleanupMessage != nil)
        try FileManager.default.removeItem(at: root)
        controller.cleanAbandonedRecordings()
        #expect(controller.cleanupMessage == nil)
    }
}
