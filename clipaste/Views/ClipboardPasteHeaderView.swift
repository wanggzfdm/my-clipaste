import SwiftUI
import UniformTypeIdentifiers

struct ClipboardPasteHeaderView: View {
    private enum HorizontalSearchLayout {
        static let fieldHeight: CGFloat = 28
        static let collapsedWidth: CGFloat = fieldHeight
        static let expandedWidth: CGFloat = 240
        static let horizontalPadding: CGFloat = 12
        static let contentSpacing: CGFloat = 8
        /// Search chrome ↔ favorites/group bar spacing (collapsed and expanded share this value).
        static let groupBarSpacing: CGFloat = 6
    }

    @ObservedObject var viewModel: ClipboardViewModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var preferencesStore: AppPreferencesStore
    @FocusState var focusedField: ClipboardPanelFocusField?
    @AppStorage("clipboardLayout") private var clipboardLayout: AppLayoutMode = .horizontal
    @AppStorage("appLanguage") private var appLanguage: AppLanguage = .auto
    @AppStorage("appAccentColor") private var appAccentColor: AppAccentColor = .defaultValue
    @AppStorage("isPanelPinned") private var isPanelPinned: Bool = false
    @AppStorage("isMonitoringPaused") private var isMonitoringPaused: Bool = false
    @AppStorage("monitorInterval") private var monitorInterval: Double = 0.5
    @State private var isShowingNewGroupPopover = false
    @StateObject private var newGroupEditor = GroupEditorViewModel(mode: .create)
    @State private var targetedGroupId: String? = nil
    @State private var targetedBuiltInGroup: ClipboardBuiltInGroup? = nil
    @State private var groupTabFrames: [String: CGRect] = [:]
    @State private var scrollableGroupTabsContentWidth: CGFloat = 0
    @State private var reorderTarget: GroupReorderTarget? = nil
    @State private var isShowingGroupOverflowPopover = false
    @State private var isShowingAIModelPopover = false
    @State private var isAIModelSubmenuHovered = false
    @State private var aiSettingsViewModel = AISettingsViewModel.shared
    /// Local chrome expand state — kept separate from `@FocusState` so layout
    /// animation does not run inside the focus transaction. Group-bar AppKit
    /// content still disables animation interpolation via `.transaction`.
    @State private var isSearchChromeExpanded = false

    // MARK: - 重命名 / 删除分组弹窗控制
    @State private var groupToEdit: ClipboardGroupItem? = nil
    @StateObject private var editGroupEditor = GroupEditorViewModel(mode: .edit)
    @State private var showEditPopover = false
    @State private var groupToDelete: ClipboardGroupItem? = nil
    @State private var showDeleteAlert = false

    /// 剪贴板面板上的 Popover 在独立窗口中呈现，往往拿不到根视图的 `\.locale`，需与 `ClipboardPanelRootView` 一致显式注入。
    private var panelLocale: Locale {
        appLanguage.resolvedLocale
    }

    private var isVerticalLayout: Bool {
        clipboardLayout == .vertical || clipboardLayout == .compact
    }

    private var groupBarSpacing: CGFloat {
        isVerticalLayout ? 2 : 4
    }

    private var groupTabHorizontalPadding: CGFloat {
        isVerticalLayout ? 9 : 12
    }

    private var groupTabVerticalPadding: CGFloat {
        isVerticalLayout ? 4 : 5
    }

    private var groupTabIconSpacing: CGFloat {
        isVerticalLayout ? 4 : 5
    }

    var body: some View {
        Group {
            if isVerticalLayout {
                verticalHeader
            } else {
                horizontalHeader
            }
        }
        .padding(.bottom, isVerticalLayout ? (isCompactMode ? 4 : 8) : 0)
        .background(headerBackground)
        .popover(isPresented: $showEditPopover, arrowEdge: .bottom) {
            editGroupPopover
                .environment(\.locale, panelLocale)
        }
        .onChange(of: isShowingNewGroupPopover) { _, isShowing in
            updatePopoverInputState(isShowing: isShowing)
        }
        .onChange(of: showEditPopover) { _, isShowing in
            updatePopoverInputState(isShowing: isShowing)
            if isShowing == false {
                groupToEdit = nil
            }
        }
        .onAppear {
            preferencesStore.refreshLaunchAtLoginStatus()
        }
        .alert("Delete Group", isPresented: $showDeleteAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                if let group = groupToDelete {
                    viewModel.deleteGroup(group: group)
                }
            }
        } message: {
            Text("The group's clipboard records will safely return to \"All\".")
        }
        .onChange(of: showDeleteAlert) { _, isShowing in
            ClipboardPanelManager.shared.suppressHide = isShowing
        }
    }

    @ViewBuilder
    private var headerBackground: some View {
        if isVerticalLayout {
            WindowDragArea()
                .background(.regularMaterial)
        } else {
            Color.clear
        }
    }

    // MARK: - 竖版模式：双行布局
    private var verticalHeader: some View {
        VStack(spacing: isCompactMode ? 4 : 10) {
            // 第一行：固定按钮 + 搜索框 + 设置菜单
            searchBarContent

            // 第二行：混合分组导航栏（占满全部宽度）- 紧凑模式下隐藏
            if clipboardLayout != .compact {
                hybridGroupBar()
            }
        }
        .padding(.horizontal, isCompactMode ? 4 : 14)
        .padding(.top, isCompactMode ? 4 : 14)
        .padding(.bottom, isCompactMode ? 0 : 2)
    }

    private var isCompactMode: Bool {
        clipboardLayout == .compact
    }

    // MARK: - 横版模式：单行紧凑布局
    private var horizontalHeader: some View {
        HStack(spacing: 0) {
            horizontalLeadingControls

            Spacer(minLength: 20)

            HStack(spacing: HorizontalSearchLayout.groupBarSpacing) {
                horizontalSearchBar

                horizontalHybridGroupBar
                    .layoutPriority(1)
                    // Search width animates; do not interpolate AppKit-hosted tab frames.
                    .transaction { $0.disablesAnimations = true }
            }

            Spacer(minLength: 20)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var hasHorizontalScrollableGroupTabs: Bool {
        !viewModel.customGroups.isEmpty || !viewModel.visibleSmartFilters.isEmpty || !viewModel.visibleBuiltInGroups.isEmpty
    }

    private var horizontalScrollableGroupTabsWidth: CGFloat {
        let customGroupWidth = CGFloat(viewModel.customGroups.count) * 72
        let smartFilterWidth = CGFloat(viewModel.visibleSmartFilters.count) * 70
        let builtInGroupWidth = CGFloat(viewModel.visibleBuiltInGroups.count) * 76
        let customAndBuiltInDividerWidth: CGFloat =
            (!viewModel.customGroups.isEmpty && !viewModel.visibleBuiltInGroups.isEmpty) ? 14 : 0
        let builtInAndSmartDividerWidth: CGFloat =
            (!viewModel.visibleBuiltInGroups.isEmpty && !viewModel.visibleSmartFilters.isEmpty) ? 14 : 0

        let estimatedWidth = customGroupWidth
            + builtInGroupWidth
            + smartFilterWidth
            + customAndBuiltInDividerWidth
            + builtInAndSmartDividerWidth
        let measuredWidth = scrollableGroupTabsContentWidth > 0
            ? scrollableGroupTabsContentWidth
            : estimatedWidth

        return min(680, measuredWidth)
    }

    private var horizontalLeadingControls: some View {
        HStack(spacing: 0) {
            pinButton
        }
        .frame(width: 28, alignment: .leading)
    }

    private var hasActiveSearchChromeContent: Bool {
        viewModel.isSearchCompositionActive
            || !viewModel.searchInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isHorizontalSearchExpanded: Bool {
        isSearchChromeExpanded
            || focusedField == .searchBar
            || hasActiveSearchChromeContent
    }

    /// Layout and visual width share one value so collapse leaves no empty slot
    /// between the search chrome and the favorites/group bar.
    private var horizontalSearchChromeWidth: CGFloat {
        isHorizontalSearchExpanded
            ? HorizontalSearchLayout.expandedWidth
            : HorizontalSearchLayout.collapsedWidth
    }

    private var searchExpandAnimation: Animation {
        .easeOut(duration: 0.18)
    }

    private var horizontalSearchBar: some View {
        HStack(spacing: 0) {
            Button(action: activateHorizontalSearch) {
                horizontalSearchIcon
                    .frame(
                        width: HorizontalSearchLayout.fieldHeight,
                        height: HorizontalSearchLayout.fieldHeight
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: HorizontalSearchLayout.contentSpacing) {
                horizontalSearchTextField
                horizontalSearchClearButton
            }
            .padding(.leading, 4)
            .padding(.trailing, HorizontalSearchLayout.horizontalPadding)
            // Text area stays at expanded width; outer frame + clip reveal it.
            .frame(
                width: HorizontalSearchLayout.expandedWidth - HorizontalSearchLayout.fieldHeight,
                alignment: .leading
            )
            .opacity(isHorizontalSearchExpanded ? 1 : 0)
            .allowsHitTesting(isHorizontalSearchExpanded)
        }
        .frame(height: HorizontalSearchLayout.fieldHeight)
        .frame(width: horizontalSearchChromeWidth, alignment: .leading)
        .background(Color.clear.background(.regularMaterial))
        .overlay {
            Capsule()
                .strokeBorder(isHorizontalSearchExpanded ? searchFieldFocusColor : .clear, lineWidth: 1)
        }
        .clipShape(Capsule())
        .contentShape(Capsule())
        .shadow(color: searchFieldShadowColor, radius: 4, y: 2)
        .animation(searchExpandAnimation, value: isHorizontalSearchExpanded)
        .compositingGroup()
        .contentShape(Rectangle())
        .onTapGesture {
            if !isHorizontalSearchExpanded {
                activateHorizontalSearch()
            }
        }
        .onChange(of: focusedField) { _, newValue in
            syncSearchChromeWithFocus(newValue)
        }
        .help(isHorizontalSearchExpanded ? Text("搜索历史") : Text("搜索"))
    }

    private var horizontalSearchIcon: some View {
        Image(systemName: "magnifyingglass")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
    }

    private var horizontalSearchTextField: some View {
        TextField("Search History…", text: searchTextBinding)
            .font(.system(size: 13))
            .textFieldStyle(.plain)
            .autocorrectionDisabled(true)
#if os(macOS)
            .textContentType(.none)
#endif
            .tint(appAccentColor.color)
            .focused($focusedField, equals: .searchBar)
    }

    @ViewBuilder
    private var horizontalSearchClearButton: some View {
        if !viewModel.searchInput.isEmpty {
            Button(action: clearHorizontalSearchInput) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    private func activateHorizontalSearch() {
        withAnimation(searchExpandAnimation) {
            isSearchChromeExpanded = true
        }
        // Focus is applied after the layout animation starts so `@FocusState`
        // does not pull the entire header/list into the same transaction.
        DispatchQueue.main.async {
            focusedField = .searchBar
        }
    }

    private func clearHorizontalSearchInput() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            viewModel.searchInput = ""
        }
    }

    private func syncSearchChromeWithFocus(_ newValue: ClipboardPanelFocusField?) {
        if newValue == .searchBar {
            if isSearchChromeExpanded == false {
                withAnimation(searchExpandAnimation) {
                    isSearchChromeExpanded = true
                }
            }
            return
        }

        guard hasActiveSearchChromeContent == false else { return }
        guard isSearchChromeExpanded else { return }
        withAnimation(searchExpandAnimation) {
            isSearchChromeExpanded = false
        }
    }

    private var horizontalHybridGroupBar: some View {
        HStack(spacing: 4) {
            allGroupTabButton

            if hasHorizontalScrollableGroupTabs {
                FreeScrollWheelView {
                    scrollableGroupTabsStrip
                }
                .frame(width: horizontalScrollableGroupTabsWidth, alignment: .leading)
            }

            Divider()
                .frame(height: 14)
                .opacity(0.5)

            groupOverflowMenu
        }
    }

    // MARK: - 核心组件：单行融合导航栏
    // 固定区域：[全部] … [溢出菜单 ⋯]
    // 可滚动区域：[智能分类…] │ [自定义分组…]
    private var allGroupTabButton: some View {
        MinimalGroupTabButton(
            title: .localized(LocalizedStringResource("All")),
            icon: "tray.2.fill",
            isSelected: viewModel.isAllScopeSelected,
            horizontalPadding: groupTabHorizontalPadding,
            verticalPadding: groupTabVerticalPadding,
            iconSpacing: groupTabIconSpacing
        ) {
            selectAllGroup()
        }
    }

    private var scrollableGroupTabsStrip: some View {
        HStack(spacing: groupBarSpacing) {
            scrollableGroupTabsContent
        }
        .padding(.horizontal, isVerticalLayout ? 1 : 2)
        .fixedSize(horizontal: true, vertical: false)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .preference(
                        key: GroupTabsContentWidthPreferenceKey.self,
                        value: proxy.size.width
                    )
            }
        }
        .coordinateSpace(.named(GroupBarDropSpace.name))
        .onPreferenceChange(GroupTabFramePreferenceKey.self) { frames in
            groupTabFrames = frames
        }
        .onPreferenceChange(GroupTabsContentWidthPreferenceKey.self) { width in
            scrollableGroupTabsContentWidth = width
        }
        .onDrop(
            of: [ClipboardDragType.group],
            delegate: GroupBarDropDelegate(
                orderedGroupIDs: viewModel.customGroups.map(\.id),
                groupFrames: groupTabFrames,
                reorderTarget: $reorderTarget,
                viewModel: viewModel
            )
        )
    }

    @ViewBuilder
    private var scrollableGroupTabsContent: some View {
        ForEach(viewModel.customGroups) { group in
            groupTabButton(group: group)
        }

        if !viewModel.customGroups.isEmpty && !viewModel.visibleBuiltInGroups.isEmpty {
            Divider()
                .frame(height: 16)
                .opacity(0.5)
        }

        ForEach(viewModel.visibleBuiltInGroups, id: \.self) { group in
            builtInGroupTabButton(group)
        }

        if !viewModel.visibleBuiltInGroups.isEmpty && !viewModel.visibleSmartFilters.isEmpty {
            Divider()
                .frame(height: 16)
                .opacity(0.5)
        }

        ForEach(viewModel.visibleSmartFilters, id: \.self) { type in
            MinimalGroupTabButton(
                title: .localized(type.localizedFilterTitle),
                icon: type.systemImage,
                isSelected: viewModel.isSmartFilterSelected(type),
                horizontalPadding: groupTabHorizontalPadding,
                verticalPadding: groupTabVerticalPadding,
                iconSpacing: groupTabIconSpacing
            ) {
                selectSmartFilter(type)
            }
        }
    }

    private var groupOverflowMenu: some View {
        Button {
            isShowingGroupOverflowPopover = true
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: 24)
        .help("所有分组")
        .popover(isPresented: $isShowingGroupOverflowPopover, arrowEdge: .bottom) {
            groupOverflowPopover
                .environment(\.locale, panelLocale)
        }
        .popover(isPresented: $isShowingNewGroupPopover, arrowEdge: .bottom) {
            newGroupPopover
                .environment(\.locale, panelLocale)
        }
    }

    private var groupOverflowPopover: some View {
        VStack(alignment: .leading, spacing: 4) {
            GroupOverflowSectionTitle("Built-in Groups")

            GroupOverflowRow(
                title: .localized(LocalizedStringResource("All")),
                icon: "tray.2.fill",
                isSelected: viewModel.isAllScopeSelected,
                accentColor: appAccentColor
            ) {
                performGroupOverflowAction(selectAllGroup)
            }

            if !viewModel.customGroups.isEmpty {
                Divider()
                    .padding(.vertical, 3)

                GroupOverflowSectionTitle("Groups")

                ForEach(viewModel.customGroups) { group in
                    GroupOverflowRow(
                        title: .verbatim(group.name),
                        icon: group.systemIconName,
                        isSelected: viewModel.isCustomGroupSelected(group.id),
                        accentColor: appAccentColor
                    ) {
                        performGroupOverflowAction {
                            selectCustomGroup(group.id)
                        }
                    }
                }
            }

            ForEach(viewModel.visibleBuiltInGroups, id: \.self) { group in
                GroupOverflowRow(
                    title: .localized(group.localizedTitle),
                    icon: group.systemImage,
                    isSelected: viewModel.isBuiltInGroupSelected(group),
                    accentColor: appAccentColor
                ) {
                    performGroupOverflowAction {
                        selectBuiltInGroup(group)
                    }
                }
            }

            ForEach(viewModel.visibleSmartFilters, id: \.self) { type in
                GroupOverflowRow(
                    title: .localized(type.localizedFilterTitle),
                    icon: type.systemImage,
                    isSelected: viewModel.isSmartFilterSelected(type),
                    accentColor: appAccentColor
                ) {
                    performGroupOverflowAction {
                        selectSmartFilter(type)
                    }
                }
            }

            if aiSettingsViewModel.isAIEnabled {
                Divider()
                    .padding(.vertical, 3)

                aiModelSubmenu
            }

            Divider()
                .padding(.vertical, 3)

            GroupOverflowRow(
                title: .localized(LocalizedStringResource("New Group…")),
                icon: "plus",
                isSelected: false,
                accentColor: appAccentColor
            ) {
                isShowingGroupOverflowPopover = false
                newGroupEditor.prepareForCreate()
                DispatchQueue.main.async {
                    isShowingNewGroupPopover = true
                }
            }

            Divider()
                .padding(.vertical, 3)

            GroupOverflowRow(
                title: .localized(LocalizedStringResource("Settings…")),
                icon: "gearshape",
                isSelected: false,
                accentColor: appAccentColor
            ) {
                isShowingAIModelPopover = false
                isShowingGroupOverflowPopover = false
                SettingsWindowCoordinator.open {
                    openSettings()
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .frame(width: 164)
    }

    private var aiModelSubmenu: some View {
        Button {
            isShowingAIModelPopover.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .regular))
                    .frame(width: 14, height: 14)

                (Text(verbatim: "AI") + Text(" ") + Text(LocalizedStringKey("Model")))
                    .font(.system(size: 14))
                    .lineLimit(1)

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isAIModelSubmenuHighlighted ? appAccentColor.selectedContentColor : Color.secondary)
            }
            .foregroundStyle(isAIModelSubmenuHighlighted ? appAccentColor.selectedContentColor : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isAIModelSubmenuHighlighted ? appAccentColor.color : Color.clear)
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isAIModelSubmenuHovered = hovering
        }
        .popover(isPresented: $isShowingAIModelPopover, arrowEdge: .trailing) {
            aiModelPopover
                .environment(\.locale, panelLocale)
        }
    }

    private var isAIModelSubmenuHighlighted: Bool {
        isAIModelSubmenuHovered || isShowingAIModelPopover
    }

    private var aiModelPopover: some View {
        VStack(alignment: .leading, spacing: 4) {
            if aiSettingsViewModel.configurations.isEmpty {
                GroupOverflowRow(
                    title: .localized(LocalizedStringResource("Open AI Settings…")),
                    icon: "gearshape",
                    isSelected: false,
                    accentColor: appAccentColor
                ) {
                    isShowingAIModelPopover = false
                    isShowingGroupOverflowPopover = false
                    NotificationCenter.default.post(name: .openSettingsIntent, object: nil)
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(aiSettingsViewModel.configurations) { config in
                            AIModelOverflowRow(
                                configuration: config,
                                isSelected: aiSettingsViewModel.activeConfigurationID == config.id,
                                accentColor: appAccentColor
                            ) {
                                aiSettingsViewModel.setActive(config)
                                isShowingAIModelPopover = false
                                isShowingGroupOverflowPopover = false
                            }
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .frame(width: 220)
    }

    private func performGroupOverflowAction(_ action: () -> Void) {
        action()
        isShowingGroupOverflowPopover = false
    }

    @ViewBuilder
    private func hybridGroupBar() -> some View {
        HStack(spacing: groupBarSpacing) {
            allGroupTabButton

            if hasHorizontalScrollableGroupTabs {
                // “全部”固定在左侧，其余分组在独立滚动区域内横向滚动。
                FreeScrollWheelView {
                    scrollableGroupTabsStrip
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer(minLength: 0)
            }

            Divider()
                .frame(height: 14)
                .opacity(0.5)

            // ── 固定：溢出菜单 ⋯ ─────────────────────────────────
            groupOverflowMenu
        }
    }

    // MARK: - 单个分组 Tab 按钮（支持拖拽 & 右键管理）
    @ViewBuilder
    private func builtInGroupTabButton(_ group: ClipboardBuiltInGroup) -> some View {
        let isSelected = viewModel.isBuiltInGroupSelected(group)
        let isDropTarget = targetedBuiltInGroup == group

        MinimalGroupTabButton(
            title: .localized(group.localizedTitle),
            icon: group.systemImage,
            isSelected: isSelected || isDropTarget,
            horizontalPadding: groupTabHorizontalPadding,
            verticalPadding: groupTabVerticalPadding,
            iconSpacing: groupTabIconSpacing
        ) {
            selectBuiltInGroup(group)
        }
        .help(Text(group.localizedTitle))
        .onDrop(
            of: [
                ClipboardDragType.item,
                UTType.image.identifier,
                UTType.fileURL.identifier
            ],
            isTargeted: Binding(
                get: { targetedBuiltInGroup == group },
                set: { isTargeted in
                    withAnimation(.easeOut(duration: 0.08)) {
                        targetedBuiltInGroup = isTargeted ? group : nil
                    }
                }
            )
        ) { providers in
            handleItemDrop(providers: providers) { draggedItem in
                viewModel.addItemToBuiltInGroup(item: draggedItem, group: group)
            }
        }
    }

    @ViewBuilder
    private func groupTabButton(group: ClipboardGroupItem) -> some View {
        let isSelected = viewModel.isCustomGroupSelected(group.id)
        let isDropTarget = targetedGroupId == group.id
        let insertionEdge = reorderTarget?.groupID == group.id ? reorderTarget?.edge : nil

        MinimalGroupTabButton(
            title: .verbatim(group.name),
            icon: group.systemIconName,
            isSelected: isSelected || isDropTarget,
            maxTextWidth: isVerticalLayout ? 60 : 80,
            horizontalPadding: groupTabHorizontalPadding,
            verticalPadding: groupTabVerticalPadding,
            iconSpacing: groupTabIconSpacing
        ) {
            selectCustomGroup(group.id)
        }
        .help(group.name)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .preference(
                        key: GroupTabFramePreferenceKey.self,
                        value: [group.id: proxy.frame(in: .named(GroupBarDropSpace.name))]
                    )
            }
        )
        .overlay(alignment: .leading) {
            if insertionEdge == .leading {
                groupInsertionIndicator
                    .offset(x: -4)
            }
        }
        .overlay(alignment: .trailing) {
            if insertionEdge == .trailing {
                groupInsertionIndicator
                    .offset(x: 4)
            }
        }
        .onDrag {
            reorderTarget = nil
            viewModel.draggedGroup = group
            let provider = NSItemProvider(object: group.id as NSString)
            provider.registerDataRepresentation(
                forTypeIdentifier: ClipboardDragType.group,
                visibility: .all
            ) { completion in
                completion(group.id.data(using: .utf8), nil)
                return nil
            }
            return provider
        }
        .onDrop(
            of: [
                ClipboardDragType.item,
                UTType.image.identifier,
                UTType.fileURL.identifier
            ],
            isTargeted: Binding(
                get: { targetedGroupId == group.id },
                set: { isTargeted in
                    withAnimation(.easeOut(duration: 0.08)) {
                        targetedGroupId = isTargeted ? group.id : nil
                    }
                }
            )
        ) { providers in
            handleItemDrop(providers: providers) { draggedItem in
                viewModel.assignItemToGroup(item: draggedItem, group: group)
            }
        }
        .contextMenu {
            Button {
                editGroupEditor.prepareForEditing(group: group)
                groupToEdit = group
                showEditPopover = true
            } label: { Label("Rename", systemImage: "pencil") }
            Button(role: .destructive) {
                groupToDelete = group
                showDeleteAlert = true
            } label: { Label("Delete Group", systemImage: "trash") }
        }
    }

    private var groupInsertionIndicator: some View {
        Capsule(style: .continuous)
            .fill(appAccentColor.color)
            .frame(width: 3, height: 22)
            .shadow(color: appAccentColor.color.opacity(0.35), radius: 4, y: 1)
            .allowsHitTesting(false)
    }

    // MARK: - 固定面板按钮
    private var pinButton: some View {
        Button(action: {
            isPanelPinned.toggle()
            NotificationCenter.default.post(
                name: NSNotification.Name("TogglePinStatus"),
                object: isPanelPinned
            )
        }) {
            Image(systemName: isPanelPinned ? "pin.fill" : "pin")
                .foregroundStyle(isPanelPinned ? appAccentColor.color : .secondary)
                .font(.system(size: 15))
                .rotationEffect(.degrees(isPanelPinned ? 45 : 0))
                .animation(.spring(), value: isPanelPinned)
        }
        .buttonStyle(.plain)
        .help(isPanelPinned ? Text("取消固定面板") : Text("固定面板"))
    }

    // MARK: - 设置下拉菜单
    private var settingsMenu: some View {
        Menu {
            Button(action: { isMonitoringPaused.toggle() }) {
                Text(isMonitoringPaused ? "Resume Monitoring" : "Pause Monitoring")
            }

            Menu("Clipboard Monitoring Interval") {
                Button(action: { monitorInterval = 0.1 }) {
                    HStack {
                        Text("Very Frequent (0.1s)")
                        if monitorInterval == 0.1 { Image(systemName: "checkmark") }
                    }
                }
                Button(action: { monitorInterval = 0.5 }) {
                    HStack {
                        Text("Frequent (0.5s)")
                        if monitorInterval == 0.5 { Image(systemName: "checkmark") }
                    }
                }
                Button(action: { monitorInterval = 1.0 }) {
                    HStack {
                        Text("Normal (1s)")
                        if monitorInterval == 1.0 { Image(systemName: "checkmark") }
                    }
                }
            }

            Divider()

            Button("Settings…") {
                NotificationCenter.default.post(
                    name: NSNotification.Name("HidePanelForce"),
                    object: nil
                )
                SettingsWindowCoordinator.open {
                    openSettings()
                }
            }

            Toggle("Launch at Login", isOn: launchAtLoginBinding)

            Divider()

            Button("About Clipaste") {
                NSApp.orderFrontStandardAboutPanel()
                NotificationCenter.default.post(
                    name: NSNotification.Name("HidePanelForce"),
                    object: nil
                )
            }

            Button("Send Feedback") {
                if let url = URL(string: "mailto:your_email@example.com?subject=clipaste%20Feedback") {
                    NSWorkspace.shared.open(url)
                }
            }

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        } label: {
            Image(systemName: "gearshape")
                .foregroundColor(.secondary)
                .font(.system(size: 15))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { preferencesStore.launchAtLogin },
            set: { preferencesStore.updateLaunchAtLogin($0) }
        )
    }

    // MARK: - 搜索栏（竖版模式使用）
    @ViewBuilder
    private var searchBarContent: some View {
        HStack(spacing: 8) {
            // 左侧：固定面板按钮
            pinButton

            // 中间：搜索框
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                TextField("Search…", text: searchTextBinding)
                    .font(.system(size: 13))
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled(true)
#if os(macOS)
                    .textContentType(.none)
#endif
                    .tint(appAccentColor.color)
                    .focused($focusedField, equals: .searchBar)
                if !viewModel.searchInput.isEmpty {
                    Button(action: { viewModel.searchInput = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .frame(maxWidth: .infinity)
            .background(Color.clear.background(.regularMaterial))
            .overlay {
                Capsule()
                    .strokeBorder(searchFieldFocusColor, lineWidth: 1)
            }
            .clipShape(Capsule())
            .shadow(color: searchFieldShadowColor, radius: focusedField == .searchBar ? 8 : 4, y: 2)

            // 右侧：设置菜单
            settingsMenu
        }
    }

    // MARK: - 新建分组弹窗
    private var newGroupPopover: some View {
        GroupEditorPopover(viewModel: newGroupEditor) { name, iconName in
            commitNewGroup(name: name, iconName: iconName)
        }
    }

    private func commitNewGroup(name: String, iconName: String?) {
        viewModel.createNewGroup(name: name, systemIconName: iconName)
        isShowingNewGroupPopover = false
    }

    // MARK: - 编辑分组弹窗（支持修改名称 + 图标）
    private var editGroupPopover: some View {
        GroupEditorPopover(viewModel: editGroupEditor) { name, iconName in
            commitEditGroup(name: name, iconName: iconName)
        }
    }

    private func commitEditGroup(name: String, iconName: String?) {
        guard let group = groupToEdit else { return }
        if name != group.name {
            viewModel.renameGroup(group: group, newName: name)
        }
        // 重新获取更新后的 group（名称可能已改）
        let updatedGroup = viewModel.customGroups.first(where: { $0.id == group.id }) ?? group
        if iconName != updatedGroup.systemIconName {
            viewModel.updateGroupIcon(group: updatedGroup, newIcon: iconName)
        }
        showEditPopover = false
    }

    private func updatePopoverInputState(isShowing: Bool) {
        TypeToSearchService.shared.isPaused = isShowingNewGroupPopover || showEditPopover

        if isShowing {
            focusedField = nil
        }
    }

    private var searchTextBinding: Binding<String> {
        Binding(
            get: { viewModel.searchInput },
            set: { newValue in
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    viewModel.searchInput = newValue
                }
            }
        )
    }

    private var searchFieldFocusColor: Color {
        focusedField == .searchBar
            ? appAccentColor.color.opacity(0.34)
            : .clear
    }

    private var searchFieldShadowColor: Color {
        isHorizontalSearchExpanded
            ? appAccentColor.color.opacity(0.16)
            : .black.opacity(0.05)
    }

    private func selectAllGroup() {
        withAnimation(.easeOut(duration: 0.12)) {
            viewModel.showAllItems()
        }
    }

    private func selectCustomGroup(_ groupID: String) {
        withAnimation(.easeOut(duration: 0.12)) {
            viewModel.showCustomGroup(groupID)
        }
    }

    private func selectSmartFilter(_ type: ClipboardContentType) {
        withAnimation(.easeOut(duration: 0.12)) {
            viewModel.showSmartFilter(type)
        }
    }

    private func selectBuiltInGroup(_ group: ClipboardBuiltInGroup) {
        withAnimation(.easeOut(duration: 0.12)) {
            viewModel.showBuiltInGroup(group)
        }
    }

    private func handleItemDrop(
        providers: [NSItemProvider],
        onResolvedItem: @escaping (ClipboardItem) -> Void
    ) -> Bool {
        if let draggedItemId = viewModel.draggedItemId,
           let draggedItem = viewModel.items.first(where: { $0.id == draggedItemId }) {
            onResolvedItem(draggedItem)
            viewModel.draggedItemId = nil
            return true
        }

        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(ClipboardDragType.item) }) else {
            return false
        }

        provider.loadDataRepresentation(forTypeIdentifier: ClipboardDragType.item) { data, _ in
            if let data,
               let idString = String(data: data, encoding: .utf8),
               let uuid = UUID(uuidString: idString) {
                DispatchQueue.main.async {
                    if let draggedItem = viewModel.items.first(where: { $0.id == uuid }) {
                        onResolvedItem(draggedItem)
                        viewModel.draggedItemId = nil
                    }
                }
            }
        }
        return true
    }
}
