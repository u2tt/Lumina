import Foundation
import os

/// 统一日志：写 stderr（前台可见）+ 落盘到 ~/Library/Logs/Lumina.log
enum Log {
    private static let lock = NSLock()
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        return f
    }()

    static var logURL: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("Lumina.log")
    }

    private static func write(_ level: String, _ message: String) {
        let line = "[\(formatter.string(from: Date()))] [\(level)] \(message)\n"
        lock.lock()
        FileHandle.standardError.write(line.data(using: .utf8) ?? Data())
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8) ?? Data())
            try? handle.close()
        } else {
            try? line.write(to: logURL, atomically: true, encoding: .utf8)
        }
        lock.unlock()
    }

    static func info(_ m: String)  { write("INFO", m) }
    static func warn(_ m: String)  { write("WARN", m) }
    static func error(_ m: String) { write("ERR ", m) }
}
