import FSCore
import XCTest
@testable import Remote

final class SigV4Tests: XCTestCase {
    let suiteCreds = AWSCredentials(accessKeyID: "AKIDEXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY")
    let s3Creds = AWSCredentials(accessKeyID: "AKIAIOSFODNN7EXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")

    func date(_ s: String) -> Date { SigV4Signer.amzDateFormatter.date(from: s)! }

    func testDerivedSigningKeyMatchesAWSDocumentation() {
        let signer = SigV4Signer(region: "us-east-1", service: "iam")
        let key = signer.signingKey(secret: suiteCreds.secretAccessKey, dateStamp: "20150830")
        XCTAssertEqual(key.withUnsafeBytes { FileDigest.hex($0) }, "c4afb1cc5771d871763a393e44b703571b55cc28424d1a5e86da6ed3c154a4b9")
    }

    func testSuiteGetVanilla() {
        let signer = SigV4Signer(region: "us-east-1", service: "service")
        let canonical = signer.canonicalRequest(method: "GET", encodedPath: "/", query: [], headers: ["Host": "example.amazonaws.com", "X-Amz-Date": "20150830T123600Z"], payloadHash: SigV4Signer.emptyPayloadHash)
        XCTAssertEqual(canonical.request, "GET\n/\n\nhost:example.amazonaws.com\nx-amz-date:20150830T123600Z\n\nhost;x-amz-date\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        let sts = signer.stringToSign(canonicalRequest: canonical.request, amzDate: "20150830T123600Z")
        XCTAssertEqual(sts, "AWS4-HMAC-SHA256\n20150830T123600Z\n20150830/us-east-1/service/aws4_request\nbb579772317eb040ac9ed261061d46c1f17a8133879d6129b6e1c25292927e63")
        XCTAssertEqual(signer.signature(stringToSign: sts, secret: suiteCreds.secretAccessKey, dateStamp: "20150830"), "5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31")
    }

    func testSuiteRequestSigningEndToEnd() {
        var req = URLRequest(url: URL(string: "https://example.amazonaws.com/")!)
        req.httpMethod = "GET"
        let signer = SigV4Signer(region: "us-east-1", service: "service", addsContentSHA256Header: false)
        signer.sign(&req, credentials: suiteCreds, payloadHash: SigV4Signer.emptyPayloadHash, date: date("20150830T123600Z"))
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31")
    }

    func testIAMListUsersExample() {
        var req = URLRequest(url: URL(string: "https://iam.amazonaws.com/?Action=ListUsers&Version=2010-05-08")!)
        req.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        let signer = SigV4Signer(region: "us-east-1", service: "iam")
        let canonical = signer.canonicalRequest(method: "GET", encodedPath: "/", query: [("Action", "ListUsers"), ("Version", "2010-05-08")],
                                                headers: ["Content-Type": "application/x-www-form-urlencoded; charset=utf-8", "Host": "iam.amazonaws.com", "X-Amz-Date": "20150830T123600Z"],
                                                payloadHash: SigV4Signer.emptyPayloadHash)
        XCTAssertEqual(FileDigest.sha256Hex(Data(canonical.request.utf8)), "f536975d06c0309214f805bb90ccff089219ecd68b2577efef23edd43b7e1a59")
        let sts = signer.stringToSign(canonicalRequest: canonical.request, amzDate: "20150830T123600Z")
        XCTAssertEqual(signer.signature(stringToSign: sts, secret: suiteCreds.secretAccessKey, dateStamp: "20150830"), "5d672d79c15b13162d9279b0855cfba6789a8edb4c82c400e06b5924a6f2b5d7")
        signer.sign(&req, credentials: suiteCreds, payloadHash: SigV4Signer.emptyPayloadHash, date: date("20150830T123600Z"))
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/iam/aws4_request, SignedHeaders=content-type;host;x-amz-date, Signature=5d672d79c15b13162d9279b0855cfba6789a8edb4c82c400e06b5924a6f2b5d7")
    }

    func testS3GetObjectWithRangeExample() {
        var req = URLRequest(url: URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!)
        req.setValue("bytes=0-9", forHTTPHeaderField: "Range")
        SigV4Signer(region: "us-east-1").sign(&req, credentials: s3Creds, payloadHash: SigV4Signer.emptyPayloadHash, date: date("20130524T000000Z"))
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
    }

    func testS3PutObjectExample() {
        let body = Data("Welcome to Amazon S3.".utf8)
        var req = URLRequest(url: URL(string: "https://examplebucket.s3.amazonaws.com/test%24file.text")!)
        req.httpMethod = "PUT"
        req.setValue("Fri, 24 May 2013 00:00:00 GMT", forHTTPHeaderField: "Date")
        req.setValue("REDUCED_REDUNDANCY", forHTTPHeaderField: "x-amz-storage-class")
        req.httpBody = body
        XCTAssertEqual(FileDigest.sha256Hex(body), "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072")
        SigV4Signer(region: "us-east-1").sign(&req, credentials: s3Creds, payloadHash: FileDigest.sha256Hex(body), date: date("20130524T000000Z"))
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, SignedHeaders=date;host;x-amz-content-sha256;x-amz-date;x-amz-storage-class, Signature=98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd")
    }

    func testS3GetBucketLifecycleExample() {
        var req = URLRequest(url: URL(string: "https://examplebucket.s3.amazonaws.com/?lifecycle")!)
        SigV4Signer(region: "us-east-1").sign(&req, credentials: s3Creds, payloadHash: SigV4Signer.emptyPayloadHash, date: date("20130524T000000Z"))
        XCTAssertTrue(req.value(forHTTPHeaderField: "Authorization")!.hasSuffix("Signature=fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543"))
    }

    func testS3ListObjectsExample() {
        var req = URLRequest(url: URL(string: "https://examplebucket.s3.amazonaws.com/?max-keys=2&prefix=J")!)
        SigV4Signer(region: "us-east-1").sign(&req, credentials: s3Creds, payloadHash: SigV4Signer.emptyPayloadHash, date: date("20130524T000000Z"))
        XCTAssertTrue(req.value(forHTTPHeaderField: "Authorization")!.hasSuffix("Signature=34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7"))
    }

    func testURIEncodingRules() {
        XCTAssertEqual(SigV4Signer.uriEncode("a b+c/d~e", encodeSlash: false), "a%20b%2Bc/d~e")
        XCTAssertEqual(SigV4Signer.uriEncode("a/b"), "a%2Fb")
        XCTAssertEqual(SigV4Signer.uriEncode("é"), "%C3%A9")
        XCTAssertEqual(SigV4Signer.canonicalQuery([("b", "2"), ("a", "z"), ("a", "y"), ("uploads", "")]), "a=y&a=z&b=2&uploads=")
    }

    func testSessionTokenIsSignedWhenPresent() {
        var req = URLRequest(url: URL(string: "https://bucket.s3.amazonaws.com/k")!)
        let creds = AWSCredentials(accessKeyID: "AK", secretAccessKey: "SK", sessionToken: "TOKEN")
        SigV4Signer(region: "us-east-1").sign(&req, credentials: creds, payloadHash: SigV4Signer.emptyPayloadHash)
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-amz-security-token"), "TOKEN")
        XCTAssertTrue(req.value(forHTTPHeaderField: "Authorization")!.contains("x-amz-security-token"))
    }
}
