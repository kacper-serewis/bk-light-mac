import ServiceManagement
import SwiftUI

/// Registers the app itself as a login item (System Settings › General › Login Items).
@MainActor
final class LaunchAtLogin: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var note: String?

    init() { refresh() }

    func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled || status == .requiresApproval
        note = status == .requiresApproval
            ? "Allow BK Light in System Settings › General › Login Items."
            : nil
    }

    func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            note = error.localizedDescription
            isEnabled = SMAppService.mainApp.status == .enabled
            return
        }
        refresh()
    }

    /// True when macOS started the app at login, so it can stay in the menu bar without opening a window.
    static var wasLaunchedAtLogin: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}

struct LaunchAtLoginToggle: View {
    @StateObject private var launchAtLogin = LaunchAtLogin()

    var body: some View {
        Toggle("Start at login", isOn: Binding(get: { launchAtLogin.isEnabled }, set: { launchAtLogin.set($0) }))
            .onAppear { launchAtLogin.refresh() }
        if let note = launchAtLogin.note {
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
    }
}
