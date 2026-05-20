//
//  ScriptLibraryWindowController.swift
//  notchprompt
//
//  Hosts the SwiftUI ScriptLibraryView in a standard NSWindow so the user
//  can browse, create, rename, and load saved scripts.
//

import AppKit
import SwiftUI

@MainActor
final class ScriptLibraryWindowController: NSWindowController {
    init() {
        let root = ScriptLibraryView()
        let hosting = NSHostingController(rootView: root)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Notchprompt Script Library"
        window.contentViewController = hosting
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 420)
        // Sit above the overlay panel so the notch never blocks this window.
        window.level = NSWindow.Level(Int(NSWindow.Level.screenSaver.rawValue) + 1)
        window.setFrameAutosaveName("NotchpromptScriptLibraryWindow")
        window.center()

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }
}
