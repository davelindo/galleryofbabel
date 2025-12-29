import AppKit
import SwiftUI

@main
struct GobxMenuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let model = ExploreMenuModel()
        controller = MenuBarController(model: model)
        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stop()
    }
}
