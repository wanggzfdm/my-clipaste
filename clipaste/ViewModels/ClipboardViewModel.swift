import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    static let selectNextGroup = Notification.Name("selectNextGroup")
    static let selectPreviousGroup = Notification.Name("selectPreviousGroup")
    static let focusSearchFieldIntent = Notification.Name("focusSearchFieldIntent")
    static let focusListIntent = Notification.Name("focusListIntent")
    static let toggleFavoriteSelectionIntent = Notification.Name("toggleFavoriteSelectionIntent")
}

/// 统一分组标识：将智能分类和用户分组抹平为同一类型，供游标引擎使用。
/// UI 层绝不感知此枚举，仅 ViewModel 内部消费。
enum UnifiedGroupSlot: Equatable {
    case all
    case smartFilter(ClipboardContentType)
    case builtIn(ClipboardBuiltInGroup)
    case userGroup(String)
}

/// 面板关闭时缓存的当前 scope 首屏，重开时优先恢复，避免分组列表先空后闪。
struct PanelScopeSnapshot {
    let filter: ClipboardContentType?
    let builtInGroup: ClipboardBuiltInGroup?
    let groupID: String?
    let items: [ClipboardItem]
    let displayedIDs: [UUID]
}

extension UserDefaults {
    @objc dynamic var enable_smart_groups: Bool {
        bool(forKey: "enable_smart_groups")
    }
}

@MainActor
final class ClipboardViewModel: ObservableObject {
    enum DataLoadMode {
        case visibleFirst
        case fullRefresh
    }

    /// 首屏 / 续页统一 page size（真·按需分页，不再后台 while 扫全库）。
    static let historyPageSize = 64
    static let initialVisibleItemBatchSize = historyPageSize
    static let backgroundPageBatchSize = historyPageSize
    /// 距列表尾部多少条内触发 loadMore。
    static let loadMorePrefetchDistance = 8
    /// 打开态内存软上限：超出则丢掉最旧且未保护的条目，保持 DB offset 游标。
    static let openStateItemSoftCap = 480
    /// 首屏物化窗口：超过此数量时先提交窗口，再分帧补齐，避免切到「全部」时主线程一次拷贝上千 struct。
    static let displayMaterializeWindowSize = 100
    static let displayMaterializeChunkSize = 200

    struct QuickLookImagePreviewState {
        let image: NSImage
        let targetSize: CGSize
    }

    @Published var items: [ClipboardItem] = []
    @Published var displayedItemIDs: [UUID] = []
    /// Materialised view of `displayedItemIDs` for scroll/render hot paths.
    @Published var displayedItems: [ClipboardItem] = []
    @Published var searchInput: String = ""
    @Published var isSearchCompositionActive: Bool = false
    @Published var activeSearchQuery: String = ""
    @Published var searchResultScrollGeneration: UInt = 0
    @Published var searchResultScrollTargetID: UUID? = nil
    @Published var currentFilter: ClipboardContentType? = nil
    @Published var selectedBuiltInGroup: ClipboardBuiltInGroup? = nil
    @Published var selectedItemIDs: Set<UUID> = []
    @Published var listScrollRequest: ClipboardListScrollRequest? = nil
    @Published var isInitialHistoryLoading = false
    @Published var isLoadingMoreHistory = false
    /// 分组/范围切换时置位：横向 LazyHStack 强制无动画重建，避免右→左飞入。
    @Published var suppressListAnimations = false
    /// 每次 scope 切换递增；列表用 `.id(listContentEpoch)` 整树重建而非 cell 插入动画。
    @Published var listContentEpoch: UInt = 0
    var lastSelectedID: UUID? = nil
    @Published var quickLookItem: ClipboardItem? = nil
    /// 非 @Published:滚动时每帧被所有可见卡片写入,发布会引发全卡片级联重绘;
    /// 仅 QuickLook 窗口定位时按需读取,无 SwiftUI body 依赖。
    var quickLookAnchorFramesByItemID: [UUID: CGRect] = [:]
    @Published var forceQuickLookTranslate: Bool = false
    @Published var quickLookTranslationOverrideText: String? = nil
    @Published var operationNotice: String? = nil
    @Published var highResImage: NSImage? = nil
    @Published var previewTargetSize: CGSize = .zero
    @Published var sharingItem: ClipboardItem? = nil
    @Published var draggedItemId: UUID? = nil
    @Published var groups: [ClipboardGroup] = []
    @Published var selectedGroupID: UUID? = nil
    @Published var customGroups: [ClipboardGroupItem] = []
    @Published var selectedGroupId: String? = nil
    @Published var draggedGroup: ClipboardGroupItem? = nil
    @Published var titleEditorItem: ClipboardItem? = nil
    @Published var quickPasteModifier: ModifierKey = ModifierKey.quickPastePreference()
    @Published var plainTextModifier: ModifierKey = ModifierKey.plainTextPreference()
    @Published var isQuickPasteModifierHeld: Bool = false
    @Published var isPlainTextModifierHeld: Bool = false
    @AppStorage("enable_smart_groups") var isSmartGroupsEnabled: Bool = true
    @AppStorage("pasteTextFormat") var pasteTextFormat: PasteTextFormat = .original
    var panelFocusField: ClipboardPanelFocusField? = nil

    // Shared implementation state for the split partial ViewModel files.
    var cancellables: Set<AnyCancellable> = []
    var filterGeneration: UInt = 0
    var handledSearchResultScrollGeneration: UInt = 0
    var lastSearchResultScrollQuery: String = ""
    var listScrollGeneration: UInt = 0
    var quickLookLoadTask: Task<Void, Never>? = nil
    var quickLookLoadGeneration: UInt = 0
    var quickLookRequestedItemID: UUID? = nil
    var autoPreviewTask: Task<Void, Never>? = nil
    var autoPreviewDismissTask: Task<Void, Never>? = nil
    var autoPreviewPendingItemID: UUID? = nil
    var autoPreviewPresentedItemID: UUID? = nil
    nonisolated(unsafe) var keyDownMonitor: Any?
    nonisolated(unsafe) var flagsChangedMonitor: Any?
    var currentModifierFlags: NSEvent.ModifierFlags = []
    var shouldResetSelectionToFirstDisplayedItem = false
    var hasPreparedPanelData = false
    var isPanelPresentationActive = false
    var needsReloadOnNextPresentation = false
    var dataLoadGeneration: UInt = 0
    var loadedHistoryCount = 0
    var hasLoadedFullHistory = false
    var historyLoadTask: Task<Void, Never>? = nil
    /// Suppresses intermediate filter/UI churn while background pages merge.
    var isBulkHistoryLoading = false
    /// 真·按需分页游标（打开态不自动灌满全库）。
    var pagination = HistoryPaginationState(pageSize: historyPageSize)
    var itemIndexByID: [UUID: Int] = [:]
    var itemIndexByHash: [String: Int] = [:]
    var pendingLinkMetadataHashes: Set<String> = []
    /// record 变更通知的合并缓冲(见 setupRecordChangeSubscriptions)。
    var pendingRecordChangesByHash: [String: ClipboardRecordChange] = [:]
    var pendingRecordChangeFlushTask: Task<Void, Never>? = nil
    var operationNoticeHideTask: Task<Void, Never>? = nil
    var suppressedPasteItemIDs: Set<UUID> = []
    /// When true, passive list mutations (optimistic capture / DB reconcile) suppress SwiftUI animations.
    var isSilentPresentationMutation = false
    var silentPresentationEndTask: Task<Void, Never>? = nil
    /// activateDisplayedScope 已同步刷新时，吞掉 Combine pipeline 的同一次回声。
    var suppressFilterPipelineEcho = false
    /// 分帧物化 generation，避免过期补齐覆盖新的 scope。
    var displayMaterializeGeneration: UInt = 0
    var displayMaterializeTask: Task<Void, Never>? = nil
    var scopeSwitchAnimationSuppressTask: Task<Void, Never>? = nil
    /// 关面板时保留的当前 scope 首屏，重开分组时避免空白。
    var lastScopeSnapshot: PanelScopeSnapshot? = nil
    let settingsViewModel: SettingsViewModel
    let aiSettingsViewModel: AISettingsViewModel

    init(
        clipboardMonitor _: ClipboardMonitor? = nil,
        settingsViewModel: SettingsViewModel? = nil,
        aiSettingsViewModel: AISettingsViewModel? = nil
    ) {
        self.settingsViewModel = settingsViewModel ?? SettingsViewModel.shared
        self.aiSettingsViewModel = aiSettingsViewModel ?? AISettingsViewModel.shared
        ModifierKey.migrateStoredPreferences()

        self.groups = [
            ClipboardGroup(id: UUID(), name: "链接", iconName: "link")
        ]

        setupDataSubscriptions()
        setupRecordChangeSubscriptions()
        setupWarmCacheSubscription()
        setupFilterPipeline()
        setupGroupSwitchSubscriptions()
        setupKeyboardIntentSubscriptions()
        setupSmartGroupsGuard()
        setupModifierPreferenceSync()
        hydrateFromWarmCacheIfAvailable()
    }

    func updateQuickLookAnchorFrame(itemID: UUID, frame: CGRect) {
        guard frame.isNull == false, frame.isEmpty == false else { return }
        if quickLookAnchorFramesByItemID[itemID] != frame {
            quickLookAnchorFramesByItemID[itemID] = frame
        }
    }

    func removeQuickLookAnchorFrame(itemID: UUID) {
        quickLookAnchorFramesByItemID[itemID] = nil
    }

    func quickLookAnchorFrame(for itemID: UUID) -> CGRect? {
        quickLookAnchorFramesByItemID[itemID]
    }

    deinit {
        operationNoticeHideTask?.cancel()
        silentPresentationEndTask?.cancel()
        displayMaterializeTask?.cancel()
        autoPreviewTask?.cancel()
        pendingRecordChangeFlushTask?.cancel()
        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
        }
        if let flagsChangedMonitor {
            NSEvent.removeMonitor(flagsChangedMonitor)
        }
        historyLoadTask?.cancel()
    }
}
