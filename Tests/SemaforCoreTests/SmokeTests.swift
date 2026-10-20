import SemaforCore
import Testing

/// The import of SemaforCore is the actual assertion: the core library links.
@Suite struct SmokeTests {
    @Test func coreLinks() {
        #expect(true)
    }
}
