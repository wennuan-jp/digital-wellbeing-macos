import AppKit
import GuardCore
import SwiftUI

@main
struct LolGuardApp: App {
    @StateObject private var state = AppState()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("LoL Guard — Rules & Schedule", id: "main") {
            RulesEditorView(state: state)
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .defaultSize(width: 900, height: 620)

        MenuBarExtra("LoL Guard", systemImage: "shield.lefthalf.filled") {
            VStack(alignment: .leading, spacing: 4) {
                Text("Rules (\(state.statuses.count))")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(state.statuses) { st in
                    let icon = st.bypassActive ? "🟡" : (st.blockedNow ? "🔴" : "🟢")
                    Text("\(icon) \(st.name) (\(st.mode))")
                }
            }

            Divider()

            Button("Open Rules & Schedule...") {
                NSApp.setActivationPolicy(.regular)
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }

            Button(state.isInAppGuardRunning ? "Stop In-App Guard" : "Start In-App Guard") {
                state.toggleInAppGuard()
            }

            Button("Reload Config") {
                state.loadConfig()
                state.refreshStatuses()
            }

            Divider()

            Button("Quit LoL Guard") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
