import AppKit

/// 仅通过启动参数 -stickyNotesDiagnosticsPath <路径> 开启，不记录正文或窗口标题。
@MainActor
final class StickyNoteDiagnostics {
    static let shared: StickyNoteDiagnostics? = {
        guard let path = UserDefaults.standard.string(forKey: "stickyNotesDiagnosticsPath"),
              !path.isEmpty else { return nil }
        do {
            let trace = try StickyNoteDiagnostics(url: URL(fileURLWithPath: path))
            trace.record("trace.start", fields: [
                "pid": ProcessInfo.processInfo.processIdentifier,
                "executable": Bundle.main.executablePath ?? "",
                "os": ProcessInfo.processInfo.operatingSystemVersionString
            ])
            trace.observeFocusAndClicks()
            return trace
        } catch {
            NSLog("StickyNoteDiagnostics 无法打开日志：%@", error.localizedDescription)
            return nil
        }
    }()

    private let file: FileHandle
    private let writes = DispatchQueue(label: "app.omniforge.sticky-note-diagnostics")
    private var sequence = 0
    private var snapshots: [UUID: Data] = [:]
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var monitors: [Any] = []

    init(url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        file = try FileHandle(forWritingTo: url)
        try file.seekToEnd()
    }

    deinit {
        let file = file
        writes.sync { try? file.close() }
    }

    func record(_ event: String, noteID: UUID? = nil, fields: [String: Any] = [:]) {
        sequence += 1
        var row = fields
        row["event"] = event
        row["seq"] = sequence
        row["wall"] = Date().timeIntervalSince1970
        row["uptime"] = ProcessInfo.processInfo.systemUptime
        if let noteID { row["noteID"] = noteID.uuidString }
        do {
            var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            data.append(0x0A)
            let line = data
            let file = file
            // 点击与焦点回调只取快照，写盘不得阻塞原有窗口策略。
            writes.async {
                do { try file.write(contentsOf: line) }
                catch { NSLog("StickyNoteDiagnostics 写入失败：%@", error.localizedDescription) }
            }
        } catch {
            NSLog("StickyNoteDiagnostics 写入失败：%@", error.localizedDescription)
        }
    }

    func capture(_ event: String, noteID: UUID, panel: NSPanel,
                 pinned: Bool, promoted: Bool, changesOnly: Bool = false) {
        let front = NSWorkspace.shared.frontmostApplication
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                kCGNullWindowID) as? [[String: Any]] ?? []
        let rank = windows.firstIndex { ($0[kCGWindowNumber as String] as? Int) == panel.windowNumber }
        let serverWindow = rank.map { windows[$0] }
        let bounds = (serverWindow?[kCGWindowBounds as String] as? [String: Any])
            .flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
        var fields: [String: Any] = [
            "window": panel.windowNumber, "level": panel.level.rawValue,
            "key": panel.isKeyWindow, "main": panel.isMainWindow,
            "visible": panel.isVisible, "occlusionVisible": panel.occlusionState.contains(.visible),
            "appActive": NSApp?.isActive ?? false,
            "appKeyWindow": NSApp?.keyWindow?.windowNumber ?? -1,
            "appMainWindow": NSApp?.mainWindow?.windowNumber ?? -1,
            "frontPID": front?.processIdentifier ?? -1,
            "frontBundle": front?.bundleIdentifier ?? "",
            "pinned": pinned, "promoted": promoted,
            "keySuppressed": PanelKeySuppression.isActive,
            "collectionBehavior": panel.collectionBehavior.rawValue,
            "frame": NSStringFromRect(panel.frame),
            "serverRank": rank ?? -1,
            "serverLayer": serverWindow?[kCGWindowLayer as String] as? Int ?? -1,
            "firstResponder": panel.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        ]
        if let bounds { fields["overlappingWindowsFrontToBack"] = Self.windowStack(windows, intersecting: bounds) }
        let fingerprint = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        if changesOnly, let fingerprint, snapshots[noteID] == fingerprint { return }
        snapshots[noteID] = fingerprint
        record(event, noteID: noteID, fields: fields)
    }

    /// CGWindow 字段白名单：保留真实遮挡顺序，排除标题及任何正文信息。
    static func windowStack(_ windows: [[String: Any]], intersecting rect: CGRect) -> [[String: Any]] {
        windows.compactMap { window -> [String: Any]? in
            guard let rawBounds = window[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: rawBounds as CFDictionary),
                  bounds.intersects(rect) else { return nil }
            return [
                "id": window[kCGWindowNumber as String] as? Int ?? -1,
                "pid": window[kCGWindowOwnerPID as String] as? Int ?? -1,
                "layer": window[kCGWindowLayer as String] as? Int ?? -1,
                "bounds": rawBounds,
                "alpha": window[kCGWindowAlpha as String] as? Double ?? 1
            ]
        }.prefix(16).map { $0 }
    }

    private func observeFocusAndClicks() {
        let centers: [(NotificationCenter, [Notification.Name])] = [
            (.default, [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification]),
            (NSWorkspace.shared.notificationCenter, [NSWorkspace.didActivateApplicationNotification,
                NSWorkspace.didDeactivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification])
        ]
        for (center, names) in centers {
            for name in names {
                let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    MainActor.assumeIsolated {
                        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                        self?.record(note.name.rawValue, fields: [
                            "appActive": NSApp?.isActive ?? false,
                            "subjectPID": app?.processIdentifier ?? -1,
                            "subjectBundle": app?.bundleIdentifier ?? "",
                            "frontPID": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
                        ])
                    }
                }
                observers.append((center, token))
            }
        }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        if let token = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.recordClick(event, source: "local") }
            return event
        }) { monitors.append(token) }
        if let token = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.recordClick(event, source: "global") }
        }) { monitors.append(token) }
    }

    private func recordClick(_ event: NSEvent, source: String) {
        record("mouse.down", fields: [
            "source": source, "window": event.windowNumber,
            "eventUptime": event.timestamp,
            "frontPID": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
        ])
    }
}
