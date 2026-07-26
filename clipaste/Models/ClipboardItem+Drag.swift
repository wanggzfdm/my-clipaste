import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ClipboardDragType {
    static let item = "com.seedpilot.clipboard.item"
    static let group = "com.seedpilot.clipboard.group"
}

extension ClipboardItem {
    var universalDragProvider: NSItemProvider {
        let provider: NSItemProvider
        let plainText = rawText ?? (textPreview.isEmpty ? nil : textPreview)

        // ==========================================
        // 1. 本地文件（⚠️ 必须最高优先级，否则会被纯文本分支拦截）
        // ==========================================
        if contentType == .fileURL, let fileURL = resolvedFileURL {
            provider = NSItemProvider(object: fileURL as NSURL)

        // ==========================================
        // 2. 图片
        // ==========================================
        } else if contentType == .image {
            provider = NSItemProvider()
            let typeIdentifier = imageUTType ?? UTType.png.identifier
            provider.registerDataRepresentation(
                forTypeIdentifier: typeIdentifier,
                visibility: .all
            ) { [id] completion in
                Task {
                    let imageData = await StorageManager.shared.loadImageData(id: id)
                    let previewData = await StorageManager.shared.loadPreviewImageData(id: id)
                    let data = imageData ?? previewData
                    completion(data, nil)
                }
                return nil
            }

        // ==========================================
        // 3. 超链接
        // ==========================================
        } else if isFastLink,
                  let text = plainText,
                  let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            provider = NSItemProvider(object: url as NSURL)
            provider.registerObject(text as NSString, visibility: .all)

        // ==========================================
        // 4. 纯文本
        // ==========================================
        } else if let text = plainText {
            provider = NSItemProvider(object: text as NSString)
        } else {
            provider = NSItemProvider()
        }

        // ==========================================
        // 5. 内部识别码（用于分组拖拽）
        // ==========================================
        provider.registerDataRepresentation(
            forTypeIdentifier: ClipboardDragType.item,
            visibility: .all
        ) { [id] completion in
            completion(id.uuidString.data(using: .utf8), nil)
            return nil
        }

        // 拖到访达/桌面生成文件时的默认文件名。不设置时系统落名「未命名」。
        // 本地文件拖拽(分支 1)保留原始文件名,不覆盖。
        if contentType != .fileURL {
            provider.suggestedName = dragSuggestedFileName
        }

        return provider
    }

    /// 拖拽落盘文件名:自定义标题 > 链接标题 > 正文首行 > 类型默认名。
    /// 给卡片改个标题(右键重命名),拖出去的文件就用这个名字。
    var dragSuggestedFileName: String {
        let candidates: [String?] = [
            trimmedCustomTitle,
            contentType == .image ? nil : linkTitle,
            contentType == .image ? nil : (rawText ?? previewText)
        ]

        for candidate in candidates {
            if let sanitized = Self.sanitizedFileName(from: candidate) {
                return sanitized
            }
        }

        let typeName: String
        switch contentType {
        case .image: typeName = String(localized: "Smart Filter Image")
        case .link: typeName = String(localized: "Smart Filter Link")
        case .code: typeName = String(localized: "Smart Filter Code")
        case .color: typeName = String(localized: "Smart Filter Color")
        case .fileURL, .text: typeName = String(localized: "Smart Filter Text")
        }
        return "\(typeName) \(timestamp.formatted(.dateTime.month().day().hour().minute()))"
    }

    private static func sanitizedFileName(from source: String?) -> String? {
        guard let source else { return nil }

        // 取首行,去掉文件系统敏感字符,限制长度。
        let firstLine = source
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .first ?? ""

        var sanitized = firstLine
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)

        // 纯 URL 落名时去掉协议前缀,避免整串协议字符做文件名。
        for prefix in ["https://", "http://"] where sanitized.lowercased().hasPrefix(prefix) {
            sanitized = String(sanitized.dropFirst(prefix.count))
        }
        sanitized = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "-. "))

        guard sanitized.isEmpty == false else { return nil }

        if sanitized.count > 60 {
            sanitized = String(sanitized.prefix(60)).trimmingCharacters(in: .whitespaces)
        }

        return sanitized
    }
}
