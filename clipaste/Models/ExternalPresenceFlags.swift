import Foundation

/// Lightweight presence flags for externalStorage blobs.
/// List/snapshot paths must read these instead of touching blob properties.
struct ExternalPresenceFlags: Equatable, Sendable {
    var hasPreviewImageData = false
    var hasOriginalImageData = false
    var hasLinkIconData = false
    var hasRTFData = false
    var hasRichTextArchiveData = false

    mutating func update(
        preview: Data?,
        image: Data?,
        linkIcon: Data?,
        rtf: Data?,
        archive: Data?
    ) {
        hasPreviewImageData = Self.isPresent(preview)
        hasOriginalImageData = Self.isPresent(image)
        hasLinkIconData = Self.isPresent(linkIcon)
        hasRTFData = Self.isPresent(rtf)
        hasRichTextArchiveData = Self.isPresent(archive)
    }

    static func isPresent(_ data: Data?) -> Bool {
        guard let data else { return false }
        return data.isEmpty == false
    }

    static func make(
        preview: Data?,
        image: Data?,
        linkIcon: Data?,
        rtf: Data?,
        archive: Data?
    ) -> ExternalPresenceFlags {
        var flags = ExternalPresenceFlags()
        flags.update(
            preview: preview,
            image: image,
            linkIcon: linkIcon,
            rtf: rtf,
            archive: archive
        )
        return flags
    }
}
