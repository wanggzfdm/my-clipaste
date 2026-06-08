import SwiftUI
import Foundation

final class AttributedStringCache {
    private struct CacheEntry {
        let attributedString: AttributedString
        let timestamp: Date
    }
    
    private var cache: [String: CacheEntry] = [:]
    private let maxCount: Int
    private let expirationInterval: TimeInterval = 300
    
    private let queue = DispatchQueue(
        label: "com.clipaste.attributedstring.cache",
        attributes: .concurrent
    )
    
    init(maxCount: Int = 1000) {
        self.maxCount = maxCount
    }
    
    func get(key: String) -> AttributedString? {
        queue.sync {
            guard let entry = cache[key] else { return nil }
            if Date().timeIntervalSince(entry.timestamp) > expirationInterval {
                queue.async(flags: .barrier) { self.cache[key] = nil }
                return nil
            }
            return entry.attributedString
        }
    }
    
    func set(key: String, attributedString: AttributedString) {
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            if self.cache.count >= self.maxCount { self.evictOldest() }
            self.cache[key] = CacheEntry(attributedString: attributedString, timestamp: Date())
        }
    }
    
    private func evictOldest() {
        guard let oldestKey = cache.min(by: { $0.value.timestamp < $1.value.timestamp })?.key else { return }
        cache[oldestKey] = nil
    }
    
    var count: Int { queue.sync { cache.count } }
}

let globalAttributedStringCache = AttributedStringCache(maxCount: 2000)

struct HighlightedText: View {
    let text: String
    let highlight: String
    var font: Font = .system(size: 13, weight: .regular)
    var foregroundColor: Color = .primary
    var highlightBackgroundColor: Color = .yellow.opacity(0.8)
    var highlightForegroundColor: Color = .black
    var highlightFont: Font? = nil
    
    private var cacheKey: String {
        "\(text.hashValue)-\(highlight.hashValue)-\(String(describing: font))-\(foregroundColor.hashValue)"
    }

    var body: some View {
        Text(attributedString)
    }

    private var attributedString: AttributedString {
        if let cached = globalAttributedStringCache.get(key: cacheKey) {
            return cached
        }
        let result = computeAttributedString()
        globalAttributedStringCache.set(key: cacheKey, attributedString: result)
        return result
    }
    
    private func computeAttributedString() -> AttributedString {
        var attrString = AttributedString(text)
        attrString.font = font
        attrString.foregroundColor = foregroundColor

        let query = highlight.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return attrString }

        let lowercasedText = text.lowercased()
        var searchRange = lowercasedText.startIndex..<lowercasedText.endIndex
        let emphasizedFont = highlightFont ?? font.bold()

        while let matchRange = lowercasedText.range(of: query, range: searchRange) {
            if let attributedRange = Range(matchRange, in: attrString) {
                attrString[attributedRange].backgroundColor = highlightBackgroundColor
                attrString[attributedRange].foregroundColor = highlightForegroundColor
                attrString[attributedRange].font = emphasizedFont
            }
            searchRange = matchRange.upperBound..<lowercasedText.endIndex
        }
        return attrString
    }
}
