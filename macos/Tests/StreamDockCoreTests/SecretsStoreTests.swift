import Foundation
import XCTest
@testable import StreamDockCore

final class SecretsStoreTests: XCTestCase {
    private func makeStore() -> (store: SecretsStore, url: URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("secrets.dat")
        let store = SecretsStore(
            fileURL: url,
            keyProvider: StaticSecretsKeyProvider(seed: "unit-test-key")
        )
        return (store, url)
    }

    func testEncryptedRoundTripAndFileIsNotPlaintext() throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try store.save([
            SecretItem(name: "HA_TOKEN", value: "super-secret-value"),
            SecretItem(name: "API_KEY", value: "abc123"),
        ])

        let blob = try Data(contentsOf: url)
        let asText = String(decoding: blob, as: UTF8.self)
        XCTAssertFalse(asText.contains("super-secret-value"), "value must be encrypted at rest")
        XCTAssertFalse(asText.contains("HA_TOKEN"), "name must be encrypted at rest")

        let reopened = SecretsStore(
            fileURL: url,
            keyProvider: StaticSecretsKeyProvider(seed: "unit-test-key")
        )
        let loaded = try reopened.load()
        XCTAssertEqual(loaded.map(\.name), ["HA_TOKEN", "API_KEY"])
        XCTAssertEqual(loaded.map(\.value), ["super-secret-value", "abc123"])
        XCTAssertEqual(reopened.environment(), ["HA_TOKEN": "super-secret-value", "API_KEY": "abc123"])
    }

    func testWrongKeyFailsToDecrypt() throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try store.save([SecretItem(name: "X", value: "y")])

        let other = SecretsStore(
            fileURL: url,
            keyProvider: StaticSecretsKeyProvider(seed: "a-different-key")
        )
        XCTAssertThrowsError(try other.load()) { error in
            XCTAssertEqual(error as? SecretsError, SecretsError.decryptionFailed)
        }
        XCTAssertEqual(other.environment(), [:])
    }

    func testNormalizeTrimsCollapsesAndDropsBlanks() throws {
        let (store, _) = makeStore()
        let normalized = store.normalized([
            SecretItem(name: "  A ", value: "1"),
            SecretItem(name: "", value: "ignored"),
            SecretItem(name: "A", value: "2"),
            SecretItem(name: "B", value: "3"),
        ])
        XCTAssertEqual(normalized.map(\.name), ["A", "B"])
        XCTAssertEqual(normalized.first(where: { $0.name == "A" })?.value, "2")
    }

    func testParseEnvFileHandlesExportsQuotesAndComments() {
        let text = """
        # comment
        export HA_TOKEN="a b c"
        API_KEY='quoted'
        PLAIN=value
        BAD LINE WITHOUT EQUALS
        """
        let items = SecretsStore.parseEnvFile(text)
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].name, "HA_TOKEN")
        XCTAssertEqual(items[0].value, "a b c")
        XCTAssertEqual(items[1].value, "quoted")
        XCTAssertEqual(items[2].value, "value")
    }

    func testEnvFileTextRoundTripsThroughParser() {
        let (store, _) = makeStore()
        let original = [
            SecretItem(name: "HA_TOKEN", value: "has spaces and $pecial"),
            SecretItem(name: "SIMPLE", value: "plain"),
        ]
        let text = store.envFileText(for: original)
        let parsed = SecretsStore.parseEnvFile(text)
        XCTAssertEqual(parsed.map(\.name), ["HA_TOKEN", "SIMPLE"])
        XCTAssertEqual(parsed.map(\.value), ["has spaces and $pecial", "plain"])
    }
}

extension SecretsError: Equatable {
    public static func == (lhs: SecretsError, rhs: SecretsError) -> Bool {
        switch (lhs, rhs) {
        case (.decryptionFailed, .decryptionFailed),
             (.encodingFailed, .encodingFailed):
            return true
        case let (.keychain(a), .keychain(b)):
            return a == b
        default:
            return false
        }
    }
}
