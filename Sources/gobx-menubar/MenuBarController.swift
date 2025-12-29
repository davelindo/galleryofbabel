import AppKit
import SwiftUI

@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let model: ExploreMenuModel
    private var iconTimer: Timer?
    private let contextMenu = NSMenu()
    private let pauseItem = NSMenuItem()
    private let stopItem = NSMenuItem()
    private let quitItem = NSMenuItem()

    init(model: ExploreMenuModel) {
        self.model = model
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.popover = NSPopover()
        super.init()

        // macOS 26 style: allow SwiftUI material to handle the background.
        let contentView = MenuContentView(model: model)
            .ignoresSafeArea()

        popover.contentViewController = NSHostingController(rootView: contentView)
        popover.behavior = .transient
        popover.animates = true

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.toolTip = "gobx explore"
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            refreshIcon()
        }

        configureContextMenu()
        iconTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshIcon()
            }
        }
    }

    func stop() {
        iconTimer?.invalidate()
        iconTimer = nil
        model.stop()
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            showContextMenu(button: button, event: event)
            return
        }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // Re-render icon immediately on open for snappiness.
            refreshIcon()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            if let window = popover.contentViewController?.view.window {
                window.isOpaque = false
                window.backgroundColor = .clear
                window.makeKey()
            }
        }
    }

    private func refreshIcon() {
        let tint: NSColor = model.isPaused
            ? .systemOrange
            : (model.isRunning ? .labelColor : .secondaryLabelColor)
        statusItem.button?.contentTintColor = nil
        statusItem.button?.image = StatusIconRenderer.image(
            isRunning: model.isRunning,
            isPaused: model.isPaused,
            tint: tint
        )
    }

    private func configureContextMenu() {
        pauseItem.target = self
        pauseItem.action = #selector(togglePauseFromMenu)
        stopItem.target = self
        stopItem.action = #selector(stopFromMenu)
        quitItem.target = self
        quitItem.action = #selector(quitFromMenu)
        quitItem.title = "Quit"

        contextMenu.addItem(pauseItem)
        contextMenu.addItem(stopItem)
        contextMenu.addItem(.separator())
        contextMenu.addItem(quitItem)
        updateContextMenu()
    }

    private func updateContextMenu() {
        if model.isRunning {
            pauseItem.title = model.isPaused ? "Resume" : "Pause"
            pauseItem.isEnabled = true
            stopItem.title = "Stop"
            stopItem.isEnabled = true
        } else {
            pauseItem.title = "Pause"
            pauseItem.isEnabled = false
            stopItem.title = "Stop"
            stopItem.isEnabled = false
        }
    }

    private func showContextMenu(button: NSStatusBarButton, event: NSEvent) {
        updateContextMenu()
        if popover.isShown {
            popover.performClose(nil)
        }
        NSMenu.popUpContextMenu(contextMenu, with: event, for: button)
    }

    @objc private func togglePauseFromMenu() {
        model.togglePause()
        updateContextMenu()
    }

    @objc private func stopFromMenu() {
        model.stop()
        updateContextMenu()
    }

    @objc private func quitFromMenu() {
        NSApplication.shared.terminate(nil)
    }
}

private enum StatusIconRenderer {
    static func image(isRunning: Bool, isPaused: Bool, tint: NSColor) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size)
        img.lockFocus()
        defer { img.unlockFocus() }

        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()

        if let base = NSImage(systemSymbolName: "cpu.fill", accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
                .applying(NSImage.SymbolConfiguration(hierarchicalColor: tint))
            let baseImg = base.withSymbolConfiguration(config) ?? base
            let baseSize = baseImg.size
            let baseRect = NSRect(
                x: (size.width - baseSize.width) / 2,
                y: (size.height - baseSize.height) / 2,
                width: baseSize.width,
                height: baseSize.height
            )
            baseImg.draw(in: baseRect)
        }

        let overlayName: String = {
            if isRunning { return isPaused ? "pause.fill" : "stop.fill" }
            return "play.fill"
        }()
        if let overlay = NSImage(systemSymbolName: overlayName, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 7, weight: .bold)
                .applying(NSImage.SymbolConfiguration(hierarchicalColor: tint))
            let overlayImg = overlay.withSymbolConfiguration(config) ?? overlay
            let overlaySize = overlayImg.size
            let inset: CGFloat = 1
            let overlayRect = NSRect(
                x: size.width - overlaySize.width - inset,
                y: inset,
                width: overlaySize.width,
                height: overlaySize.height
            )
            overlayImg.draw(in: overlayRect)
        }

        return img
    }
}
