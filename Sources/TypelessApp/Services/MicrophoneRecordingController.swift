import AVFoundation
import Combine

/// 负责本机录音和回放；T11 由独立识别控制器在用户点击后读取已完成的 clipURL。
@MainActor
final class MicrophoneRecordingController: NSObject, ObservableObject {
    enum Mode {
        case fiveSecondTest, dictation
        // 16 kHz 单声道 PCM 的 3 分钟 WAV 约 5.76 MB，Base64 后低于服务的 10 MB 上限。
        var maximumDuration: TimeInterval { self == .dictation ? 180 : 5 }
        var sampleRate: Double { self == .dictation ? 16_000 : 44_100 }
    }
    enum State: Equatable {
        case idle, requestingPermission, recording, ready, playing, cancelled
        case failed(String)
    }

    typealias CaptureFactory = @MainActor (URL, @escaping @MainActor (Bool) -> Void) throws -> any MicrophoneCapture
    typealias PlaybackFactory = @MainActor (URL, @escaping @MainActor (Bool) -> Void) throws -> any MicrophonePlayback
    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: Float = 0
    @Published private(set) var clipDuration: TimeInterval = 0
    @Published private(set) var clipBytes: Int64 = 0
    @Published private(set) var warnings: [String] = []
    @Published private(set) var playbackMessage: String?
    @Published private(set) var cleanupMessage: String?
    @Published private(set) var permissionDenied = false
    @Published private(set) var isVeryQuietClip = false
    let mode: Mode
    private(set) var clipURL: URL?
    private var operationID: UUID?
    private var playbackID: UUID?
    private var capture: (any MicrophoneCapture)?
    private var player: (any MicrophonePlayback)?
    private var timer: Timer?
    private var startupTask: Task<Void, Never>?
    private var startedAt: TimeInterval = 0
    private let requestPermission: @MainActor () async -> Bool
    private let makeCapture: CaptureFactory
    private let makePlayback: PlaybackFactory
    private let uptime: () -> TimeInterval
    private let files: RecordingTemporaryStore

    init(
        mode: Mode = .fiveSecondTest,
        requestPermission: @escaping @MainActor () async -> Bool = {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return true
            case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
            default: return false
            }
        },
        makeCapture: CaptureFactory? = nil,
        makePlayback: @escaping PlaybackFactory = { try SystemMicrophonePlayback(url: $0, completion: $1) },
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        files: RecordingTemporaryStore = RecordingTemporaryStore()
    ) {
        self.requestPermission = requestPermission
        self.mode = mode
        self.makeCapture = makeCapture ?? { url, completion in
            try SystemMicrophoneCapture(url: url, maximumDuration: mode.maximumDuration,
                                        sampleRate: mode.sampleRate, completion: completion)
        }
        self.makePlayback = makePlayback
        self.uptime = uptime
        self.files = files
        super.init()
    }

    var canDeleteClip: Bool { files.directory != nil }

    var isBusy: Bool { state == .requestingPermission || state == .recording || state == .playing }

    var status: String {
        switch state {
        case .idle: return "尚未录音"
        case .requestingPermission: return "等待麦克风权限，请在系统弹窗中选择"
        case .recording: return mode == .dictation
            ? "正在录音；再按 Fn 结束，本次最多 3 分钟"
            : "正在录音，请说话；5 秒后自动停止"
        case .ready: return warnings.isEmpty ? "录音完成，可以播放" : "录音已保存，请查看下方提示并回听"
        case .playing: return "正在播放刚才的录音"
        case .cancelled: return "已取消，本次测试录音已清理"
        case .failed(let message): return message
        }
    }

    func cleanAbandonedRecordings() {
        do { try files.removeAbandoned(); cleanupMessage = nil }
        catch { cleanupMessage = "旧的临时录音清理失败。请检查临时目录权限或磁盘空间，再点击“重试清理”。" }
    }

    // 按钮同步占用状态，再启动异步授权；立即关闭页面也能取消尚未执行的任务。
    func beginRecording() {
        guard let id = reserveRecording() else { return }
        startupTask = Task { [weak self] in await self?.authorizeAndRecord(id: id) }
    }

    func start() async {
        guard !Task.isCancelled, let id = reserveRecording() else { return }
        await authorizeAndRecord(id: id)
    }

    /// 真实会话第二次 Fn：同步停止并关闭 WAV，再发布 ready，禁止识别读取半个文件。
    func finishRecording() {
        guard mode == .dictation, state == .recording, let id = operationID else { return }
        finishedRecording(id: id, success: true)
    }

    private func reserveRecording() -> UUID? {
        guard !isBusy, clearClip() else { return nil }
        permissionDenied = false
        let id = UUID()
        operationID = id
        state = .requestingPermission
        startedAt = uptime()
        installTimer()
        return id
    }

    private func authorizeAndRecord(id: UUID) async {
        guard operationID == id, !Task.isCancelled else { return }
        let granted = await requestPermission()
        guard operationID == id, state == .requestingPermission else { return }
        guard !Task.isCancelled else { cancelIfActive(); return }
        guard granted else {
            fail("未获麦克风权限。请到“系统设置 → 隐私与安全性 → 麦克风”允许 云写君，然后重试；若系统要求退出，请重开应用。", id: id)
            permissionDenied = true
            return
        }
        do {
            let url = try files.create()
            clipURL = url
            let next = try makeCapture(url) { [weak self] success in self?.finishedRecording(id: id, success: success) }
            capture = next
            state = .recording
            startedAt = uptime()
            guard next.start() else {
                fail("无法开始录音，请检查“系统设置 → 声音 → 输入”中是否有可用麦克风，再重试。", id: id)
                return
            }
            guard operationID == id, state == .recording else { return }
            installTimer()
        } catch {
            fail("录音设备或临时文件无法准备，请检查麦克风及磁盘可用空间后重试。", id: id)
        }
    }

    private func installTimer() {
        timer?.invalidate()
        let next = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollRecording() }
        }
        timer = next
        RunLoop.main.add(next, forMode: .common)
    }

    /// 权限等待最多 30 秒；录音超过对应上限 3 秒仍无通知则强制停止。
    func pollRecording() {
        guard let id = operationID else { return }
        if state == .requestingPermission {
            if uptime() - startedAt >= 30 {
                fail("麦克风权限等待超时，本次录音已取消。请检查系统权限后重新点击录制；若重新构建后一直没有提示，请退出重开应用并检查授权。", id: id)
                permissionDenied = true
            }
            return
        }
        guard state == .recording, let capture else { return }
        let duration = capture.elapsed
        let input = capture.level
        elapsed = duration.isFinite ? min(mode.maximumDuration, max(0, duration)) : 0
        level = input.isFinite ? min(1, max(0, input)) : 0
        if uptime() - startedAt >= mode.maximumDuration + 3 {
            finishedRecording(id: id, success: false, timedOut: true)
        }
    }

    private func finishedRecording(id: UUID, success: Bool, timedOut: Bool = false) {
        guard operationID == id, state == .recording else { return }
        timer?.invalidate(); timer = nil
        capture?.stop(); capture = nil
        level = 0
        if mode == .dictation, !success || timedOut {
            fail("录音意外中断，已停止本次会话；没有把不完整音频发送到 API，请重新录制。", id: id)
            return
        }
        guard let url = clipURL else { fail("没有取得有效音频，请重新录制。", id: id); return }
        do {
            let audio = try AVAudioFile(forReading: url)
            let duration = Double(audio.length) / audio.processingFormat.sampleRate
            guard duration.isFinite, duration > 0, audio.length > 0 else {
                fail("没有取得有效音频，请检查麦克风后重新录制。", id: id)
                return
            }
            clipDuration = duration
            elapsed = duration
            clipBytes = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            if timedOut { warnings.append("录音结束通知超时，已强制停止。保留了可读取的音频，请回听确认。") }
            else if !success { warnings.append("录音曾中断，已保留可读取的部分，请回听或重新录制。") }
            if mode == .fiveSecondTest {
                if duration < 4.8 { warnings.append("录音不足 5 秒，可能不完整；请检查麦克风连接后重录。") }
                if duration > 5.5 { warnings.append("录音超过预期的 5 秒，请回听确认。") }
            } else if duration >= 29.8 {
                warnings.append("已达到当前 3 分钟上限，自动结束录音并开始处理。")
            }
            isVeryQuietClip = try isVeryQuiet(audio)
            if isVeryQuietClip {
                warnings.append("录音音量很低或接近静音。请回听，并检查“系统设置 → 声音 → 输入”的设备和输入音量。这不是人声识别。")
            }
            state = .ready
        } catch {
            fail(timedOut ? "录音超时，已停止且没有可用音频，请检查麦克风后重试。" : "录音中断或文件无法读取，请检查麦克风连接后重新录制。", id: id)
        }
    }

    // 分块读取，避免文件异常变长时一次性分配大量内存。阈值是整体 RMS -50 dBFS。
    private func isVeryQuiet(_ audio: AVAudioFile) throws -> Bool {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 4096) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var energy: Double = 0
        var samples = 0
        while audio.framePosition < audio.length {
            try audio.read(into: buffer)
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { throw CocoaError(.fileReadCorruptFile) }
            for channel in 0..<Int(buffer.format.channelCount) {
                for frame in 0..<Int(buffer.frameLength) {
                    let value = Double(channels[channel][frame])
                    guard value.isFinite else { throw CocoaError(.fileReadCorruptFile) }
                    energy += value * value
                }
            }
            samples += Int(buffer.frameLength) * Int(buffer.format.channelCount)
        }
        return samples > 0 && sqrt(energy / Double(samples)) < 0.0031623
    }

    func play() {
        guard state == .ready, let url = clipURL else { return }
        let id = UUID()
        playbackID = id
        playbackMessage = nil
        do {
            let next = try makePlayback(url) { [weak self] success in
                guard let self, self.playbackID == id, self.state == .playing else { return }
                if success { self.stopPlayback() } else { self.playbackFailed() }
            }
            player = next
            state = .playing
            if !next.start() { playbackFailed() }
        } catch { playbackFailed() }
    }

    private func playbackFailed() {
        stopPlayback()
        playbackID = nil
        state = .ready
        playbackMessage = "播放失败，录音仍保留。请检查系统声音输出后再点“播放录音”；若文件损坏，可重新录制。"
    }

    func stopPlayback() {
        guard state == .playing else { return }
        playbackID = nil
        player?.stop(); player = nil
        state = .ready
    }

    func cancelIfActive() {
        guard isBusy else { return }
        if state == .playing { stopPlayback(); return }
        if clearClip() { state = .cancelled }
    }

    func deleteClip() { if clearClip() { state = .idle } }

    private func fail(_ message: String, id: UUID) {
        guard operationID == id else { return }
        if clearClip() { state = .failed(message) }
    }

    @discardableResult
    private func clearClip() -> Bool {
        operationID = nil
        startupTask?.cancel(); startupTask = nil
        timer?.invalidate(); timer = nil
        capture?.stop(); capture = nil
        playbackID = nil
        player?.stop(); player = nil
        elapsed = 0; level = 0; clipDuration = 0; clipBytes = 0
        warnings = []; playbackMessage = nil; isVeryQuietClip = false
        do { try files.remove() }
        catch {
            state = .failed("录音已停止，但临时文件清理失败；请再次点击“删除测试录音”。")
            return false
        }
        clipURL = nil
        return true
    }
}
