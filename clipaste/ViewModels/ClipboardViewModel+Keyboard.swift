import AppKit
import Combine
import SwiftUI

extension ClipboardViewModel {
    func setupKeyboardIntentSubscriptions() {
        NotificationCenter.default.publisher(for: .toggleFavoriteSelectionIntent)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.isPanelPresentationActive else { return }
                self.toggleFavoriteForSelection()
            }
            .store(in: &cancellables)
    }

    func startKeyboardMonitoring() {
        stopKeyboardMonitoring()
        updateModifierFlags(from: NSEvent.modifierFlags)

        flagsChangedMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.updateModifierFlags(from: event.modifierFlags)
            return event
        }

        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // Only process keyboard events when the Clipaste panel is visible.
            // This prevents capturing keys when the panel is hidden.
            guard ClipboardPanelManager.shared.panel?.isVisible == true else { return event }
            return self.handlePanelKeyDown(event)
        }
    }

    func stopKeyboardMonitoring() {
        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
            self.keyDownMonitor = nil
        }

        if let flagsChangedMonitor {
            NSEvent.removeMonitor(flagsChangedMonitor)
            self.flagsChangedMonitor = nil
        }

        resetModifierTracking()
    }

    func handlePrimaryClickSelection(for itemID: UUID) {
        if isQuickLookActive {
            dismissQuickLook()
        }
        handleSelection(
            id: itemID,
            isCommand: currentModifierFlags.contains(.command),
            isShift: currentModifierFlags.contains(.shift)
        )
    }

    var reservedSearchModifierFlags: NSEvent.ModifierFlags {
        quickPasteModifier.eventFlags
            .union(plainTextModifier.eventFlags)
    }

    func shouldStartTypeToSearch(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let acceptedInput = acceptedSearchInput(from: event)

        if modifiers.contains(.command) || modifiers.contains(.control) || modifiers.contains(.option) {
            return false
        }

        let reservedModifiers = modifiers.intersection(reservedSearchModifierFlags)
        if !reservedModifiers.isEmpty,
           allowsShiftGeneratedTypeToSearch(
                modifiers: modifiers,
                reservedModifiers: reservedModifiers,
                acceptedInput: acceptedInput
           ) == false {
            return false
        }

        return acceptedInput != nil
    }

    func acceptedSearchInput(from event: NSEvent) -> String? {
        if let characters = event.characters,
           let acceptedCharacters = acceptedSearchInput(from: characters) {
            return acceptedCharacters
        }

        guard let charactersIgnoringModifiers = event.charactersIgnoringModifiers else {
            return nil
        }

        return acceptedSearchInput(from: charactersIgnoringModifiers)
    }

    func setupModifierPreferenceSync() {
        syncModifierPreferences()

        NotificationCenter.default.publisher(
            for: UserDefaults.didChangeNotification,
            object: UserDefaults.standard
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            self?.syncModifierPreferences()
        }
        .store(in: &cancellables)
    }

    func syncModifierPreferences() {
        let updatedQuickPasteModifier = ModifierKey.quickPastePreference()
        if quickPasteModifier != updatedQuickPasteModifier {
            quickPasteModifier = updatedQuickPasteModifier
        }

        let updatedPlainTextModifier = ModifierKey.plainTextPreference()
        if plainTextModifier != updatedPlainTextModifier {
            plainTextModifier = updatedPlainTextModifier
        }

        updateModifierFlags(from: currentModifierFlags)
    }

    func updateModifierFlags(from modifierFlags: NSEvent.ModifierFlags) {
        currentModifierFlags = modifierFlags.intersection(.deviceIndependentFlagsMask)

        let quickPasteHeld = currentModifierFlags.contains(quickPasteModifier.eventFlags)
        if isQuickPasteModifierHeld != quickPasteHeld {
            isQuickPasteModifierHeld = quickPasteHeld
        }

        let plainTextHeld = currentModifierFlags.contains(plainTextModifier.eventFlags)
        if isPlainTextModifierHeld != plainTextHeld {
            isPlainTextModifierHeld = plainTextHeld
        }

    }

    func resetModifierTracking() {
        currentModifierFlags = []
        if isQuickPasteModifierHeld {
            isQuickPasteModifierHeld = false
        }
        if isPlainTextModifierHeld {
            isPlainTextModifierHeld = false
        }
    }

    func handlePanelKeyDown(_ event: NSEvent) -> NSEvent? {
        let keyCode = event.keyCode

        if handleQuickLookTranslateSelectionShortcutIfNeeded(event) {
            return nil
        }

        if handleQuickLookCopyShortcutIfNeeded(event) {
            return nil
        }

        if hasActiveTextInputResponder, panelFocusField != .clipList {
            if keyCode == 53 {
                if isQuickLookActive {
                    toggleQuickLook()
                } else if !searchInput.isEmpty {
                    searchInput = ""
                } else {
                    NotificationCenter.default.post(name: NSNotification.Name("HidePanelForce"), object: nil)
                }
                return nil
            }

            if panelFocusField == .searchBar, isSearchInputEffectivelyEmpty {
                if PanelShortcutStore.matches(event, action: .translatePreviewSelection) {
                    if let textView = NSApp.keyWindow?.firstResponder as? NSTextView,
                       textView.hasMarkedText() {
                        return event
                    }

                    if !selectedItemIDs.isEmpty || isQuickLookActive {
                        let mode = PreviewPanelMode(rawValue: UserDefaults.standard.string(forKey: "previewPanelMode") ?? PreviewPanelMode.disabled.rawValue) ?? .disabled
                        guard mode == .enabled else { return event }
                        openTranslationWindowForCurrentPreviewSelection()
                        return nil
                    }
                    return event
                }

                if PanelShortcutStore.matches(event, action: .previewSelection) {
                    if let textView = NSApp.keyWindow?.firstResponder as? NSTextView,
                       textView.hasMarkedText() {
                        return event
                    }

                    if !selectedItemIDs.isEmpty || isQuickLookActive {
                        let mode = PreviewPanelMode(rawValue: UserDefaults.standard.string(forKey: "previewPanelMode") ?? PreviewPanelMode.disabled.rawValue) ?? .disabled
                        guard mode == .enabled else { return event }
                        toggleQuickLook()
                        return nil
                    }
                    return event
                }

                if keyCode == 36 {
                    // When IME is composing (marked text exists), let the Return key commit the composition
                    if let textView = NSApp.keyWindow?.firstResponder as? NSTextView,
                       textView.hasMarkedText() {
                        return event
                    }

                    if isQuickLookActive {
                        toggleQuickLook()
                        return nil
                    }

                    if let firstID = selectedItemIDs.first,
                       let item = displayedItemsForInteraction.first(where: { $0.id == firstID }) {
                        pasteToActiveApp(item: item)
                    } else if let first = displayedItemsForInteraction.first {
                        pasteToActiveApp(item: first)
                    }
                    return nil
                }

                if isPlainNavigationEvent(event),
                   !isQuickLookActive,
                   let direction = navigationDirection(for: keyCode) {
                    moveSelection(direction: direction)
                    return nil
                }
            }

            if isPlainNavigationEvent(event),
               !isQuickLookActive,
               let direction = navigationDirection(for: keyCode),
               shouldRouteSearchArrowNavigation {
                NotificationCenter.default.post(name: .focusListIntent, object: nil)
                moveSelection(direction: direction)
                return nil
            }

            return event
        }

        updateModifierFlags(from: event.modifierFlags)

        if keyCode == 53 {
            if isQuickLookActive {
                toggleQuickLook()
            } else if !searchInput.isEmpty {
                searchInput = ""
            } else {
                NotificationCenter.default.post(name: NSNotification.Name("HidePanelForce"), object: nil)
            }
            return nil
        }

        if matchesPanelShortcut(event, action: .translatePreviewSelection) {
            if shouldProtectPanelTextInput {
                return event
            }

            if !selectedItemIDs.isEmpty || isQuickLookActive {
                let mode = PreviewPanelMode(rawValue: UserDefaults.standard.string(forKey: "previewPanelMode") ?? PreviewPanelMode.disabled.rawValue) ?? .disabled
                guard mode == .enabled else { return event }
                openTranslationWindowForCurrentPreviewSelection()
                return nil
            }
            return event
        }

        if matchesPanelShortcut(event, action: .previewSelection) {
            if shouldProtectPanelTextInput {
                return event
            }

            if !selectedItemIDs.isEmpty || isQuickLookActive {
                let mode = PreviewPanelMode(rawValue: UserDefaults.standard.string(forKey: "previewPanelMode") ?? PreviewPanelMode.disabled.rawValue) ?? .disabled
                guard mode == .enabled else { return event }
                toggleQuickLook()
                return nil
            }
            return event
        }

        if keyCode == 36 {
            if isQuickLookActive {
                toggleQuickLook()
                return nil
            }

            if let firstResponder = NSApp.keyWindow?.firstResponder,
               firstResponder is NSTextView || firstResponder is NSTextField {
                return event
            }

            if let firstID = selectedItemIDs.first,
               let item = displayedItemsForInteraction.first(where: { $0.id == firstID }) {
                pasteToActiveApp(item: item)
            } else if let first = displayedItemsForInteraction.first {
                pasteToActiveApp(item: first)
            }
            return nil
        }

        if keyCode == 43, event.modifierFlags.contains(.command) {
            NotificationCenter.default.post(name: .openSettingsIntent, object: nil)
            return nil
        }

        if keyCode == 3, event.modifierFlags.contains(.command) {
            NotificationCenter.default.post(name: .focusSearchFieldIntent, object: nil)
            return nil
        }

        // Cmd+Backspace to delete selected items (when requireCmdToDelete is enabled)
        if keyCode == 51, event.modifierFlags.contains(.command) {
            if let responder = NSApp.keyWindow?.firstResponder,
               responder is NSTextView || responder is NSTextField {
                return event
            }
            deleteSelection(isCommandHeld: true)
            return nil
        }

        if keyCode == 0, event.modifierFlags.contains(.command) {
            if let responder = NSApp.keyWindow?.firstResponder,
               responder is NSTextView || responder is NSTextField {
                return event
            }
            selectAll()
            return nil
        }

        if matchesPanelShortcut(event, action: .toggleVerticalClipboard) {
            togglePanelLayoutShortcut()
            return nil
        }

        if matchesPanelShortcut(event, action: .nextList) {
            selectNextGroup()
            return nil
        }

        if matchesPanelShortcut(event, action: .prevList) {
            selectPreviousGroup()
            return nil
        }

        if matchesPanelShortcut(event, action: .toggleFavoriteSelection) {
            toggleFavoriteForSelection()
            return nil
        }

        if matchesPanelShortcut(event, action: .clearHistory) {
            StorageManager.shared.clearUnpinnedHistory()
            return nil
        }

        if isPlainNavigationEvent(event),
           !isQuickLookActive,
           let direction = navigationDirection(for: keyCode),
           shouldRouteSearchArrowNavigation {
            NotificationCenter.default.post(name: .focusListIntent, object: nil)
            moveSelection(direction: direction)
            return nil
        }

        if hasActiveTextInputResponder {
            return event
        }

        if isPlainNavigationEvent(event),
           !isQuickLookActive,
           let direction = navigationDirection(for: keyCode) {
            moveSelection(direction: direction)
            return nil
        }

        return event
    }
}

extension ClipboardViewModel {
    var isSearchInputEffectivelyEmpty: Bool {
        searchInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var shouldRouteSearchArrowNavigation: Bool {
        guard panelFocusField == .searchBar else {
            return false
        }

        guard !displayedItemsForInteraction.isEmpty else {
            return false
        }

        guard !searchInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        if let textView = NSApp.keyWindow?.firstResponder as? NSTextView,
           textView.hasMarkedText() {
            return false
        }

        return true
    }

    var hasActiveTextInputResponder: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else {
            return false
        }

        return responder is NSTextView || responder is NSTextField
    }

    func matchesPanelShortcut(_ event: NSEvent, action: PanelShortcutAction) -> Bool {
        guard shouldProtectPanelTextInput == false else {
            return false
        }

        return PanelShortcutStore.matches(event, action: action)
    }

    var shouldProtectPanelTextInput: Bool {
        if panelFocusField == .clipList {
            return false
        }

        if let textView = NSApp.keyWindow?.firstResponder as? NSTextView,
           textView.hasMarkedText() {
            return true
        }

        return hasActiveTextInputResponder
    }

    func togglePanelLayoutShortcut() {
        let defaults = UserDefaults.standard
        let currentLayoutMode = AppLayoutMode(
            rawValue: defaults.string(forKey: "clipboardLayout") ?? AppLayoutMode.horizontal.rawValue
        ) ?? .horizontal

        let nextLayoutMode: AppLayoutMode
        switch currentLayoutMode {
        case .horizontal: nextLayoutMode = .vertical
        case .vertical:   nextLayoutMode = .compact
        case .compact:    nextLayoutMode = .horizontal
        }

        defaults.set(nextLayoutMode.rawValue, forKey: "clipboardLayout")
        defaults.set(nextLayoutMode.isVertical, forKey: "isVerticalLayout")
    }

    func isPlainNavigationEvent(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let disallowedModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        return modifiers.isDisjoint(with: disallowedModifiers)
    }

    func handleQuickLookCopyShortcutIfNeeded(_ event: NSEvent) -> Bool {
        guard isQuickLookCopyShortcut(event),
              let item = quickLookItem else {
            return false
        }

        if let selectedText = selectedQuickLookText(), selectedText.isEmpty == false {
            PasteEngine.shared.writePlainTextToPasteboard(text: selectedText)
            playCopySound()
        } else {
            copyToClipboard(item: item)
        }

        return true
    }

    func openTranslationWindowForCurrentPreviewSelection() {
        guard let item = quickLookPreviewCandidate ?? quickLookItem else {
            return
        }

        guard let configuration = aiSettingsViewModel.activeConfiguration else {
            operationNotice = String(localized: "No active AI configuration is available.")
            NotificationCenter.default.post(name: .openSettingsIntent, object: nil)
            return
        }

        let selectedTranslationText = selectedQuickLookText()?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceTextOverride = selectedTranslationText?.isEmpty == false ? selectedTranslationText : nil

        if isQuickLookActive {
            dismissQuickLook()
        }

        openTranslationWindow(
            for: item,
            configuration: configuration,
            sourceTextOverride: sourceTextOverride
        )
    }

    func handleQuickLookTranslateSelectionShortcutIfNeeded(_ event: NSEvent) -> Bool {
        guard isQuickLookTranslateSelectionShortcut(event),
              let selectedText = selectedQuickLookText()?.trimmingCharacters(in: .whitespacesAndNewlines),
              selectedText.isEmpty == false else {
            return false
        }

        guard let item = quickLookItem else { return false }
        guard let configuration = aiSettingsViewModel.activeConfiguration else {
            operationNotice = String(localized: "No active AI configuration is available.")
            NotificationCenter.default.post(name: .openSettingsIntent, object: nil)
            return true
        }

        dismissQuickLook()
        openTranslationWindow(
            for: item,
            configuration: configuration,
            sourceTextOverride: selectedText
        )
        return true
    }

    func isQuickLookTranslateSelectionShortcut(_ event: NSEvent) -> Bool {
        guard isQuickLookActive else {
            return false
        }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.control),
              modifiers.contains(.shift),
              modifiers.isDisjoint(with: [.command, .option]) else {
            return false
        }

        return event.keyCode == 49
    }

    func isQuickLookCopyShortcut(_ event: NSEvent) -> Bool {
        guard isQuickLookActive else {
            return false
        }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.command),
              modifiers.isDisjoint(with: [.control, .option, .shift]) else {
            return false
        }

        return event.keyCode == 8
    }

    func selectedQuickLookText() -> String? {
        guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView else {
            return nil
        }

        if textView.window === ClipboardPanelManager.shared.panel {
            return nil
        }

        let selectedRange = textView.selectedRange()
        guard selectedRange.length > 0 else {
            return nil
        }

        let text = textView.string as NSString
        guard NSMaxRange(selectedRange) <= text.length else {
            return nil
        }

        return text.substring(with: selectedRange)
    }

    func navigationDirection(for keyCode: UInt16) -> Int? {
        let layout = AppLayoutMode(
            rawValue: UserDefaults.standard.string(forKey: "clipboardLayout") ?? AppLayoutMode.horizontal.rawValue
        ) ?? .horizontal

        if layout.isVertical {
            if keyCode == 125 {
                return 1
            }
            if keyCode == 126 {
                return -1
            }
        } else {
            if keyCode == 124 {
                return 1
            }
            if keyCode == 123 {
                return -1
            }
        }

        return nil
    }

    func acceptedSearchInput(from rawInput: String) -> String? {
        guard !rawInput.isEmpty else { return nil }
        guard rawInput.unicodeScalars.allSatisfy(isAllowedSearchScalar) else { return nil }
        return rawInput
    }

    func allowsShiftGeneratedTypeToSearch(
        modifiers: NSEvent.ModifierFlags,
        reservedModifiers: NSEvent.ModifierFlags,
        acceptedInput: String?
    ) -> Bool {
        guard modifiers == [.shift], reservedModifiers == [.shift] else {
            return false
        }

        guard let acceptedInput else {
            return false
        }

        return !acceptedInput.isEmpty
    }

    func isAllowedSearchScalar(_ scalar: UnicodeScalar) -> Bool {
        let value = scalar.value

        if (0xF700...0xF8FF).contains(value) {
            return false
        }

        if CharacterSet.controlCharacters.contains(scalar) {
            return false
        }

        switch scalar.properties.generalCategory {
        case .uppercaseLetter,
             .lowercaseLetter,
             .titlecaseLetter,
             .modifierLetter,
             .otherLetter,
             .decimalNumber,
             .letterNumber,
             .otherNumber,
             .connectorPunctuation,
             .dashPunctuation,
             .openPunctuation,
             .closePunctuation,
             .initialPunctuation,
             .finalPunctuation,
             .otherPunctuation,
             .mathSymbol,
             .currencySymbol,
             .modifierSymbol,
             .otherSymbol:
            return true
        default:
            return false
        }
    }

}
