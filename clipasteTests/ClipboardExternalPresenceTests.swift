import Foundation

@main
struct ClipboardExternalPresenceTests {
    static func main() {
        testSyncFlagsFromNonEmptyBlobs()
        testSyncFlagsFromNilAndEmptyBlobs()
        testPartialUpdateSemantics()
        print("ClipboardExternalPresenceTests: 3 passed")
    }

    private static func testSyncFlagsFromNonEmptyBlobs() {
        let flags = ExternalPresenceFlags.make(
            preview: Data([1]),
            image: nil,
            linkIcon: Data([2]),
            rtf: nil,
            archive: Data([3])
        )
        precondition(flags.hasPreviewImageData)
        precondition(flags.hasOriginalImageData == false)
        precondition(flags.hasLinkIconData)
        precondition(flags.hasRTFData == false)
        precondition(flags.hasRichTextArchiveData)
    }

    private static func testSyncFlagsFromNilAndEmptyBlobs() {
        let flags = ExternalPresenceFlags.make(
            preview: nil,
            image: Data(),
            linkIcon: nil,
            rtf: Data(),
            archive: nil
        )
        precondition(flags.hasPreviewImageData == false)
        precondition(flags.hasOriginalImageData == false)
        precondition(flags.hasLinkIconData == false)
        precondition(flags.hasRTFData == false)
        precondition(flags.hasRichTextArchiveData == false)
    }

    private static func testPartialUpdateSemantics() {
        var flags = ExternalPresenceFlags.make(
            preview: Data([1]),
            image: Data([2]),
            linkIcon: Data([3]),
            rtf: Data([4]),
            archive: Data([5])
        )
        flags.update(
            preview: nil,
            image: Data([9]),
            linkIcon: nil,
            rtf: Data(),
            archive: Data([5])
        )
        precondition(flags.hasPreviewImageData == false)
        precondition(flags.hasOriginalImageData)
        precondition(flags.hasLinkIconData == false)
        precondition(flags.hasRTFData == false)
        precondition(flags.hasRichTextArchiveData)
    }
}
