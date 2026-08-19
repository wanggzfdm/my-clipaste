import Foundation

extension ClipboardRecord {
    func apply(_ flags: ExternalPresenceFlags) {
        hasPreviewImageData = flags.hasPreviewImageData
        hasOriginalImageData = flags.hasOriginalImageData
        hasLinkIconData = flags.hasLinkIconData
        hasRTFData = flags.hasRTFData
        hasRichTextArchiveData = flags.hasRichTextArchiveData
    }

    /// Backfill/debug only: recomputes flags from blobs (faults external storage in).
    func resyncExternalPresenceFlagsFromBlobs() {
        apply(
            ExternalPresenceFlags.make(
                preview: previewImageData,
                image: imageData,
                linkIcon: linkIconData,
                rtf: rtfData,
                archive: richTextArchiveData
            )
        )
    }

    func setPreviewImageDataKeepingPresence(_ data: Data?) {
        previewImageData = data
        hasPreviewImageData = ExternalPresenceFlags.isPresent(data)
    }

    func setOriginalImageDataKeepingPresence(_ data: Data?) {
        imageData = data
        hasOriginalImageData = ExternalPresenceFlags.isPresent(data)
    }

    func setLinkIconDataKeepingPresence(_ data: Data?) {
        linkIconData = data
        hasLinkIconData = ExternalPresenceFlags.isPresent(data)
    }

    func setRTFDataKeepingPresence(_ data: Data?) {
        rtfData = data
        hasRTFData = ExternalPresenceFlags.isPresent(data)
    }

    func setRichTextArchiveDataKeepingPresence(_ data: Data?) {
        richTextArchiveData = data
        hasRichTextArchiveData = ExternalPresenceFlags.isPresent(data)
    }
}
