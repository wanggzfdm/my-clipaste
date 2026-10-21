import SwiftUI

struct ClipboardEmptyStateView: View {
    var viewModel: ClipboardViewModel
    @AppStorage("clipboardLayout") private var clipboardLayout: AppLayoutMode = .horizontal
    @AppStorage("appTheme") private var appTheme: AppTheme = .system

    @State private var shimmerOffset: CGFloat = -600

    private var chrome: PanelChromeTokens {
        appTheme.chrome
    }

    private var skeletonCornerRadius: CGFloat {
        chrome.cardCornerRadius
    }

    var body: some View {
        Group {
            if isLoading {
                loadingPlaceholder
            } else {
                emptyStateContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var isSearching: Bool {
        !viewModel.searchInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isLoading: Bool {
        // 初始加载、或当前 scope 仍空且全量历史未就绪时，显示 skeleton 而非空托盘
        if isSearching { return false }
        if viewModel.isInitialHistoryLoading { return true }
        if viewModel.displayedItemIDs.isEmpty,
           viewModel.hasLoadedFullHistory == false,
           viewModel.isLoadingMoreHistory || viewModel.needsReloadOnNextPresentation {
            return true
        }
        return false
    }

    @ViewBuilder
    private var loadingPlaceholder: some View {
        skeletonStack
            .overlay {
                shimmerOverlay
            }
            .clipped()
    }

    @ViewBuilder
    private var skeletonStack: some View {
        if clipboardLayout == .horizontal {
            HStack(spacing: 20) {
                ForEach(0..<4, id: \.self) { _ in
                    LiquidGlassSurface(cornerRadius: skeletonCornerRadius)
                        .frame(width: 240, height: 240)
                }
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.top, 12)
        } else {
            VStack(spacing: 10) {
                ForEach(0..<6, id: \.self) { _ in
                    LiquidGlassSurface(cornerRadius: chrome.verticalRowCornerRadius)
                        .frame(height: 76)
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 12)
        }
    }

    /// 骨架屏扫光（shimmer）效果：一道高光自左向右掠过，提示正在加载历史。
    private var shimmerOverlay: some View {
        GeometryReader { geo in
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: Color.white.opacity(0.14), location: 0.5),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: geo.size.width * 0.6)
            .offset(x: shimmerOffset)
            .onAppear {
                shimmerOffset = -geo.size.width * 0.7
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    shimmerOffset = geo.size.width * 1.3
                }
            }
        }
        .allowsHitTesting(false)
        .blendMode(.plusLighter)
    }

    private var emptyStateContent: some View {
        VStack(spacing: 16) {
            Image(systemName: isSearching ? "doc.text.magnifyingglass" : "tray.fill")
                .font(.system(size: 48, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tertiary)

            VStack(spacing: 6) {
                Text(titleKey)
                    .font(.headline)
                    .foregroundStyle(.primary)

                Text(subtitleKey)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
        .padding(.top, 60)
        .padding(.bottom, 40)
    }

    private var titleKey: LocalizedStringKey {
        if isLoading {
            return "Loading Clipboard History…"
        }

        return isSearching ? "No Matches Found" : "Clipboard Empty"
    }

    private var subtitleKey: LocalizedStringKey {
        if isLoading {
            return "Recent items will appear first while the full history finishes loading."
        }

        return isSearching ? "Try a different search term" : "Copied text, images and links will appear here"
    }
}
