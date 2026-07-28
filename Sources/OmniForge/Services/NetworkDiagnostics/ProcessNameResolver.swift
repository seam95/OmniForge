import AppKit
import Darwin
import Foundation

// MARK: - Protocol

protocol ProcessNameResolving {
    /// PID → 显示名：NSRunningApplication → proc_pidpath basename → lsof command。
    func resolveDisplayName(pid: pid_t, fallbackCommand: String) -> String
}

// MARK: - Production resolver

final class ProcessNameResolver: ProcessNameResolving {
    private let runningAppName: (pid_t) -> String?
    private let processPath: (pid_t) -> String?
    private let pathBasename: (String) -> String

    init(
        runningAppName: @escaping (pid_t) -> String? = ProcessNameResolver.liveRunningAppName,
        processPath: @escaping (pid_t) -> String? = ProcessNameResolver.liveProcessPath,
        pathBasename: @escaping (String) -> String = { ($0 as NSString).lastPathComponent }
    ) {
        self.runningAppName = runningAppName
        self.processPath = processPath
        self.pathBasename = pathBasename
    }

    func resolveDisplayName(pid: pid_t, fallbackCommand: String) -> String {
        if let name = runningAppName(pid)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty
        {
            return name
        }
        if let path = processPath(pid) {
            let base = pathBasename(path)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !base.isEmpty {
                return base
            }
        }
        let fallback = fallbackCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? "—" : fallback
    }

    // MARK: Live providers

    static func liveRunningAppName(pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        guard let app = NSRunningApplication(processIdentifier: pid),
              let name = app.localizedName,
              !name.isEmpty
        else {
            return nil
        }
        return name
    }

    static func liveProcessPath(pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let len = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard len > 0 else { return nil }
        return String(cString: buffer)
    }
}
