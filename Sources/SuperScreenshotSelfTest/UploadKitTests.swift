import Foundation
import SuperScreenshotCore
import UploadKit

/// Append cases with `SelfTest.cases.append(("name", { check(..., "msg") }))`.
/// Nothing here touches the network or the Keychain: transfers go through `StubURLProtocol`, files live in temp folders.
func registerUploadKitTests() {
    registerUploadKitFaultTests()
    SelfTest.cases.append(("UploadKit.SigV4.signingKey", {
        // AWS docs "Examples of how to derive a signing key for Signature Version 4".
        let key = AWSSigV4.signingKey(secret: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", dateStamp: "20120215",
                                      region: "us-east-1", service: "iam")
        check(AWSSigV4.hex(key) == "f4780e2d9f65fa895f9c67b32ce1baf0b0d8a43505a000a1a9e090d414db404d", "documented signing key")
        check(AWSSigV4.emptyPayloadHash == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "empty SHA-256")
    }))

    SelfTest.cases.append(("UploadKit.SigV4.getVanilla", {
        // AWS SigV4 test suite "get-vanilla" request: canonical form and header layout.
        let signer = AWSSigV4(accessKeyID: "AKIDEXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
                              region: "us-east-1", service: "service")
        let s = signer.sign(method: "GET", url: URL(string: "https://example.amazon.com/")!,
                            headers: ["Host": "example.amazon.com", "X-Amz-Date": "20150830T123600Z"],
                            payloadHash: AWSSigV4.emptyPayloadHash, date: Date())
        let expectedCanonical = "GET\n/\n\nhost:example.amazon.com\nx-amz-date:20150830T123600Z\n\nhost;x-amz-date\n" + AWSSigV4.emptyPayloadHash
        check(s.canonicalRequest == expectedCanonical, "canonical request")
        check(s.stringToSign.hasPrefix("AWS4-HMAC-SHA256\n20150830T123600Z\n20150830/us-east-1/service/aws4_request\n"),
              "string to sign header lines")
        check(s.authorization.hasPrefix("AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=")
              && s.signature.count == 64, "authorization header layout")
        // Signature bytes are pinned by the S3 documentation vectors below.
    }))

    SelfTest.cases.append(("UploadKit.SigV4.s3Examples", {
        // S3 docs "Signature calculation: Transfer payload in a single chunk" examples.
        let signer = AWSSigV4(accessKeyID: "AKIAIOSFODNN7EXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
                              region: "us-east-1", service: "s3")
        let get = signer.sign(method: "GET", url: URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!,
                              headers: ["Range": "bytes=0-9", "x-amz-content-sha256": AWSSigV4.emptyPayloadHash,
                                        "x-amz-date": "20130524T000000Z"],
                              payloadHash: AWSSigV4.emptyPayloadHash, date: Date())
        check(get.signature == "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41", "GET Object signature")

        let payload = AWSSigV4.sha256Hex(Data("Welcome to Amazon S3.".utf8))
        check(payload == "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072", "PUT payload hash")
        let put = signer.sign(method: "PUT", url: URL(string: "https://examplebucket.s3.amazonaws.com/test$file.text")!,
                              headers: ["Date": "Fri, 24 May 2013 00:00:00 GMT", "x-amz-date": "20130524T000000Z",
                                        "x-amz-storage-class": "REDUCED_REDUNDANCY", "x-amz-content-sha256": payload],
                              payloadHash: payload, date: Date())
        check(put.canonicalRequest.hasPrefix("PUT\n/test%24file.text\n\n"), "PUT canonical URI encodes $")
        check(put.signature == "98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd", "PUT Object signature")
    }))

    SelfTest.cases.append(("UploadKit.SigV4.canonicalParts", {
        check(AWSSigV4.canonicalQuery(URL(string: "https://b.s3.amazonaws.com/k?uploads")!) == "uploads=", "valueless query")
        check(AWSSigV4.canonicalQuery(URL(string: "https://h/k?uploadId=a%2Bb~c&partNumber=2")!) == "partNumber=2&uploadId=a%2Bb~c",
              "sorted, re-encoded query")
        check(AWSSigV4.canonicalURI(URL(string: "https://h/dir/a%20b.png")!) == "/dir/a%20b.png", "path encoded once")
        check(AWSSigV4.uriEncode("a b/ü", encodeSlash: false) == "a%20b/%C3%BC", "uriEncode keeps slash on request")
        let (amz, stamp) = AWSSigV4.timestamps(Date(timeIntervalSince1970: 1_440_938_160))
        check(amz == "20150830T123600Z" && stamp == "20150830", "UTC timestamps")
    }))

    SelfTest.cases.append(("UploadKit.S3.urls", {
        let aws = S3Configuration(region: "eu-west-1", bucket: "shots", accessKeyID: "a", secretAccessKey: "s")
        check(aws.objectURL(key: "p/abc/A b.png")?.absoluteString == "https://shots.s3.eu-west-1.amazonaws.com/p/abc/A%20b.png",
              "AWS virtual-hosted")
        let dotted = S3Configuration(bucket: "my.bucket", accessKeyID: "a", secretAccessKey: "s")
        check(dotted.objectURL(key: "k.png")?.absoluteString == "https://s3.us-east-1.amazonaws.com/my.bucket/k.png",
              "dotted bucket falls back to path style")
        let minio = S3Configuration(endpoint: "http://localhost:9000/", region: "us-east-1", bucket: "media", accessKeyID: "a", secretAccessKey: "s")
        check(minio.objectURL(key: "x/y.mp4")?.absoluteString == "http://localhost:9000/media/x/y.mp4", "custom endpoint path style")
        let r2 = S3Configuration(endpoint: "acct.r2.cloudflarestorage.com", region: "auto", bucket: "media", accessKeyID: "a", secretAccessKey: "s")
        check(r2.objectURL(key: "k")?.absoluteString == "https://acct.r2.cloudflarestorage.com/media/k", "scheme-less endpoint gets https")
        let vhost = S3Configuration(endpoint: "https://media.s3.wasabisys.com", bucket: "media", accessKeyID: "a", secretAccessKey: "s")
        check(vhost.usesVirtualHostedStyle && vhost.objectURL(key: "k")?.absoluteString == "https://media.s3.wasabisys.com/k",
              "bucket-prefixed endpoint is virtual-hosted")
        var pub = aws
        pub.publicURLPrefix = "https://cdn.example.com/shots"
        check(pub.publicURL(key: "p/abc/A b.png")?.absoluteString == "https://cdn.example.com/shots/p/abc/A%20b.png", "public prefix + key")
        check(aws.publicURL(key: "k") == aws.objectURL(key: "k"), "no prefix → object URL")
        check(!S3Configuration(bucket: "b", accessKeyID: "a", secretAccessKey: "").isComplete, "missing secret → incomplete")
    }))

    SelfTest.cases.append(("UploadKit.objectKeys", {
        let key = UploadNaming.objectKey(prefix: "/super-screenshot", fileName: "Screenshot 2026-03-07 at 14.05.09.PNG", id: "AbCdE12345")
        check(key == "super-screenshot/AbCdE12345/Screenshot-2026-03-07-at-14.05.09.png", "prefix + id + sanitized name (\(key))")
        check(UploadNaming.objectKey(prefix: "", fileName: "a.mp4", id: "x").hasPrefix("x/"), "empty prefix")
        check(UploadNaming.normalizedPrefix("a/b//") == "a/b/", "prefix normalized")
        let id = UploadNaming.randomID()
        check(id.count == 10 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }, "10-char alphanumeric id")
        check(UploadNaming.randomID() != UploadNaming.randomID(), "ids are random")
        check(UploadNaming.sanitizedFileName("Ärger: “quoted”/file?.gif") == "rger-quoted-file.gif", "unsafe chars collapsed")
        check(UploadNaming.sanitizedFileName("???") == "file", "empty stem fallback")
    }))

    SelfTest.cases.append(("UploadKit.folderLinks", {
        let file = URL(fileURLWithPath: "/Users/me/Dropbox/Shots/Screen Shot #1.png")
        check(UploadNaming.folderLink(prefix: "https://files.example.com/s", fileURL: file)?.absoluteString
              == "https://files.example.com/s/Screen%20Shot%20%231.png", "prefix + encoded name")
        check(UploadNaming.folderLink(prefix: "", fileURL: file) == file, "no prefix → file URL")
    }))

    SelfTest.cases.append(("UploadKit.multipartFormData", {
        let form = MultipartFormData(boundary: "XyZ")
        check(form.contentType == "multipart/form-data; boundary=XyZ", "content type")
        let body = form.body(fieldName: "file", fileName: "a\"b.png", contentType: "image/png", fileData: Data([0x89, 0x50]))
        let expected = Data("--XyZ\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a%22b.png\"\r\nContent-Type: image/png\r\n\r\n".utf8)
            + Data([0x89, 0x50]) + Data("\r\n--XyZ--\r\n".utf8)
        check(body == expected, "body layout")
        // Streamed variant matches the in-memory one.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("superscreenshot-uploadkit-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("in.bin"), out = dir.appendingPathComponent("out.bin")
        try? Data([0x89, 0x50]).write(to: src)
        try? form.write(fieldName: "file", fileName: "a\"b.png", contentType: "image/png", file: src, to: out)
        check((try? Data(contentsOf: out)) == expected, "streamed body")
    }))

    SelfTest.cases.append(("UploadKit.jsonKeyPath", {
        let json = Data(#"{"data":{"link":"https://i.example.com/a.png"},"files":[{"url":"https://f.example.com/1"},{"url":"https://f.example.com/2"}],"n":3}"#.utf8)
        check(JSONKeyPath.string(at: "data.link", inJSON: json) == "https://i.example.com/a.png", "dot path")
        check(JSONKeyPath.string(at: "files[0].url", inJSON: json) == "https://f.example.com/1", "bracket index")
        check(JSONKeyPath.string(at: "$.files[1].url", inJSON: json) == "https://f.example.com/2", "$ prefix")
        check(JSONKeyPath.string(at: "files[5].url", inJSON: json) == nil, "out of range")
        check(JSONKeyPath.string(at: "n", inJSON: json) == nil, "non-string")
        check(JSONKeyPath.string(at: "files[x]", inJSON: json) == nil, "bad index")
        let arr = Data(#"[{"href":"https://a.b/c"}]"#.utf8)
        check(JSONKeyPath.string(at: "[0].href", inJSON: arr) == "https://a.b/c", "root array")
    }))

    SelfTest.cases.append(("UploadKit.responseLink", {
        check(HTTPResponseLink.parse(Data("https://x.example/abc\n".utf8), keyPath: "url")?.absoluteString == "https://x.example/abc", "plain text")
        check(HTTPResponseLink.parse(Data(#"{"data":{"link":"https://x.example/1"}}"#.utf8), keyPath: "data.link")?.absoluteString
              == "https://x.example/1", "JSON path")
        check(HTTPResponseLink.parse(Data(#""https://x.example/q""#.utf8), keyPath: "")?.absoluteString == "https://x.example/q", "JSON string")
        check(HTTPResponseLink.parse(Data("<html>OK</html>".utf8), keyPath: "url") == nil, "HTML is not a link")
        check(HTTPResponseLink.parse(Data(#"{"url":"javascript:alert(1)"}"#.utf8), keyPath: "url") == nil, "non-http scheme rejected")
    }))

    SelfTest.cases.append(("UploadKit.s3XML", {
        let initiate = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <InitiateMultipartUploadResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Bucket>b</Bucket><Key>k</Key>\
        <UploadId>VXBsb2FkIElE.ZWxt-ZW1lbnQ</UploadId></InitiateMultipartUploadResult>
        """.utf8)
        let r = S3XMLResponse(initiate)
        check(r?.value("UploadId") == "VXBsb2FkIElE.ZWxt-ZW1lbnQ" && r?.error == nil, "UploadId")
        let err = S3XMLResponse(Data("<Error><Code>InternalError</Code><Message>We encountered an internal error.</Message></Error>".utf8))
        check(err?.error?.code == "InternalError" && err?.error?.message == "We encountered an internal error.", "Error document")
        let body = S3XMLResponse.completeMultipartBody(etags: ["\"e1\"", "\"e2\""])
        check(body.contains("<Part><PartNumber>1</PartNumber><ETag>&quot;e1&quot;</ETag></Part><Part><PartNumber>2</PartNumber>"),
              "complete body")
        check(S3XMLResponse(Data(body.utf8))?.value("ETag") == "\"e1\"", "complete body round-trips")
    }))

    SelfTest.cases.append(("UploadKit.preparation", {
        check(UploadPreparation.scaledSize(width: 3024, height: 1964, maxWidth: 1512).map { [$0.width, $0.height] } == [1512, 982], "halved")
        check(UploadPreparation.scaledSize(width: 800, height: 600, maxWidth: 1280) == nil, "narrower stays")
        check(UploadPreparation.scaledSize(width: 4000, height: 3000, maxWidth: 0) == nil, "0 = original")
        check(UploadPreparation.contentType(forFileName: "a.png") == "image/png", "png MIME")
        check(UploadPreparation.contentType(forFileName: "a.mp4") == "video/mp4", "mp4 MIME")
        check(UploadPreparation.contentType(forFileName: "a.unknownext") == "application/octet-stream", "fallback MIME")
    }))
}

// MARK: - Fault injection

/// Loopback transport: every request is answered from a script instead of the network. The body stream is
/// drained so streamed uploads can be measured. The last scripted reply repeats.
final class StubURLProtocol: URLProtocol {
    enum Reply {
        case status(Int, headers: [String: String] = [:], body: Data = Data())
        case fail(URLError.Code)
    }
    struct Seen { var method: String; var url: URL; var bodyBytes: Int }

    nonisolated(unsafe) private static var script: [Reply] = []
    nonisolated(unsafe) private static var seen: [Seen] = []
    private static let lock = NSLock()

    static func reset(_ replies: [Reply]) { lock.withLock { script = replies; seen = [] } }
    static var requests: [Seen] { lock.withLock { seen } }

    /// A transport that talks only to this stub, with no pauses between retries unless asked for.
    static func transport(delays: [TimeInterval] = [0, 0, 0]) -> UploadTransport {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return UploadTransport(configuration: config, retryDelays: delays)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var bytes = request.httpBody?.count ?? 0
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 1 << 16)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                bytes += n
            }
            stream.close()
        }
        let reply: Reply = Self.lock.withLock {
            Self.seen.append(Seen(method: request.httpMethod ?? "", url: request.url!, bodyBytes: bytes))
            return Self.script.count > 1 ? Self.script.removeFirst() : (Self.script.first ?? .status(200))
        }
        switch reply {
        case .fail(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .status(let code, let headers, let body):
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!
            if (300..<400).contains(code), let location = headers["Location"].flatMap(URL.init(string:)) {
                client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: location), redirectResponse: response)
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

private final class ByteCounter: @unchecked Sendable { var value: Int64 = 0 }

private func scratchDirectory(_ tag: String) -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("superscreenshot-uploadkit-\(tag)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private let stubURL = URL(string: "http://stub.local/upload")!

func registerUploadKitFaultTests() {
    SelfTest.cases.append(("UploadKit.retryPolicy", {
        func delay(_ e: Error, _ attempt: Int) -> TimeInterval? { UploadRetryPolicy.shouldRetry(error: e, attempt: attempt) }
        let lost = URLError(.networkConnectionLost)
        check(delay(lost, 1) == 1 && delay(lost, 2) == 3 && delay(lost, 3) == 9 && delay(lost, 4) == nil, "1s/3s/9s, then give up")
        for code: URLError.Code in [.timedOut, .dnsLookupFailed, .cannotFindHost, .cannotConnectToHost, .notConnectedToInternet] {
            check(delay(URLError(code), 1) == 1, "\(code) is transient")
        }
        check(delay(URLError(.cancelled), 1) == nil && delay(CancellationError(), 1) == nil, "cancellation never retries")
        check(delay(URLError(.fileDoesNotExist), 1) == nil && delay(URLError(.badURL), 1) == nil, "local errors never retry")
        check(delay(UploadHTTPError(statusCode: 503), 1) == 1 && delay(UploadHTTPError(statusCode: 429), 2) == 3
              && delay(UploadHTTPError(statusCode: 500), 3) == 9, "429/5xx are transient")
        for status in [302, 400, 401, 403, 404, 413] { check(delay(UploadHTTPError(statusCode: status), 1) == nil, "HTTP \(status) never retries") }
        check(delay(UploadError.failed("x"), 1) == nil, "local failures never retry")
        check(delay(lost, 0) == nil, "attempts are numbered from 1")
        check(UploadRetryPolicy.shouldRetry(error: lost, attempt: 1, delays: [0.5]) == 0.5
              && UploadRetryPolicy.shouldRetry(error: lost, attempt: 2, delays: [0.5]) == nil, "custom delays bound the attempts")
    }))

    SelfTest.cases.append(("UploadKit.httpErrorMessages", {
        let auth = UploadHTTPError(statusCode: 403, detail: "SignatureDoesNotMatch: The request signature we calculated does not match")
        check(auth.isAuthFailure && !auth.isTransient, "403 is an auth failure")
        check(auth.localizedDescription.contains("HTTP 403") && auth.localizedDescription.contains("SignatureDoesNotMatch")
              && auth.localizedDescription.contains("Settings → Upload"), "auth message points at Settings (\(auth.localizedDescription))")
        let busy = UploadHTTPError(statusCode: 503)
        check(busy.isTransient && !busy.isAuthFailure && busy.localizedDescription.contains("HTTP 503"), "503 is transient")
        check(UploadHTTPError(statusCode: 302).localizedDescription.contains("sign-in"), "bare redirect hints at a Wi-Fi portal")
        check(!UploadHTTPError(statusCode: 404, detail: "gone").localizedDescription.contains("Settings"), "plain 4xx doesn't blame credentials")
    }))

    SelfTest.cases.append(("UploadKit.transport.retriesTransientThenSucceeds", {
        StubURLProtocol.reset([.fail(.networkConnectionLost), .fail(.timedOut), .status(503), .status(200, body: Data("ok".utf8))])
        let transport = StubURLProtocol.transport()
        let result = blocking { try await transport.send(URLRequest(url: stubURL), body: .data(Data("hi".utf8))) }
        guard case .success(let r) = result else { check(false, "should succeed after retries: \(result)"); return }
        check(r.1.statusCode == 200 && r.0 == Data("ok".utf8), "final response returned")
        let seen = StubURLProtocol.requests
        check(seen.count == 4 && seen.allSatisfy { $0.bodyBytes == 2 }, "three retries, body resent each time (\(seen.count))")
    }))

    SelfTest.cases.append(("UploadKit.transport.givesUpAfterRetries", {
        StubURLProtocol.reset([.status(503, body: Data("busy".utf8))])
        let transport = StubURLProtocol.transport()
        let result = blocking { try await transport.send(URLRequest(url: stubURL), body: .none) }
        guard case .failure(let error) = result, let http = error as? UploadHTTPError else { check(false, "should fail: \(result)"); return }
        check(http.statusCode == 503 && http.detail == "busy", "last 503 surfaces (\(http))")
        check(StubURLProtocol.requests.count == 4, "1 attempt + 3 retries, no more (\(StubURLProtocol.requests.count))")
    }))

    SelfTest.cases.append(("UploadKit.transport.authFailureNoRetry", {
        StubURLProtocol.reset([.status(401, body: Data("bad token".utf8)), .status(200)])
        let transport = StubURLProtocol.transport()
        let result = blocking { try await transport.send(URLRequest(url: stubURL), body: .none) }
        guard case .failure(let error) = result, let http = error as? UploadHTTPError else { check(false, "should fail: \(result)"); return }
        check(http.isAuthFailure && http.localizedDescription.contains("bad token"), "401 explained with the server's words")
        check(StubURLProtocol.requests.count == 1, "no retry storm on 401 (\(StubURLProtocol.requests.count))")
    }))

    SelfTest.cases.append(("UploadKit.transport.redirectIsNotFollowed", {
        StubURLProtocol.reset([.status(302, headers: ["Location": "http://portal.local/login"], body: Data("<html>".utf8)),
                               .status(200, body: Data("<html>Sign in</html>".utf8))])
        let transport = StubURLProtocol.transport()
        let result = blocking { try await transport.send(URLRequest(url: stubURL), body: .data(Data("x".utf8))) }
        guard case .failure(let error) = result, let http = error as? UploadHTTPError else { check(false, "a 302 must not pass as success: \(result)"); return }
        check(http.statusCode == 302 && StubURLProtocol.requests.count == 1, "Wi-Fi portal redirect reported, not followed (\(StubURLProtocol.requests.count))")
    }))

    SelfTest.cases.append(("UploadKit.transport.cancelDuringBackoff", {
        StubURLProtocol.reset([.fail(.networkConnectionLost)])
        let transport = StubURLProtocol.transport(delays: [30, 30, 30])
        let started = Date()
        let result = blocking { () -> Void in
            let task = Task { _ = try await transport.send(URLRequest(url: stubURL), body: .none) }
            try await Task.sleep(nanoseconds: 200_000_000)
            task.cancel()
            try await task.value
        }
        guard case .failure(let error) = result else { check(false, "should be cancelled"); return }
        check(error is CancellationError, "cancel during back-off → CancellationError (\(error))")
        check(Date().timeIntervalSince(started) < 5, "cancel cuts the back-off short")
        check(StubURLProtocol.requests.count == 1, "no further attempt after cancel (\(StubURLProtocol.requests.count))")
    }))

    SelfTest.cases.append(("UploadKit.transport.streamsFileBody", {
        let dir = scratchDirectory("stream")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("big.bin")
        let size = 3 * 1024 * 1024
        try? Data(count: size).write(to: file)
        StubURLProtocol.reset([.status(200)])
        let transport = StubURLProtocol.transport()
        let result = blocking { try await transport.send(URLRequest(url: stubURL), body: .file(file)) }
        guard case .success = result else { check(false, "file upload failed: \(result)"); return }
        check(StubURLProtocol.requests.first?.bodyBytes == size, "whole file streamed from disk (\(StubURLProtocol.requests.first?.bodyBytes ?? -1))")
    }))

    SelfTest.cases.append(("UploadKit.s3.multipartReadsToEOF", {
        let dir = scratchDirectory("multipart")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("big.bin")
        let size = Int(S3Client.multipartThreshold) + 1024
        try? Data(count: size).write(to: file)
        let initiate = Data("<InitiateMultipartUploadResult><Bucket>b</Bucket><Key>k</Key><UploadId>up-1</UploadId></InitiateMultipartUploadResult>".utf8)
        let part = StubURLProtocol.Reply.status(200, headers: ["ETag": "\"e\""])
        let complete = Data("<CompleteMultipartUploadResult><Location>http://stub.local/b/k/big.bin</Location></CompleteMultipartUploadResult>".utf8)
        StubURLProtocol.reset([.status(200, body: initiate), part, part, part, .status(200, body: complete)])
        let transport = StubURLProtocol.transport()
        let client = S3Client(config: S3Configuration(endpoint: "http://stub.local", bucket: "b", accessKeyID: "a", secretAccessKey: "s"),
                              transport: transport)
        // `size` is what preparation measured; the file has grown since (re-saved while queued) and must still go up whole.
        let result = blocking {
            try await client.upload(file: file, size: Int64(size - 512), key: "k/big.bin", contentType: "application/octet-stream") { _ in }
        }
        guard case .success = result else { check(false, "multipart upload failed: \(result)"); return }
        let seen = StubURLProtocol.requests
        check(seen.map(\.method) == ["POST", "PUT", "PUT", "PUT", "POST"], "create, 3 parts, complete (\(seen.map(\.method)))")
        check(seen.filter { $0.method == "PUT" }.map(\.bodyBytes) == [8 << 20, 8 << 20, 1024], "8 MB parts, remainder last")
        check(seen.last?.url.query == "uploadId=up-1" && seen.first?.url.query == "uploads", "upload id threaded through")
    }))

    SelfTest.cases.append(("UploadKit.s3.multipartAbortsOnFailure", {
        let dir = scratchDirectory("abort")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("big.bin")
        let size = Int(S3Client.multipartThreshold) + 1024
        try? Data(count: size).write(to: file)
        let initiate = Data("<InitiateMultipartUploadResult><UploadId>up-2</UploadId></InitiateMultipartUploadResult>".utf8)
        let denied = Data("<Error><Code>AccessDenied</Code><Message>Access Denied</Message></Error>".utf8)
        StubURLProtocol.reset([.status(200, body: initiate), .status(200, headers: ["ETag": "\"e1\""]), .status(403, body: denied), .status(204)])
        let transport = StubURLProtocol.transport()
        let client = S3Client(config: S3Configuration(endpoint: "http://stub.local", bucket: "b", accessKeyID: "a", secretAccessKey: "s"),
                              transport: transport)
        let result = blocking { try await client.upload(file: file, size: Int64(size), key: "k/big.bin", contentType: "application/octet-stream") { _ in } }
        guard case .failure(let error) = result, let http = error as? UploadHTTPError else { check(false, "should fail: \(result)"); return }
        check(http.statusCode == 403 && http.isAuthFailure && http.detail?.contains("AccessDenied") == true, "S3 error document explained (\(http))")
        let deadline = Date(timeIntervalSinceNow: 5)
        while transport.hasBackgroundWork && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        check(!transport.hasBackgroundWork, "abort finished")
        let seen = StubURLProtocol.requests
        check(seen.map(\.method) == ["POST", "PUT", "PUT", "DELETE"], "create, part 1, refused part 2 (no retry), abort (\(seen.map(\.method)))")
        check(seen.last?.url.query == "uploadId=up-2", "abort targets the multipart upload (\(seen.last?.url.query ?? ""))")
    }))

    SelfTest.cases.append(("UploadKit.folder.atomicCopy", {
        let fm = FileManager.default
        let base = scratchDirectory("folder")
        let folder = base.appendingPathComponent("Synced", isDirectory: true)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try? fm.removeItem(at: base)
        }
        let source = base.appendingPathComponent("Shot.png")
        let payload = Data((0..<2_500_000).map { UInt8(truncatingIfNeeded: $0) })
        try? payload.write(to: source)
        let cfg = FolderConfiguration(folder: folder, urlPrefix: "")
        func entries() -> [String] { (try? fm.contentsOfDirectory(atPath: folder.path))?.sorted() ?? [] }

        guard let dest = try? cfg.reserveDestination(fileName: "Shot.png") else { check(false, "reserve"); return }
        check(dest.lastPathComponent == "Shot.png" && fm.fileExists(atPath: folder.path), "folder created, name reserved")
        let sent = ByteCounter()
        do { try cfg.copy(source, to: dest, progress: { sent.value = $0 }) } catch { check(false, "copy failed: \(error)") }
        check((try? Data(contentsOf: dest)) == payload && sent.value == Int64(payload.count), "copied in full with progress")
        check(entries() == ["Shot.png"], "no partial file left behind (\(entries()))")
        check((try? Data(contentsOf: source)) == payload, "source untouched")

        // Re-upload of an edited capture replaces the same file atomically.
        let edited = Data("edited".utf8)
        try? edited.write(to: source)
        do { try cfg.copy(source, to: dest, progress: { _ in }) } catch { check(false, "replace failed: \(error)") }
        check((try? Data(contentsOf: dest)) == edited && entries() == ["Shot.png"], "existing file replaced, no leftovers")
        check((try? cfg.reserveDestination(fileName: "Shot.png"))?.lastPathComponent == "Shot 2.png", "taken name gets a suffix")

        // Missing source: clear failure, nothing written.
        let dest2 = folder.appendingPathComponent("Missing.png")
        do { try cfg.copy(base.appendingPathComponent("gone.png"), to: dest2, progress: { _ in }); check(false, "missing source must fail") } catch {}
        check(entries() == ["Shot.png"], "failed copy leaves no partial file (\(entries()))")

        // Cancelled mid-way: partial removed, destination absent.
        let dest3 = folder.appendingPathComponent("Cancelled.png")
        let task = Task.detached {
            while !Task.isCancelled { await Task.yield() } // start the copy only once the cancel request is in
            try cfg.copy(source, to: dest3, progress: { _ in })
        }
        task.cancel()
        let cancelled = blocking { try await task.value }
        if case .failure(let error) = cancelled { check(error is CancellationError, "cancelled copy reports cancellation (\(error))") }
        else { check(false, "cancelled copy must not succeed") }
        check(entries() == ["Shot.png"], "cancelled copy leaves nothing (\(entries()))")

        // Read-only folder (synced folder without write access, external disk): clear message, nothing written.
        try? fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        let dest4 = folder.appendingPathComponent("Denied.png")
        do {
            try cfg.copy(source, to: dest4, progress: { _ in })
            check(false, "read-only folder must fail")
        } catch {
            check(error.localizedDescription.contains("can't write") && error.localizedDescription.contains("permissions"),
                  "read-only folder explained (\(error.localizedDescription))")
        }
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        check(entries() == ["Shot.png"], "read-only failure leaves nothing (\(entries()))")
        check((try? Data(contentsOf: source)) == edited, "source still untouched after failures")
    }))

    SelfTest.cases.append(("UploadKit.preparation.sourceProblems", {
        let fm = FileManager.default
        let base = scratchDirectory("prepare")
        defer { try? fm.removeItem(at: base) }
        func failure(_ url: URL) -> String? {
            do { _ = try UploadPreparation.prepare(fileURL: url, isImage: true, maxWidth: 0); return nil } catch { return error.localizedDescription }
        }
        check(failure(base.appendingPathComponent("gone.png"))?.contains("no longer exists") == true, "missing file")
        let project = base.appendingPathComponent("Clip.superscreenshot", isDirectory: true)
        try? fm.createDirectory(at: project, withIntermediateDirectories: true)
        check(failure(project)?.contains("Export the video first") == true, "project folder")
        let locked = base.appendingPathComponent("locked.png")
        try? Data([1, 2, 3]).write(to: locked)
        try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        check(failure(locked)?.contains("can't be read") == true, "unreadable file (\(failure(locked) ?? "nil"))")
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path)

        // A down-scaled copy goes to its own temp folder; the capture itself is never touched.
        let wide = base.appendingPathComponent("wide.png")
        guard let ctx = ImageTools.context(width: 3000, height: 100), let image = ctx.makeImage(),
              (try? ImageTools.write(image, to: wide, format: .png)) != nil, let before = try? Data(contentsOf: wide) else { check(false, "fixture"); return }
        do {
            let scaled = try UploadPreparation.prepare(fileURL: wide, isImage: true, maxWidth: 1500)
            guard let temp = scaled.temporaryDirectory else { check(false, "scaled copy needs a temp dir"); return }
            check(scaled.item.fileURL.path.hasPrefix(temp.path) && scaled.item.fileURL != wide, "copy lives in the temp dir")
            check(ImageTools.load(scaled.item.fileURL)?.width == 1500 && scaled.item.size > 0, "scaled to the maximum width")
            check(!temp.path.hasPrefix(base.path), "temp dir is not next to the capture")
            try? fm.removeItem(at: temp)
            let original = try UploadPreparation.prepare(fileURL: wide, isImage: true, maxWidth: 0)
            check(original.temporaryDirectory == nil && original.item.fileURL == wide && original.item.size == Int64(before.count),
                  "unscaled upload uses the capture in place")
        } catch { check(false, "prepare failed: \(error)") }
        check((try? Data(contentsOf: wide)) == before, "capture untouched")
    }))
}
