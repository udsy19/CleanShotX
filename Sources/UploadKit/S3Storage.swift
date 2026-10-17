import Foundation
import ShotcraftCore

// MARK: - Configuration & addressing

/// Snapshot of the S3 settings (Settings → Upload) plus the Keychain secret.
public struct S3Configuration: Sendable, Equatable {
    public var endpoint: String
    public var region: String
    public var bucket: String
    public var accessKeyID: String
    public var secretAccessKey: String
    public var publicURLPrefix: String
    public var pathPrefix: String

    public init(endpoint: String = "", region: String = "us-east-1", bucket: String, accessKeyID: String,
                secretAccessKey: String, publicURLPrefix: String = "", pathPrefix: String = "") {
        self.endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = region.trimmingCharacters(in: .whitespacesAndNewlines)
        self.region = r.isEmpty ? "us-east-1" : r
        self.bucket = bucket.trimmingCharacters(in: .whitespacesAndNewlines)
        self.accessKeyID = accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.secretAccessKey = secretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.publicURLPrefix = publicURLPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        self.pathPrefix = pathPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func current() -> S3Configuration {
        S3Configuration(endpoint: Defaults[.s3Endpoint], region: Defaults[.s3Region], bucket: Defaults[.s3Bucket],
                        accessKeyID: Defaults[.s3AccessKeyID], secretAccessKey: Keychain.get(Keychain.s3SecretKeyAccount) ?? "",
                        publicURLPrefix: Defaults[.s3PublicURLPrefix], pathPrefix: Defaults[.s3PathPrefix])
    }

    public var isComplete: Bool { !bucket.isEmpty && !accessKeyID.isEmpty && !secretAccessKey.isEmpty }

    func validate() throws {
        if bucket.isEmpty { throw UploadError.failed("Enter the name of your S3 bucket in Settings → Upload.") }
        if accessKeyID.isEmpty || secretAccessKey.isEmpty {
            throw UploadError.failed("Enter your S3 access key ID and secret access key in Settings → Upload.")
        }
        if baseURL == nil { throw UploadError.failed("The S3 endpoint “\(endpoint)” isn't a valid URL.") }
    }

    /// Endpoint as a URL (scheme defaulted to https), or nil for AWS.
    private var endpointURL: URL? {
        guard !endpoint.isEmpty else { return nil }
        var s = endpoint
        if !s.contains("://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host?.isEmpty == false else { return nil }
        return url
    }

    /// Virtual-hosted style (`bucket.host/key`) vs path style (`host/bucket/key`).
    public var usesVirtualHostedStyle: Bool {
        if let url = endpointURL { return url.host?.lowercased().hasPrefix(bucket.lowercased() + ".") == true }
        return Self.isDNSCompatibleBucket(bucket)
    }

    /// Bucket names usable as a TLS-valid subdomain: 3–63 chars of a–z, 0–9, '-', no dots.
    static func isDNSCompatibleBucket(_ b: String) -> Bool {
        (3...63).contains(b.count) && b.allSatisfy { ($0.isLowercase && $0.isASCII) || $0.isNumber || $0 == "-" }
            && !b.hasPrefix("-") && !b.hasSuffix("-")
    }

    /// URL prefix objects live under, without a trailing slash.
    var baseURL: String? {
        if let url = endpointURL {
            return usesVirtualHostedStyle ? url.absoluteString : url.absoluteString + "/" + AWSSigV4.uriEncode(bucket)
        }
        return usesVirtualHostedStyle ? "https://\(bucket).s3.\(region).amazonaws.com"
                                      : "https://s3.\(region).amazonaws.com/\(AWSSigV4.uriEncode(bucket))"
    }

    public func objectURL(key: String) -> URL? {
        guard let base = baseURL else { return nil }
        return URL(string: base + "/" + AWSSigV4.uriEncode(key, encodeSlash: false))
    }

    /// Shareable link: the public prefix (CDN / public bucket domain) + key, else the object URL.
    public func publicURL(key: String) -> URL? {
        guard !publicURLPrefix.isEmpty else { return objectURL(key: key) }
        var prefix = publicURLPrefix
        if !prefix.contains("://") { prefix = "https://" + prefix }
        if !prefix.hasSuffix("/") { prefix += "/" }
        return URL(string: prefix + AWSSigV4.uriEncode(key, encodeSlash: false))
    }
}

// MARK: - Object keys

public enum UploadNaming {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")

    public static func randomID(length: Int = 10) -> String {
        var rng = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet.randomElement(using: &rng)! })
    }

    /// URL-friendly file name: letters, digits, '.', '_' and '-' only; runs of anything else become one '-'.
    public static func sanitizedFileName(_ name: String) -> String {
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        func clean(_ s: String) -> String {
            var out = ""
            for ch in s.precomposedStringWithCanonicalMapping {
                if ch.isASCII && (ch.isLetter || ch.isNumber || ch == "." || ch == "_" || ch == "-") {
                    out.append(ch)
                } else if !out.hasSuffix("-") {
                    out.append("-")
                }
            }
            return out.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        }
        let s = clean(stem), e = clean(ext).lowercased()
        let base = s.isEmpty ? "file" : s
        return e.isEmpty ? base : base + "." + e
    }

    /// Normalized folder prefix: no leading slash, exactly one trailing slash (or empty).
    public static func normalizedPrefix(_ prefix: String) -> String {
        let trimmed = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/ ").union(.whitespacesAndNewlines))
        return trimmed.isEmpty ? "" : trimmed + "/"
    }

    /// Synced-folder link: `prefix` + percent-encoded file name, or the file URL itself when no prefix is set.
    public static func folderLink(prefix: String, fileURL: URL) -> URL? {
        guard !prefix.isEmpty else { return fileURL }
        var p = prefix
        if !p.contains("://") { p = "https://" + p }
        if !p.hasSuffix("/") { p += "/" }
        return URL(string: p + AWSSigV4.uriEncode(fileURL.lastPathComponent))
    }

    /// `<prefix><10-char id>/<sanitized file name>`
    public static func objectKey(prefix: String, fileName: String, id: String = randomID()) -> String {
        normalizedPrefix(prefix) + id + "/" + sanitizedFileName(fileName)
    }
}

// MARK: - XML responses

/// Minimal reader for S3 XML responses: root element name + first text value of each element.
public struct S3XMLResponse {
    public private(set) var rootElement: String?
    private var values: [String: String] = [:]

    public init?(_ data: Data) {
        guard !data.isEmpty else { return nil }
        let collector = Collector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        guard parser.parse() else { return nil }
        rootElement = collector.root
        values = collector.values
    }

    public func value(_ element: String) -> String? { values[element] }

    /// `(Code, Message)` when the document is an `<Error>` response.
    public var error: (code: String, message: String)? {
        guard rootElement == "Error" else { return nil }
        return (value("Code") ?? "Error", value("Message") ?? "")
    }

    private final class Collector: NSObject, XMLParserDelegate {
        var root: String?
        var values: [String: String] = [:]
        private var text = ""
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            if root == nil { root = elementName }
            text = ""
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if values[elementName] == nil && !t.isEmpty { values[elementName] = t }
            text = ""
        }
    }

    /// Body of a CompleteMultipartUpload request.
    public static func completeMultipartBody(etags: [String]) -> String {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<CompleteMultipartUpload xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">"
        for (i, etag) in etags.enumerated() {
            xml += "<Part><PartNumber>\(i + 1)</PartNumber><ETag>\(escape(etag))</ETag></Part>"
        }
        return xml + "</CompleteMultipartUpload>"
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

// MARK: - Client

/// S3 REST calls signed with SigV4: single PUT, multipart upload, DELETE.
struct S3Client: Sendable {
    static let multipartThreshold: Int64 = 16 * 1024 * 1024
    static let partSize: Int64 = 8 * 1024 * 1024

    let config: S3Configuration
    var transport: UploadTransport = .shared

    private var signer: AWSSigV4 {
        AWSSigV4(accessKeyID: config.accessKeyID, secretAccessKey: config.secretAccessKey, region: config.region, service: "s3")
    }

    /// Uploads `file` to `key`, choosing single PUT or multipart by size. `progress` gets total bytes sent.
    func upload(file: URL, size: Int64, key: String, contentType: String, progress: @escaping @Sendable (Int64) -> Void) async throws {
        if size > Self.multipartThreshold {
            try await multipartUpload(file: file, size: size, key: key, contentType: contentType, progress: progress)
        } else {
            try await putObject(file: file, key: key, contentType: contentType, progress: progress)
        }
    }

    func putObject(file: URL, key: String, contentType: String, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let url = try objectURL(key)
        // Over HTTPS the body is integrity-protected by TLS, so stream it unsigned; plain HTTP gets a real hash.
        let hash = url.scheme?.lowercased() == "https" ? AWSSigV4.unsignedPayload : try AWSSigV4.sha256Hex(fileAt: file)
        let request = signedRequest("PUT", url, headers: ["Content-Type": contentType], payloadHash: hash)
        try check(await transport.send(request, body: .file(file), progress: progress), stage: "uploading")
    }

    func deleteObject(key: String) async throws {
        let request = signedRequest("DELETE", try objectURL(key), headers: [:], payloadHash: AWSSigV4.emptyPayloadHash)
        try check(await transport.send(request, body: .none), stage: "deleting")
    }

    func multipartUpload(file: URL, size: Int64, key: String, contentType: String,
                         progress: @escaping @Sendable (Int64) -> Void) async throws {
        let base = try objectURL(key).absoluteString
        // 1. CreateMultipartUpload
        let create = signedRequest("POST", URL(string: base + "?uploads")!, headers: ["Content-Type": contentType],
                                   payloadHash: AWSSigV4.emptyPayloadHash)
        let created = try check(await transport.send(create, body: .none), stage: "initiating")
        guard let uploadID = S3XMLResponse(created)?.value("UploadId") else {
            throw UploadError.failed("There was an error while initiating the upload: the storage didn't return an upload ID.")
        }
        let encodedID = AWSSigV4.uriEncode(uploadID)
        do {
            // 2. UploadPart × n
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var etags: [String] = []
            var offset: Int64 = 0
            var partNumber = 1
            while offset < size {
                try Task.checkCancellation()
                try handle.seek(toOffset: UInt64(offset))
                guard let chunk = try handle.read(upToCount: Int(min(Self.partSize, size - offset))), !chunk.isEmpty else { break }
                let url = URL(string: base + "?partNumber=\(partNumber)&uploadId=\(encodedID)")!
                let request = signedRequest("PUT", url, headers: [:], payloadHash: AWSSigV4.sha256Hex(chunk))
                let sentBefore = offset
                let (data, response) = try await transport.send(request, body: .data(chunk)) { progress(sentBefore + $0) }
                _ = try check((data, response), stage: "uploading")
                guard let etag = response.value(forHTTPHeaderField: "ETag"), !etag.isEmpty else {
                    throw UploadError.failed("The storage didn't return an ETag for part \(partNumber). If you use a CDN or proxy, expose the ETag header.")
                }
                Log.upload.debug("[S3MultiPartUpload] part \(partNumber) done")
                etags.append(etag)
                offset += Int64(chunk.count)
                partNumber += 1
            }
            // 3. CompleteMultipartUpload
            let body = Data(S3XMLResponse.completeMultipartBody(etags: etags).utf8)
            let complete = signedRequest("POST", URL(string: base + "?uploadId=\(encodedID)")!,
                                         headers: ["Content-Type": "application/xml"], payloadHash: AWSSigV4.sha256Hex(body))
            _ = try check(await transport.send(complete, body: .data(body)), stage: "completing")
        } catch {
            // AbortMultipartUpload so the storage frees the parts — run detached because this task may be cancelled.
            let abort = signedRequest("DELETE", URL(string: base + "?uploadId=\(encodedID)")!, headers: [:],
                                      payloadHash: AWSSigV4.emptyPayloadHash)
            let transport = self.transport
            Task.detached { _ = try? await transport.send(abort, body: .none) }
            throw error
        }
    }

    // MARK: Helpers

    private func objectURL(_ key: String) throws -> URL {
        guard let url = config.objectURL(key: key) else { throw UploadError.failed("The S3 endpoint isn't a valid URL.") }
        return url
    }

    private func signedRequest(_ method: String, _ url: URL, headers: [String: String], payloadHash: String) -> URLRequest {
        var headers = headers
        headers["x-amz-content-sha256"] = payloadHash
        let signature = signer.sign(method: method, url: url, headers: headers, payloadHash: payloadHash, date: Date())
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (k, v) in headers.merging(signature.headers, uniquingKeysWith: { _, new in new }) {
            request.setValue(v, forHTTPHeaderField: k)
        }
        return request
    }

    /// Throws for non-2xx responses and for `<Error>` documents S3 can return with status 200 (CompleteMultipartUpload).
    @discardableResult
    private func check(_ result: (Data, HTTPURLResponse), stage: String) throws -> Data {
        let (data, response) = result
        let xml = S3XMLResponse(data)
        if !(200..<300).contains(response.statusCode) {
            let detail = xml?.error.map { "\($0.code): \($0.message)" }
            throw UploadTransport.statusError(response, detail: detail)
        }
        if let err = xml?.error {
            throw UploadError.failed("The storage reported an error while \(stage) the file — \(err.code): \(err.message)")
        }
        return data
    }
}
