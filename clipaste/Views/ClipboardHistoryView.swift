import SwiftUI
import AppKit
import SwiftData

struct ClipboardHistoryView: View {
    var body: some View {
        ClipboardMainView()
            .environmentObject(AppPreferencesStore.shared)
            .environment(ClipboardRuntimeStore.shared)
            .modelContainer(ClipboardRuntimeStore.shared.container)
            .id(ClipboardRuntimeStore.shared.rootIdentity)
    }
}

// Helper wrapper for NSVisualEffectView to get the correct background blur
struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    var isEmphasized: Bool = true
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let visualEffectView = NSVisualEffectView()
        configure(visualEffectView)
        return visualEffectView
    }
    
    func updateNSView(_ visualEffectView: NSVisualEffectView, context: Context) {
        configure(visualEffectView)
    }

    private func configure(_ visualEffectView: NSVisualEffectView) {
        visualEffectView.material = material
        visualEffectView.blendingMode = blendingMode
        // Keep blur active even when the panel is not key, matching fork glass feel.
        visualEffectView.state = .active
        visualEffectView.isEmphasized = isEmphasized
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.backgroundColor = NSColor.clear.cgColor
    }
}

#Preview {
    ClipboardHistoryView()
}
