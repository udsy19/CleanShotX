import Foundation
import CryptoKit

/// AWS Signature Version 4 (header-based authorization), as used by S3-compatible storage.
public struct AWSSigV4: Sendable {
    public static let algorithm = "AWS4-HMAC-SHA256"
    /// Payload hash value telling S3 the body is not covered by the signature (HTTPS only).
    public static let unsignedPayload = "UNSIGNED-PAYLOAD"
    public static let emptyPayloadHash = sha256Hex(Data())

    public var accessKeyID: String
    public var secretAccessKey: String
    public var region: String
    public var service: String

    public init(accessKeyID: String, secretAccessKey: String, region: String, service: String) {
        self.accessKeyID = accessKeyID; self.secretAccessKey = secretAccessKey
        self.region = region; self.service = service
    }

    public struct Signature: Sendable {
        public var canonicalRequest: String
        public var stringToSign: String
        public var signature: String
        public var authorization: String
        /// Headers the caller must add to the request (`Authorization`, `x-amz-date`).
        public var headers: [String: String]
    }

    /// Signs a request. `headers` are the headers that will be sent (they are all signed); `host` and
    /// `x-amz-date` are added when missing. `payloadHash` is the hex SHA-256 of the body or `unsignedPayload`.
    public func sign(method: String, url: URL, headers: [String: String], payloadHash: String, date: Date) -> Signature {
        var all: [String: String] = [:]
        for (k, v) in headers { all[k.lowercased()] = Self.normalizeHeaderValue(v) }
        if all["host"] == nil { all["host"] = Self.hostHeader(url) }
        // A caller-supplied x-amz-date wins so the scope always matches the signed timestamp.
        let effectiveDate = all["x-amz-date"] ?? Self.timestamps(date).amzDate
        all["x-amz-date"] = effectiveDate
        let stamp = String(effectiveDate.prefix(8))

        let names = all.keys.sorted()
        let canonicalHeaders = names.map { "\($0):\(all[$0]!)\n" }.joined()
        let signedHeaders = names.joined(separator: ";")
        let canonicalRequest = [method.uppercased(), Self.canonicalURI(url), Self.canonicalQuery(url),
                                canonicalHeaders, signedHeaders, payloadHash].joined(separator: "\n")
        let scope = "\(stamp)/\(region)/\(service)/aws4_request"
        let stringToSign = [Self.algorithm, effectiveDate, scope, Self.sha256Hex(Data(canonicalRequest.utf8))].joined(separator: "\n")
        let key = Self.signingKey(secret: secretAccessKey, dateStamp: stamp, region: region, service: service)
        let signature = Self.hex(Self.hmac(key: key, stringToSign))
        let authorization = "\(Self.algorithm) Credential=\(accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
        return Signature(canonicalRequest: canonicalRequest, stringToSign: stringToSign, signature: signature,
                         authorization: authorization, headers: ["Authorization": authorization, "x-amz-date": effectiveDate])
    }

    // MARK: - Primitives

    public static func signingKey(secret: String, dateStamp: String, region: String, service: String) -> Data {
        let kDate = hmac(key: Data("AWS4\(secret)".utf8), dateStamp)
        let kRegion = hmac(key: kDate, region)
        let kService = hmac(key: kRegion, service)
        return hmac(key: kService, "aws4_request")
    }

    public static func hmac(key: Data, _ message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key)))
    }

    public static func sha256Hex(_ data: Data) -> String { hex(SHA256.hash(data: data)) }

    /// Streams a file through SHA-256 without loading it into memory.
    public static func sha256Hex(fileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hex(hasher.finalize())
    }

    public static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// `yyyyMMdd'T'HHmmss'Z'` and `yyyyMMdd` in UTC.
    public static func timestamps(_ date: Date) -> (amzDate: String, dateStamp: String) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let stamp = String(format: "%04d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        return (stamp + String(format: "T%02d%02d%02dZ", c.hour ?? 0, c.minute ?? 0, c.second ?? 0), stamp)
    }

    private static let unreserved: Set<UInt8> = Set(Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8))

    /// RFC 3986 encoding as AWS specifies: everything but unreserved characters becomes `%XX` (uppercase).
    public static func uriEncode(_ s: String, encodeSlash: Bool = true) -> String {
        var out = ""
        for b in s.utf8 {
            if unreserved.contains(b) || (!encodeSlash && b == UInt8(ascii: "/")) {
                out.unicodeScalars.append(UnicodeScalar(b))
            } else {
                out += String(format: "%%%02X", b)
            }
        }
        return out
    }

    /// Path segments decoded once and re-encoded (S3 rules: no path normalization).
    public static func canonicalURI(_ url: URL) -> String {
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
        guard !path.isEmpty else { return "/" }
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .map { uriEncode(String($0).removingPercentEncoding ?? String($0)) }
            .joined(separator: "/")
    }

    public static func canonicalQuery(_ url: URL) -> String {
        guard let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery, !query.isEmpty else { return "" }
        let pairs: [(String, String)] = query.split(separator: "&").map { part in
            let kv = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let k = String(kv[0]).removingPercentEncoding ?? String(kv[0])
            let v = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
            return (uriEncode(k), uriEncode(v))
        }
        return pairs.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
    }

    static func hostHeader(_ url: URL) -> String {
        let host = url.host ?? ""
        guard let port = url.port else { return host }
        let scheme = url.scheme?.lowercased()
        return (scheme == "https" && port == 443) || (scheme == "http" && port == 80) ? host : "\(host):\(port)"
    }

    /// Trims and collapses runs of spaces, per the canonical-headers rule.
    static func normalizeHeaderValue(_ v: String) -> String {
        v.trimmingCharacters(in: .whitespaces).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }
}
