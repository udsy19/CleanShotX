import Foundation
import ShotcraftCore
import UploadKit

/// Append cases with `SelfTest.cases.append(("name", { check(..., "msg") }))`.
/// Pure logic only — nothing here touches the network or the Keychain.
func registerUploadKitTests() {
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
        let key = UploadNaming.objectKey(prefix: "/shotcraft", fileName: "Screenshot 2026-03-07 at 14.05.09.PNG", id: "AbCdE12345")
        check(key == "shotcraft/AbCdE12345/Screenshot-2026-03-07-at-14.05.09.png", "prefix + id + sanitized name (\(key))")
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
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shotcraft-uploadkit-test-\(UUID().uuidString)")
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
