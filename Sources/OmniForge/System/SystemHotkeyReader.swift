import Carbon
import Foundation

/// 读取系统配置的快捷键
struct SystemHotkeyReader {
    /// 系统符号快捷键的 ID
    enum SymbolicHotkeyID: Int {
        case selectPreviousInputSource = 60
        case selectNextInputSource = 61
    }

    struct Hotkey: Equatable, Codable {
        let keyCode: Int
        let modifiers: Int

        /// 将系统 plist 中的 modifiers 转换为 CGEventFlags
        var cgEventFlags: CGEventFlags {
            var flags = CGEventFlags()

            // plist 中的 modifiers 格式：
            // Shift: 131072 (1 << 17)
            // Control: 262144 (1 << 18)
            // Option: 524288 (1 << 19)
            // Command: 1048576 (1 << 20)
            // Fn: 8388608 (1 << 23)

            if modifiers & (1 << 17) != 0 { flags.insert(.maskShift) }
            if modifiers & (1 << 18) != 0 { flags.insert(.maskControl) }
            if modifiers & (1 << 19) != 0 { flags.insert(.maskAlternate) }
            if modifiers & (1 << 20) != 0 { flags.insert(.maskCommand) }
            if modifiers & (1 << 23) != 0 { flags.insert(.maskSecondaryFn) }

            return flags
        }
    }

    /// 读取输入法切换相关的系统快捷键
    static func readInputSourceHotkeys() -> [Hotkey] {
        var hotkeys: [Hotkey] = []

        // 方法1: 直接读取 plist 文件
        let plistPath = NSString(string: "~/Library/Preferences/com.apple.symbolichotkeys.plist").expandingTildeInPath

        if let plist = NSDictionary(contentsOfFile: plistPath) as? [String: Any],
           let appleSymbolicHotkeys = plist["AppleSymbolicHotKeys"] as? [String: Any] {
            hotkeys = parseHotkeys(from: appleSymbolicHotkeys)
        }

        // 方法2: 如果方法1失败，尝试使用 defaults 命令
        if hotkeys.isEmpty {
            hotkeys = readHotkeysViaDefaults()
        }

        // 方法3: 如果都失败了，使用默认的常见快捷键
        if hotkeys.isEmpty {
            print("[SystemHotkeyReader] 使用默认快捷键配置")
            // Ctrl+Space (最常见的输入法切换快捷键)
            hotkeys.append(Hotkey(keyCode: 49, modifiers: 262144))
        }

        return hotkeys
    }

    private static func parseHotkeys(from appleSymbolicHotkeys: [String: Any]) -> [Hotkey] {
        var hotkeys: [Hotkey] = []

        for id in [SymbolicHotkeyID.selectPreviousInputSource, .selectNextInputSource] {
            if let hotkeyDict = appleSymbolicHotkeys[String(id.rawValue)] as? [String: Any],
               let enabled = hotkeyDict["enabled"] as? Bool, enabled,
               let value = hotkeyDict["value"] as? [String: Any],
               let parameters = value["parameters"] as? [Any],
               parameters.count >= 3 {

                // parameters 可能是 Int 或 NSNumber
                let keyCode: Int
                let modifiers: Int

                if let kc = parameters[1] as? Int {
                    keyCode = kc
                } else if let kc = parameters[1] as? NSNumber {
                    keyCode = kc.intValue
                } else {
                    continue
                }

                if let mod = parameters[2] as? Int {
                    modifiers = mod
                } else if let mod = parameters[2] as? NSNumber {
                    modifiers = mod.intValue
                } else {
                    continue
                }

                let hotkey = Hotkey(keyCode: keyCode, modifiers: modifiers)
                hotkeys.append(hotkey)
                print("[SystemHotkeyReader] 检测到快捷键 ID \(id.rawValue): keyCode=\(keyCode), modifiers=\(modifiers)")
            }
        }

        return hotkeys
    }

    private static func readHotkeysViaDefaults() -> [Hotkey] {
        var hotkeys: [Hotkey] = []

        // 使用 defaults 命令读取
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["read", "com.apple.symbolichotkeys", "AppleSymbolicHotKeys"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                hotkeys = parseDefaultsOutput(output)
            }
        } catch {
            print("[SystemHotkeyReader] defaults 命令执行失败: \(error)")
        }

        return hotkeys
    }

    private static func parseDefaultsOutput(_ output: String) -> [Hotkey] {
        var hotkeys: [Hotkey] = []

        // 解析 ID 60 的配置
        if let hotkey = parseHotkeyFromOutput(output, id: "60") {
            hotkeys.append(hotkey)
            print("[SystemHotkeyReader] 检测到快捷键 ID 60: keyCode=\(hotkey.keyCode), modifiers=\(hotkey.modifiers)")
        }

        // 解析 ID 61 的配置
        if let hotkey = parseHotkeyFromOutput(output, id: "61") {
            hotkeys.append(hotkey)
            print("[SystemHotkeyReader] 检测到快捷键 ID 61: keyCode=\(hotkey.keyCode), modifiers=\(hotkey.modifiers)")
        }

        return hotkeys
    }

    private static func parseHotkeyFromOutput(_ output: String, id: String) -> Hotkey? {
        // 查找特定 ID 的块
        let pattern = "\(id)\\s*=\\s*\\{[^}]*enabled\\s*=\\s*1[^}]*parameters\\s*=\\s*\\([^)]*\\)"

        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: output, options: [], range: NSRange(output.startIndex..., in: output)) else {
            return nil
        }

        let matchedString = String(output[Range(match.range, in: output)!])

        // 提取 parameters
        let paramsPattern = "parameters\\s*=\\s*\\(\\s*([0-9]+),\\s*([0-9]+),\\s*([0-9]+)"
        guard let paramsRegex = try? NSRegularExpression(pattern: paramsPattern, options: []),
              let paramsMatch = paramsRegex.firstMatch(in: matchedString, options: [], range: NSRange(matchedString.startIndex..., in: matchedString)),
              paramsMatch.numberOfRanges >= 4 else {
            return nil
        }

        let keyCodeRange = Range(paramsMatch.range(at: 2), in: matchedString)!
        let modifiersRange = Range(paramsMatch.range(at: 3), in: matchedString)!

        guard let keyCode = Int(matchedString[keyCodeRange]),
              let modifiers = Int(matchedString[modifiersRange]) else {
            return nil
        }

        return Hotkey(keyCode: keyCode, modifiers: modifiers)
    }
}
