import Foundation
import Darwin

/// 每段音频持有文件锁；进程崩溃会由系统释放锁，下一次启动即可安全清理。
/// 只识别本版专属目录中的 UUID 子目录及 lease 文件，不扫描其他临时文件。
final class RecordingTemporaryStore {
    static var defaultRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Typeless01-recordings-v1", isDirectory: true)
    }
    let root: URL
    private(set) var directory: URL?
    private var lease: Int32 = -1

    init(root: URL = RecordingTemporaryStore.defaultRoot) { self.root = root }
    deinit { if lease >= 0 { close(lease) } }

    private func prepareRoot() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw CocoaError(.fileWriteInvalidFileName) }
    }

    /// 目录创建、取得录音锁和清理必须串行，防止另一进程在新目录取得锁之前将它删除。
    private func withDirectoryLock<T>(_ body: () throws -> T) throws -> T {
        try prepareRoot()
        let fd = open(root.appendingPathComponent("coordination-lock").path,
                      O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw CocoaError(.fileLocking) }
        return try body()
    }

    func create() throws -> URL {
        guard directory == nil else { throw CocoaError(.fileWriteFileExists) }
        return try withDirectoryLock {
            let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            directory = folder
            let fd = open(folder.appendingPathComponent("lease").path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
            lease = fd
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw CocoaError(.fileLocking) }
            return folder.appendingPathComponent("test.wav")
        }
    }

    func remove() throws {
        if let directory {
            try withDirectoryLock {
                if FileManager.default.fileExists(atPath: directory.path) {
                    try FileManager.default.removeItem(at: directory)
                }
            }
        }
        if lease >= 0 { close(lease); lease = -1 }
        directory = nil
    }

    @discardableResult
    func removeAbandoned() throws -> Int {
        return try withDirectoryLock {
            var count = 0
            for folder in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
                guard UUID(uuidString: folder.lastPathComponent) != nil else { continue }
                let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
                let fd = open(folder.appendingPathComponent("lease").path, O_RDWR | O_NOFOLLOW | O_NONBLOCK)
                guard fd >= 0 else { continue }
                defer { close(fd) }
                var info = stat()
                guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
                guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { continue } // 另一实例仍在用，不能删。
                let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
                guard Set(names).isSubset(of: ["lease", "test.wav"]) else { continue }
                try FileManager.default.removeItem(at: folder)
                count += 1
            }
            return count
        }
    }
}
