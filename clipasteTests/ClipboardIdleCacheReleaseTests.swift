import Foundation

/// Documents the idle-release API surface. Full UI cache invalidation is covered
/// by AppKit-backed managers at runtime; this suite locks helper contracts used
/// by the release path.
@main
struct ClipboardIdleCacheReleaseTests {
    static func main() {
        testExternalPresenceEmptyMeansAbsent()
        testPresenceFlagsEquatable()
        print("ClipboardIdleCacheReleaseTests: 2 passed")
    }

    private static func testExternalPresenceEmptyMeansAbsent() {
        precondition(ExternalPresenceFlags.isPresent(nil) == false)
        precondition(ExternalPresenceFlags.isPresent(Data()) == false)
        precondition(ExternalPresenceFlags.isPresent(Data([0xFF])))
    }

    private static func testPresenceFlagsEquatable() {
        let a = ExternalPresenceFlags.make(
            preview: Data([1]),
            image: nil,
            linkIcon: nil,
            rtf: nil,
            archive: nil
        )
        var b = ExternalPresenceFlags()
        b.hasPreviewImageData = true
        precondition(a == b)
        b.hasOriginalImageData = true
        precondition(a != b)
    }
}
