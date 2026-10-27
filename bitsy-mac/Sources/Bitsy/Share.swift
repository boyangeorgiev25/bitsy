import AppKit
import ApplicationServices

// "Send window to Claude": screenshot the window Bitsy is sitting on, then paste it into your Claude chat.

extension Pet {
    /// The window Bitsy is standing on, or the one you're using when it's on the Dock.
    var shareableWindow: Int? {
        if let id = supportID, id >= 0, world.windows[id] != nil { return id }
        if mode == .cling, let id = clingID, world.windows[id] != nil { return id }
        return world.activeID
    }

    /// Show the result in the popup and, when the popup is closed, in a speech bubble.
    private func say(_ title: String, _ detail: String, ok: Bool = false) {
        stats.model.notice = detail
        islandNote = (title, Date())
        if !stats.isOpen && mode != .perch { bubble.show(title, detail, seconds: ok ? 3 : 6) }
    }

    func shareWindow() {
        let m = stats.model
        // the window Bitsy is on or you're using; with no window at all, the whole screen Bitsy is on
        let id = shareableWindow
        let display = (NSScreen.screens.firstIndex { world.toCG($0.frame).contains(CGPoint(x: x, y: y - 40)) } ?? 0) + 1
        guard CGPreflightScreenCaptureAccess() else {
            // First time: macOS shows its own prompt. After that, open the right Settings pane.
            if !CGRequestScreenCaptureAccess(),
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
            say("Needs permission", "Turn on \(name) under Screen & System Audio Recording, then choose Restart \(name) from the menu bar icon.")
            return
        }
        m.notice = "Capturing…"
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = id.map { ["-x", "-o", "-c", "-l", "\($0)"] }   // window only, no shadow, to the clipboard
                ?? ["-x", "-c", "-D", "\(display)"]
            try? p.run()
            p.waitUntilExit()
            DispatchQueue.main.async { self.pasteIntoChat(ok: p.terminationStatus == 0) }
        }
    }

    private func pasteIntoChat(ok: Bool) {
        guard ok else { say("Couldn't capture", "That screen couldn't be captured."); return }
        // the chat: the Claude app if it's open, otherwise whatever you were using
        let target = NSRunningApplication.runningApplications(withBundleIdentifier: "com.anthropic.claudefordesktop").first
            ?? NSWorkspace.shared.frontmostApplication
        target?.activate()
        let where_ = target?.localizedName ?? "your chat"
        guard AXIsProcessTrusted() else {
            say("Copied", "Press ⌘V in \(where_). Allow \(name) under Accessibility to paste automatically.", ok: true)
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            let src = CGEventSource(stateID: .hidSystemState)
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: down)   // V
                e?.flags = .maskCommand
                e?.post(tap: .cghidEventTap)
            }
            self.say("Sent to Claude", "Pasted into \(where_).", ok: true)
            self.walkTarget = nil
            if self.mode == .ground { self.go(.wave, 1.8) }
        }
    }
}
