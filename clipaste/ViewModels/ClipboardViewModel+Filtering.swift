import AppKit
import Combine
import SwiftUI

extension ClipboardViewModel {
    var isSearchFilteringActive: Bool {
        !searchInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !activeSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func setupFilterPipeline() {
        let searchQueries = $searchInput
            .map { query -> AnyPublisher<String, Never> in
                let isEffectivelyEmpty = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

                if isEffectivelyEmpty {
                    return Just(query)
                        .eraseToAnyPublisher()
                }

                return Just(query)
                    .delay(for: .milliseconds(200), scheduler: DispatchQueue.main)
                    .eraseToAnyPublisher()
            }
            .switchToLatest()
            .removeDuplicates()

        let settingsChanges = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .prepend(Notification(name: UserDefaults.didChangeNotification))
            .debounce(for: .milliseconds(120), scheduler: DispatchQueue.main)

        let dataChanges = Publishers.CombineLatest4($items, $selectedGroupId, $currentFilter, $selectedBuiltInGroup)

        Publishers.CombineLatest3(searchQueries, dataChanges, settingsChanges)
            .sink { [weak self] (query, quadruple, _) in
                guard let self else { return }
                let (allItems, groupId, filter, builtInGroup) = quadruple
                self.activeSearchQuery = query
                self.performAsyncFilter(
                    query: query,
                    items: allItems,
                    groupId: groupId,
                    typeFilter: filter,
                    builtInGroup: builtInGroup
                )
            }
            .store(in: &cancellables)
    }

    func performAsyncFilter(
        query: String,
        items: [ClipboardItem],
        groupId: String?,
        typeFilter: ClipboardContentType?,
        builtInGroup: ClipboardBuiltInGroup?
    ) {
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

        filterGeneration &+= 1
        let thisGeneration = filterGeneration

        if cleanQuery.isEmpty && groupId == nil && typeFilter == nil && builtInGroup == nil {
            obsidianSearchItems = []
            self.displayedItemIDs = items.map(\.id)
            reconcileSelectionAfterDisplayedItemsChange()
            return
        }

        let shouldSearchObsidian = settingsViewModel.obsidianSearchEnabled
            && settingsViewModel.obsidianVaultPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            && cleanQuery.isEmpty == false
            && groupId == nil
            && builtInGroup == nil
            && (typeFilter == nil || typeFilter == .text)
        let vaultPath = settingsViewModel.obsidianVaultPath

        DispatchQueue.global(qos: .userInitiated).async {
            let filteredIDs = items.compactMap { item -> UUID? in
                if let filter = typeFilter, item.contentType != filter {
                    return nil
                }

                if let gid = groupId, item.groupIDs.contains(gid) == false {
                    return nil
                }

                if let builtInGroup, builtInGroup.matches(item) == false {
                    return nil
                }

                if !cleanQuery.isEmpty {
                    let searchable = item.searchableText ?? item.rawText ?? item.textPreview
                    let matchesText = searchable.range(of: cleanQuery, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                    let matchesApp = item.appName.range(of: cleanQuery, options: [.caseInsensitive]) != nil

                    guard matchesText || matchesApp else {
                        return nil
                    }
                }

                return item.id
            }

            let obsidianItems = shouldSearchObsidian
                ? ObsidianVaultSearchService.shared.search(vaultPath: vaultPath, query: cleanQuery)
                : []
            let mergedIDs = filteredIDs + obsidianItems.map(\.id)

            DispatchQueue.main.async { [weak self] in
                guard let self, self.filterGeneration == thisGeneration else { return }
                self.obsidianSearchItems = obsidianItems
                self.displayedItemIDs = mergedIDs
                self.reconcileSelectionAfterDisplayedItemsChange()
            }
        }
    }

    func loadData(mode: DataLoadMode = .fullRefresh) {
        dataLoadGeneration &+= 1
        let generation = dataLoadGeneration
        historyLoadTask?.cancel()

        if items.isEmpty {
            isInitialHistoryLoading = true
        }

        // 读路径的优先级反转由 StorageManager.detachedRead 统一兜底,
        // 这里保持普通 MainActor Task 即可。
        historyLoadTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            let firstPage = await StorageManager.shared.fetchItemsPage(
                searchText: "",
                fetchLimit: Self.initialVisibleItemBatchSize,
                offset: 0
            )

            guard !Task.isCancelled else { return }
            self.applyInitialHistoryPage(
                firstPage,
                generation: generation,
                mode: mode
            )

            guard firstPage.count == Self.initialVisibleItemBatchSize else {
                self.finishHistoryLoadingIfCurrent(generation: generation, loadedCount: firstPage.count)
                return
            }

            var offset = firstPage.count
            var totalLoaded = firstPage.count

            while !Task.isCancelled {
                let page = await StorageManager.shared.fetchItemsPage(
                    searchText: "",
                    fetchLimit: Self.backgroundPageBatchSize,
                    offset: offset
                )

                guard !Task.isCancelled else { return }

                if page.isEmpty {
                    self.finishHistoryLoadingIfCurrent(generation: generation, loadedCount: totalLoaded)
                    return
                }

                totalLoaded += page.count
                offset += page.count
                self.appendHistoryPage(page, generation: generation, loadedCount: totalLoaded)

                if page.count < Self.backgroundPageBatchSize {
                    self.finishHistoryLoadingIfCurrent(generation: generation, loadedCount: totalLoaded)
                    return
                }
            }
        }
    }

    func applyLoadedItems(_ mappedItems: [ClipboardItem]) {
        replaceItems(mappedItems)
        isInitialHistoryLoading = false

        // Always use the filter pipeline to set displayedItemIDs to ensure
        // consistent behavior. The filter pipeline will set displayedItemIDs
        // based on the current activeSearchQuery (which may be debounced).
        // This ensures search state is preserved when loading new items.

        let validIDs = Set(mappedItems.map(\.id))
        let staleIDs = selectedItemIDs.subtracting(validIDs)
        if !staleIDs.isEmpty {
            selectedItemIDs.subtract(staleIDs)
        }
        if let anchor = lastSelectedID, !validIDs.contains(anchor) {
            lastSelectedID = nil
        }

        reconcileSelectionAfterDisplayedItemsChange()
    }

    @MainActor
    func applyInitialHistoryPage(_ pageItems: [ClipboardItem], generation: UInt, mode: DataLoadMode) {
        guard generation == dataLoadGeneration else { return }

        if mode == .visibleFirst, items.isEmpty == false {
            mergeItems(pageItems, prepend: true)
            refreshDisplayedItemsFromCurrentScope()
            reconcileSelectionAfterDisplayedItemsChange()
        } else {
            applyLoadedItems(pageItems)
        }

        isInitialHistoryLoading = false
        isLoadingMoreHistory = pageItems.count == Self.initialVisibleItemBatchSize
        loadedHistoryCount = items.count
        hasLoadedFullHistory = pageItems.count < Self.initialVisibleItemBatchSize
    }

    @MainActor
    func appendHistoryPage(_ pageItems: [ClipboardItem], generation: UInt, loadedCount: Int) {
        guard generation == dataLoadGeneration else { return }

        mergeItems(pageItems, prepend: false)
        refreshDisplayedItemsFromCurrentScope()
        isInitialHistoryLoading = false
        isLoadingMoreHistory = true
        loadedHistoryCount = loadedCount
    }

    @MainActor
    func finishHistoryLoadingIfCurrent(generation: UInt, loadedCount: Int) {
        guard generation == dataLoadGeneration else { return }
        isInitialHistoryLoading = false
        isLoadingMoreHistory = false
        loadedHistoryCount = loadedCount
        hasLoadedFullHistory = true
    }
}

private final class ObsidianVaultSearchService {
    static let shared = ObsidianVaultSearchService()

    private let fileManager = FileManager.default
    private let maxResults = 24
    private let maxReadableBytes = 512_000
    private let skippedDirectoryNames: Set<String> = [
        ".git",
        ".obsidian",
        ".trash",
        ".sync",
        "node_modules"
    ]

    private init() {}

    func search(vaultPath: String, query: String) -> [ClipboardItem] {
        let vaultURL = URL(fileURLWithPath: vaultPath, isDirectory: true)
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanQuery.isEmpty,
              fileManager.fileExists(atPath: vaultURL.path) else {
            return []
        }

        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = fileManager.enumerator(
            at: vaultURL,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants]
        ) else {
            return []
        }

        var results: [ClipboardItem] = []
        results.reserveCapacity(maxResults)

        for case let noteURL as URL in enumerator {
            if shouldSkip(url: noteURL, enumerator: enumerator) {
                continue
            }

            guard noteURL.pathExtension.caseInsensitiveCompare("md") == .orderedSame,
                  isReadableMarkdownFile(noteURL) else {
                continue
            }

            guard let noteText = try? String(contentsOf: noteURL, encoding: .utf8),
                  let match = makeMatch(for: noteURL, vaultURL: vaultURL, noteText: noteText, query: cleanQuery) else {
                continue
            }

            results.append(makeClipboardItem(from: match))

            if results.count >= maxResults {
                break
            }
        }

        return results
    }

    private func shouldSkip(url: URL, enumerator: FileManager.DirectoryEnumerator) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
              values.isDirectory == true else {
            return false
        }

        if skippedDirectoryNames.contains(url.lastPathComponent) || url.lastPathComponent.hasPrefix(".") {
            enumerator.skipDescendants()
            return true
        }

        return false
    }

    private func isReadableMarkdownFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true else {
            return false
        }

        return (values.fileSize ?? 0) <= maxReadableBytes
    }

    private func makeMatch(for noteURL: URL, vaultURL: URL, noteText: String, query: String) -> ObsidianNoteMatch? {
        let relativePath = relativePath(for: noteURL, in: vaultURL)
        let title = noteURL.deletingPathExtension().lastPathComponent
        let searchOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let searchableHeader = "\(title)\n\(relativePath)"

        let snippet: String
        if title.range(of: query, options: searchOptions) != nil ||
            relativePath.range(of: query, options: searchOptions) != nil {
            snippet = firstUsefulLine(from: noteText) ?? relativePath
        } else if let range = noteText.range(of: query, options: searchOptions) {
            snippet = snippetAround(range: range, in: noteText)
        } else if searchableHeader.range(of: query, options: searchOptions) != nil {
            snippet = firstUsefulLine(from: noteText) ?? relativePath
        } else {
            return nil
        }

        return ObsidianNoteMatch(
            vaultName: vaultURL.lastPathComponent,
            vaultPath: vaultURL.path,
            filePath: noteURL.path,
            relativePath: relativePath,
            title: title,
            snippet: snippet,
            fullText: noteText,
            modificationDate: (try? noteURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        )
    }

    private func relativePath(for noteURL: URL, in vaultURL: URL) -> String {
        let vaultPath = vaultURL.standardizedFileURL.path
        let notePath = noteURL.standardizedFileURL.path
        guard notePath.hasPrefix(vaultPath) else {
            return noteURL.lastPathComponent
        }

        return String(notePath.dropFirst(vaultPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func firstUsefulLine(from text: String) -> String? {
        text.split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && !$0.hasPrefix("---") && !$0.hasPrefix("# ") }
    }

    private func snippetAround(range: Range<String.Index>, in text: String) -> String {
        let lower = text.index(range.lowerBound, offsetBy: -90, limitedBy: text.startIndex) ?? text.startIndex
        let upper = text.index(range.upperBound, offsetBy: 180, limitedBy: text.endIndex) ?? text.endIndex
        return text[lower..<upper]
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeClipboardItem(from match: ObsidianNoteMatch) -> ClipboardItem {
        let textPreview = "\(match.title)\n\(match.snippet)"
        return ClipboardItem(
            id: UUID(),
            contentType: .text,
            contentHash: "obsidian:\(match.filePath)",
            textPreview: textPreview,
            searchableText: "\(match.title)\n\(match.relativePath)\n\(match.fullText)",
            sourceBundleIdentifier: ClipboardItem.obsidianSourceBundleIdentifier,
            appName: "Obsidian",
            appIconName: "note.text",
            timestamp: match.modificationDate,
            rawText: match.fullText,
            fileURL: match.filePath,
            customTitle: match.title,
            captureMethodRawValue: "obsidian-search"
        )
    }
}

private struct ObsidianNoteMatch {
    let vaultName: String
    let vaultPath: String
    let filePath: String
    let relativePath: String
    let title: String
    let snippet: String
    let fullText: String
    let modificationDate: Date
}
