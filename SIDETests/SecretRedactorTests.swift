import XCTest
@testable import Side

final class SecretRedactorTests: XCTestCase {
    private func assertRedacted(_ input: String, keeps: [String] = [], drops: [String], file: StaticString = #filePath, line: UInt = #line) {
        let result = SecretRedactor.redacting(input)
        XCTAssertTrue(result.didRedact, "expected a redaction in: \(input)", file: file, line: line)
        for fragment in drops {
            XCTAssertFalse(result.text.contains(fragment), "leaked \(fragment) in: \(result.text)", file: file, line: line)
        }
        for fragment in keeps {
            XCTAssertTrue(result.text.contains(fragment), "lost context \(fragment) in: \(result.text)", file: file, line: line)
        }
    }

    func testEnvFileAssignmentsKeepTheirNamesAndLoseTheirValues() {
        // The exact case that motivated this: `cat .env` used to land verbatim in the session
        // file and get replayed to the provider on every later message.
        assertRedacted(
            "DATABASE_PASSWORD=hunter2supersecret\nAPI_KEY=abcdef123456\nDEBUG=true",
            keeps: ["DATABASE_PASSWORD=", "API_KEY=", "DEBUG=true"],
            drops: ["hunter2supersecret", "abcdef123456"]
        )
    }

    func testNoFragmentOfTheKeySurvives() {
        // Caught in a live run: `sk_(live|test)_` captured its own alternative and the template
        // wrote it back out as `STRIPE_KEY=live[redacted api key]`. Alternations inside a
        // pattern have to be non-capturing — group 1 is reserved for the prefix to keep.
        let result = SecretRedactor.redacting("STRIPE_KEY=sk_live_AAAAAAAAAAAAAAAAAAAA")
        XCTAssertEqual(result.text, "STRIPE_KEY=[redacted api key]")
        XCTAssertFalse(SecretRedactor.redacted("id AKIAIOSFODNN7EXAMPLE").contains("AKIA"))
    }

    func testProviderKeyShapesAreCaught() {
        assertRedacted("export ANTHROPIC_KEY=sk-ant-api03-AAAAAAAAAAAAAAAAAAAAAA", drops: ["sk-ant-api03-AAAAAAAAAAAAAAAAAAAAAA"])
        assertRedacted("token ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", drops: ["ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"])
        assertRedacted("aws_access_key_id AKIAIOSFODNN7EXAMPLE", drops: ["AKIAIOSFODNN7EXAMPLE"])
        assertRedacted("slack xoxb-123456789012-abcdefghijkl", drops: ["xoxb-123456789012-abcdefghijkl"])
    }

    func testAuthorizationHeaderKeepsItsSchemeAndLosesItsCredential() {
        assertRedacted(
            "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.QQQQQQQQQQQQ",
            keeps: ["Authorization:"],
            drops: ["eyJzdWIiOiIxIn0"]
        )
    }

    func testConnectionStringLosesOnlyThePassword() {
        assertRedacted(
            "postgres://appuser:s3cr3tpassword@db.internal:5432/app",
            keeps: ["postgres://appuser:", "@db.internal:5432/app"],
            drops: ["s3cr3tpassword"]
        )
    }

    func testPrivateKeyBlockIsRemovedEntirely() {
        let pem = """
        -----BEGIN RSA PRIVATE KEY-----
        MIIEowIBAAKCAQEAxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
        yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy
        -----END RSA PRIVATE KEY-----
        """
        assertRedacted(pem, drops: ["MIIEowIBAAKCAQEA", "BEGIN RSA PRIVATE KEY"])
    }

    func testOrdinaryOutputIsLeftExactlyAlone() {
        // False positives are their own kind of damage: a redacted build log or diff is a tool
        // result the model can no longer reason about.
        let samples = [
            "Compiling 42 files\nBuild succeeded in 12.4s",
            "func loadKey() -> String? { keychain.read(\"anthropic\") }",
            "total 24\ndrwxr-xr-x  5 user  staff  160 Aug 25 10:00 src",
            "PATH=/usr/bin:/bin\nHOME=/Users/someone",
        ]
        for sample in samples {
            let result = SecretRedactor.redacting(sample)
            XCTAssertFalse(result.didRedact, "unexpected redaction in: \(sample) → \(result.text)")
            XCTAssertEqual(result.text, sample)
        }
    }

    func testShortAssignmentsAreNotTreatedAsSecrets() {
        // `TOKEN=x` in a test fixture or a doc example isn't a credential, and blanking it
        // would make the output harder to read for no safety gain.
        XCTAssertFalse(SecretRedactor.redacting("TOKEN=abc").didRedact)
    }
}
