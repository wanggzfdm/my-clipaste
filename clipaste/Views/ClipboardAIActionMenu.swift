import AppKit
import SwiftUI

/// Immutable snapshot of AI menu contents (fork 2.1.5 paste chrome).
struct AIMenuSnapshot: Equatable {
    let isEnabled: Bool
    let hasConfigurations: Bool
    let skills: [AISkill]
    let lastUsedSkill: AISkill?

    static func make(item: ClipboardItem, settings: AISettingsViewModel) -> AIMenuSnapshot {
        let skills = settings.availableSkills(for: item)
        return AIMenuSnapshot(
            isEnabled: settings.isAIEnabled,
            hasConfigurations: settings.configurations.isEmpty == false,
            skills: skills,
            lastUsedSkill: settings.lastUsedAvailableSkill(for: item)
        )
    }
}

/// Standard (2.2.10) AI menu driven by live item + viewModel.
struct ClipboardAIActionMenu<MenuLabel: View>: View {
    let item: ClipboardItem
    @ObservedObject var viewModel: ClipboardViewModel
    @ViewBuilder var label: () -> MenuLabel

    var body: some View {
        let snapshot = AIMenuSnapshot.make(item: item, settings: viewModel.aiSettingsViewModel)
        ClipboardAIActionMenuSnapshot(
            snapshot: snapshot,
            onRunSkill: { skill in viewModel.runAISkill(skill, for: item) },
            onOpenSettings: {
                NotificationCenter.default.post(name: .openSettingsIntent, object: nil)
            },
            label: label
        )
    }
}

/// Fork-style snapshot menu used by Paste cards.
struct ClipboardAIActionMenuSnapshot<MenuLabel: View>: View {
    let snapshot: AIMenuSnapshot
    let onRunSkill: (AISkill) -> Void
    let onOpenSettings: () -> Void
    @ViewBuilder var label: () -> MenuLabel

    var body: some View {
        Menu {
            menuContent
        } label: {
            label()
        }
    }

    @ViewBuilder
    private var menuContent: some View {
        if snapshot.isEnabled == false {
            Text("AI Disabled")
                .foregroundStyle(.secondary)
        } else if snapshot.hasConfigurations == false {
            Text("No AI Configurations")
                .foregroundStyle(.secondary)

            Button(action: onOpenSettings) {
                Label("Open AI Settings…", systemImage: "gearshape")
            }
        } else if snapshot.skills.isEmpty {
            Text("No AI Skills Available")
                .foregroundStyle(.secondary)

            Button(action: onOpenSettings) {
                Label("Add AI Skill…", systemImage: "plus")
            }
        } else {
            if let lastSkill = snapshot.lastUsedSkill {
                Button {
                    onRunSkill(lastSkill)
                } label: {
                    Label("Use Again: \(lastSkill.displayTitle)", systemImage: "clock.arrow.circlepath")
                }

                Divider()
            }

            ForEach(snapshot.skills) { skill in
                Button {
                    onRunSkill(skill)
                } label: {
                    Label(skill.displayTitle, systemImage: skill.outputMode.systemImage)
                }
            }

            Divider()

            Button(action: onOpenSettings) {
                Label("Manage AI Skills…", systemImage: "slider.horizontal.3")
            }
        }
    }
}

extension View {
    /// Freeze hover-driven state while any `NSMenu` is tracking (context menus / nested menus).
    func freezingHoverWhileMenuTracking(
        isMenuTracking: Binding<Bool>,
        onHoverChange: @escaping (Bool) -> Void
    ) -> some View {
        self
            .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
                isMenuTracking.wrappedValue = true
            }
            .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
                isMenuTracking.wrappedValue = false
            }
            .onHover { hovering in
                guard isMenuTracking.wrappedValue == false else { return }
                onHoverChange(hovering)
            }
    }
}
