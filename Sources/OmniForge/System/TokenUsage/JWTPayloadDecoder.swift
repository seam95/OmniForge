import Foundation

/// JWT payload 本地解码 — 不调网就拿套餐/账号信息（参考 04）。
/// 纯函数：base64url 解第二段，JSONSerialization 取字典。
enum JWTPayloadDecoder {
    /// 解码 JWT 的 payload 段（第 2 段）；非 JWT / 解析失败 → nil。
    static func decodePayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        guard let data = decodeBase64URL(String(parts[1])) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func decodeBase64URL(_ value: String) -> Data? {
        let padLen = (4 - value.count % 4) % 4
        var padded = value
        if padLen > 0 { padded += String(repeating: "=", count: padLen) }
        let standard = padded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: standard)
    }

    static func decode<T: Decodable>(_ type: T.Type, from token: String) -> T? {
        guard let payload = decodePayload(token) else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
