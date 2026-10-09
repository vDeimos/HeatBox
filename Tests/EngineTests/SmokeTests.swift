import Testing
@testable import Engine

@Test func engineIdentity() {
    #expect(!Engine.productName.isEmpty)
    #expect(Engine.bundleIdentifier.hasPrefix("local."))
}
