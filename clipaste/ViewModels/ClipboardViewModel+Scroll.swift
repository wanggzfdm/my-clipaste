import Foundation

extension ClipboardViewModel {
    func requestListScroll(to itemID: UUID, animated: Bool) {
        listScrollGeneration &+= 1
        listScrollRequest = ClipboardListScrollRequest(
            id: itemID,
            animated: animated,
            generation: listScrollGeneration
        )
    }

    func requestListScrollToPrimarySelection(animated: Bool) {
        guard let selectedID = lastSelectedID ?? selectedItemIDs.first else { return }
        requestListScroll(to: selectedID, animated: animated)
    }

    /// 分组切换：禁止列表插入/滚动动画一段时间，并 bump 列表身份令牌。
    @MainActor
    func beginScopeSwitchAnimationSuppression(durationNanoseconds: UInt64 = 250_000_000) {
        suppressListAnimations = true
        listContentEpoch &+= 1
        scopeSwitchAnimationSuppressTask?.cancel()
        scopeSwitchAnimationSuppressTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: durationNanoseconds)
            guard let self, !Task.isCancelled else { return }
            self.suppressListAnimations = false
        }
    }

    /// DB 页替换展示列表时再 bump 一次，确保新内容不是「插入动画」进来的。
    @MainActor
    func noteListContentReplacedWithoutAnimation() {
        suppressListAnimations = true
        listContentEpoch &+= 1
        scopeSwitchAnimationSuppressTask?.cancel()
        scopeSwitchAnimationSuppressTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, !Task.isCancelled else { return }
            self.suppressListAnimations = false
        }
    }
}
