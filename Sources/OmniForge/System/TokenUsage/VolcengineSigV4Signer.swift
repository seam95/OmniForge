import CryptoKit
import Foundation

/// 火山引擎 SigV4 请求签名器（实现 OpenAPI V4 标准签名规范）。
struct VolcengineSigV4Signer {
    var region: String = "cn-beijing"
    var service: String = "ark"

    /// 为指定的 URLRequest 进行签名，附加 `Authorization`、`X-Date` 和 `X-Content-Sha256` 头。
    func sign(
        request: URLRequest,
        credentials: ArkCredentials,
        date: Date = Date()
    ) -> URLRequest {
        guard !credentials.accessKeyId.isEmpty, !credentials.secretAccessKey.isEmpty else {
            return request
        }
        guard let url = request.url else { return request }

        var signedRequest = request
        let httpMethod = (request.httpMethod ?? "GET").uppercased()

        // 1. 日期格式化 (UTC: YYYYMMDDTHHMMSSZ, YYYYMMDD)
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        let xDate = dateFormatter.string(from: date)

        let shortDateFormatter = DateFormatter()
        shortDateFormatter.dateFormat = "yyyyMMdd"
        shortDateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        shortDateFormatter.locale = Locale(identifier: "en_US_POSIX")
        let dateStamp = shortDateFormatter.string(from: date)

        // 2. Payload Hash
        let bodyData = request.httpBody ?? Data()
        let payloadHash = SHA256.hash(data: bodyData).compactMap { String(format: "%02x", $0) }.joined()

        // 3. Headers
        let host = url.host ?? "open.volcengineapi.com"
        signedRequest.setValue(host, forHTTPHeaderField: "Host")
        signedRequest.setValue(xDate, forHTTPHeaderField: "X-Date")
        signedRequest.setValue(payloadHash, forHTTPHeaderField: "X-Content-Sha256")

        // 4. Canonical Headers & Signed Headers
        // 字典序排序：host, x-content-sha256, x-date
        let canonicalHeaders = "host:\(host)\nx-content-sha256:\(payloadHash)\nx-date:\(xDate)\n"
        let signedHeaders = "host;x-content-sha256;x-date"

        // 5. Canonical URI & Canonical Query String
        let canonicalURI = url.path.isEmpty ? "/" : url.path
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        // Query 按 key 字典序排序
        let sortedQuery = queryItems.sorted { $0.name < $1.name }
        let canonicalQueryString = sortedQuery.map { item -> String in
            let name = item.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? item.name
            let value = (item.value ?? "").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            return "\(name)=\(value)"
        }.joined(separator: "&")

        // 6. Canonical Request
        let canonicalRequest = [
            httpMethod,
            canonicalURI,
            canonicalQueryString,
            canonicalHeaders,
            signedHeaders,
            payloadHash
        ].joined(separator: "\n")

        let canonicalRequestHash = SHA256.hash(data: Data(canonicalRequest.utf8)).compactMap { String(format: "%02x", $0) }.joined()

        // 7. String To Sign
        let credentialScope = "\(dateStamp)/\(region)/\(service)/request"
        let stringToSign = [
            "HMAC-SHA256",
            xDate,
            credentialScope,
            canonicalRequestHash
        ].joined(separator: "\n")

        // 8. Derived Signing Key
        let kSecret = SymmetricKey(data: Data(credentials.secretAccessKey.utf8))
        let kDate = HMAC<SHA256>.authenticationCode(for: Data(dateStamp.utf8), using: kSecret)
        let kRegion = HMAC<SHA256>.authenticationCode(for: Data(region.utf8), using: SymmetricKey(data: kDate))
        let kService = HMAC<SHA256>.authenticationCode(for: Data(service.utf8), using: SymmetricKey(data: kRegion))
        let kSigning = HMAC<SHA256>.authenticationCode(for: Data("request".utf8), using: SymmetricKey(data: kService))

        // 9. Calculate Signature
        let signatureCode = HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: SymmetricKey(data: kSigning))
        let signature = signatureCode.compactMap { String(format: "%02x", $0) }.joined()

        // 10. Authorization Header
        let authorization = "HMAC-SHA256 Credential=\(credentials.accessKeyId)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
        signedRequest.setValue(authorization, forHTTPHeaderField: "Authorization")

        return signedRequest
    }
}
