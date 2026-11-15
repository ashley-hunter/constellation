import Foundation
import Testing
@testable import ConstellationCore

@Suite struct BrowserAddressTests {
    @Test(arguments: [
        ("localhost:5173", "http://localhost:5173"),
        (":3000", "http://localhost:3000"),
        ("127.0.0.1:8080/api", "http://127.0.0.1:8080/api"),
        ("app.localhost", "http://app.localhost"),
        ("example.com/docs", "https://example.com/docs"),
        ("https://sortui.dev", "https://sortui.dev"),
        ("swift actors", "https://duckduckgo.com/?q=swift%20actors"),
    ])
    func readsWhatYouType(text: String, expected: String) {
        #expect(BrowserAddress.url(from: text)?.absoluteString == expected)
    }

    @Test func emptyIsNothing() {
        #expect(BrowserAddress.url(from: "  ") == nil)
    }
}

@Suite struct LocalServerTests {
    @Test func findsTheAddressADevServerPrints() {
        let vite = "  \u{1B}[32m➜\u{1B}[39m  \u{1B}[1mLocal\u{1B}[22m:   \u{1B}[36mhttp://localhost:\u{1B}[1m5173\u{1B}[22m/\u{1B}[39m\r\n"
        #expect(LocalServer.url(in: vite)?.absoluteString == "http://localhost:5173/")
        #expect(LocalServer.url(in: "Listening on http://0.0.0.0:3000.")?.absoluteString == "http://localhost:3000")
        #expect(LocalServer.url(in: "see https://example.com") == nil)
    }
}
