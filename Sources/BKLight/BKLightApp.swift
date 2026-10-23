import SwiftUI

@main
struct BKLightApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = DisplayController()

    var body: some Scene {
        Window("BK Light", id: "main") {
            MainView().environmentObject(controller)
        }
        .windowResizability(.contentMinSize)

        MenuBarExtra("BK Light", systemImage: "square.grid.2x2.fill") {
            MenuBarView().environmentObject(controller)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var launchedAtLogin = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The open-application Apple event is only available while launching.
        launchedAtLogin = LaunchAtLogin.wasLaunchedAtLogin
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard launchedAtLogin else { return }
        // Started at login: run quietly from the menu bar.
        DispatchQueue.main.async {
            for window in NSApp.windows where window.identifier?.rawValue == "main" { window.close() }
        }
    }

    /// Keep driving the panels from the menu bar after the window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
