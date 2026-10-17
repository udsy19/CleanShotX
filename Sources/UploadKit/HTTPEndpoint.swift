import Foundation
import SuperScreenshotCore

// MARK: - multipart/form-data

/// A single-file `multipart/form-data` body (RFC 7578).
public struct MultipartFormData: Sendable {
    public let boundary: String

    public init(boundary: String = "SuperScreenshotBoundary-" + UUID().uuidString) { self.boundary = boundary }

    public var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    /// Everything before the file bytes.
    public func head(fieldName: String, fileName: String, contentType: String) -> Data {
        var s = "--\(boundary)\r\n"
        s += "Content-Disposition: form-data; name=\"\(Self.quoted(fieldName))\"; filename=\"\(Self.quoted(fileName))\"\r\n"
        s += "Content-Type: \(contentType)\r\n\r\n"
        return Data(s.utf8)
    }

    /// Everything after the file bytes.
    public var tail: Data { Data("\r\n--\(boundary)--\r\n".utf8) }

    public func body(fieldName: String, fileName: String, contentType: String, fileData: Data) -> Data {
        head(fieldName: fieldName, fileName: fileName, contentType: contentType) + fileData + tail
    }

    /// Streams the body to `destination` without loading the whole file into memory.
    public func write(fieldName: String, fileName: String, contentType: String, file: URL, to destination: URL) throws {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let out = try FileHandle(forWritingTo: destination)
        defer { try? out.close() }
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        try out.write(contentsOf: head(fieldName: fieldName, fileName: fileName, contentType: contentType))
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty { try out.write(contentsOf: chunk) }
        try out.write(contentsOf: tail)
    }

    /// Quoted-string parameter value: CR/LF and '"' are percent-encoded, as browsers do.
    static func quoted(_ s: String) -> String {
        s.replacingOccurrences(of: "\r", with: "%0D").replacingOccurrences(of: "\n", with: "%0A")
            .replacingOccurrences(of: "\"", with: "%22")
    }
}

// MARK: - JSON key paths

/// Dot/bracket paths into decoded JSON: `url`, `data.link`, `files[0].url`, `[0].href`, `$.a.b`.
public enum JSONKeyPath {
    enum Component: Equatable { case key(String), index(Int) }

    static func parse(_ path: String) -> [Component]? {
        var p = path.trimmingCharacters(in: .whitespaces)
        if p.hasPrefix("$") { p.removeFirst() }
        var out: [Component] = []
        var key = ""
        var it = Array(p)[...]
        func flushKey() { if !key.isEmpty { out.append(.key(key)); key = "" } }
        while let ch = it.popFirst() {
            switch ch {
            case ".": flushKey()
            case "[":
                flushKey()
                guard let close = it.firstIndex(of: "]"), let n = Int(String(it[it.startIndex..<close])), n >= 0 else { return nil }
                out.append(.index(n))
                it = it[(close + 1)...]
            default: key.append(ch)
            }
        }
        flushKey()
        return out
    }

    /// The value at `path` inside a `JSONSerialization` object, or nil.
    public static func value(at path: String, in json: Any) -> Any? {
        guard let comps = parse(path) else { return nil }
        var cur: Any = json
        for c in comps {
            switch c {
            case .key(let k):
                guard let d = cur as? [String: Any], let v = d[k] else { return nil }
                cur = v
            case .index(let i):
                guard let a = cur as? [Any], a.indices.contains(i) else { return nil }
                cur = a[i]
            }
        }
        return cur
    }

    public static func string(at path: String, inJSON data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return value(at: path, in: json) as? String
    }
}

// MARK: - Response → link

public enum HTTPResponseLink {
    /// Extracts the share link from a custom endpoint's response body: JSON (value at `keyPath`) or a plain-text URL.
    public static func parse(_ data: Data, keyPath: String) -> URL? {
        guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        let candidate: String?
        if text.hasPrefix("{") || text.hasPrefix("[") {
            candidate = JSONKeyPath.string(at: keyPath.isEmpty ? "url" : keyPath, inJSON: data)
        } else if text.hasPrefix("\""), let s = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String {
            candidate = s
        } else {
            candidate = text
        }
        guard let s = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !s.contains(where: \.isWhitespace),
              let url = URL(string: s), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host?.isEmpty == false else { return nil }
        return url
    }
}

// MARK: - Client

struct HTTPEndpointConfiguration: Sendable {
    var endpoint: URL
    var fieldName: String
    var headers: [String: String]
    var responseURLPath: String

    static func current() throws -> HTTPEndpointConfiguration {
        let raw = Defaults[.customHTTPEndpoint].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = validEndpoint(raw) else {
            throw UploadError.failed("The upload endpoint “\(raw)” isn't a valid http(s) URL.")
        }
        let field = Defaults[.customHTTPFieldName].trimmingCharacters(in: .whitespacesAndNewlines)
        return HTTPEndpointConfiguration(endpoint: url, fieldName: field.isEmpty ? "file" : field,
                                         headers: Defaults[.customHTTPHeaders],
                                         responseURLPath: Defaults[.customHTTPResponseURLPath].trimmingCharacters(in: .whitespaces))
    }

    static func validEndpoint(_ raw: String) -> URL? {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host?.isEmpty == false else { return nil }
        return url
    }
}

struct HTTPEndpointClient: Sendable {
    let config: HTTPEndpointConfiguration
    var transport: UploadTransport = .shared

    /// POSTs the file and returns the link found in the response. `progress` gets file bytes sent.
    func upload(file: URL, fileName: String, contentType: String, size: Int64,
                progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        let form = MultipartFormData()
        let bodyURL = AppPaths.temporary.appendingPathComponent("upload-body-\(UUID().uuidString)")
        try form.write(fieldName: config.fieldName, fileName: fileName, contentType: contentType, file: file, to: bodyURL)
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        var request = URLRequest(url: config.endpoint)
        request.httpMethod = "POST"
        for (k, v) in config.headers where !k.trimmingCharacters(in: .whitespaces).isEmpty {
            request.setValue(v, forHTTPHeaderField: k.trimmingCharacters(in: .whitespaces))
        }
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/plain;q=0.9, */*;q=0.5", forHTTPHeaderField: "Accept")

        let (data, response) = try await transport.send(request, body: .file(bodyURL)) { progress(min($0, size)) }
        guard (200..<300).contains(response.statusCode) else {
            let snippet = String(data: data.prefix(300), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw UploadTransport.statusError(response, detail: snippet)
        }
        if let url = HTTPResponseLink.parse(data, keyPath: config.responseURLPath) { return url }
        if let location = response.value(forHTTPHeaderField: "Location"), let url = URL(string: location, relativeTo: config.endpoint)?.absoluteURL {
            return url
        }
        let where_ = config.responseURLPath.isEmpty ? "" : " at “\(config.responseURLPath)”"
        throw UploadError.failed("The upload finished, but the server's response didn't contain a link\(where_).")
    }
}
