import Foundation

/// application/x-www-form-urlencoded 编码（OAuth 刷新 body 格式化；纯函数）。
enum FormURLEncoder {
    static func encode(_ fields: [String: String]) -> Data {
        let encoded = fields.map { key, value in
            "\(percentEncode(key))=\(percentEncode(value))"
        }.joined(separator: "&")
        return Data(encoded.utf8)
    }

    private static func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
