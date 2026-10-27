import AppKit
import BitsyKit
import ServiceManagement
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {
    var pet: Pet!
    var menuBar: MenuBar!

    func applicationDidFinishLaunching(_ n: Notification) {
        pet = Pet()
        menuBar = MenuBar(pet: pet)
        // first launch from /Applications: start at login (can be turned off in the menu)
        let d = UserDefaults.standard
        if Bundle.main.bundlePath.hasPrefix("/Applications/") && !d.bool(forKey: "loginItemSet") {
            d.set(true, forKey: "loginItemSet")
            try? SMAppService.mainApp.register()
        }
    }

    func applicationWillTerminate(_ n: Notification) { pet.save(); pet.fanCtl.releaseFans() }
}

final class MenuBar: NSObject, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let pet: Pet

    init(pet: Pet) {
        self.pet = pet
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        refreshIcon()
    }

    func refreshIcon() {
        // A template glyph: the pet's silhouette in black with the eyes cut out. macOS tints it to the
        // menu bar (white on dark, black on light) like every other status item, instead of a coloured
        // sprite that fights the bar.
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setFillColor(.black)
            ctx.addPath(CGPath(roundedRect: CGRect(x: 2, y: 3, width: 14, height: 9), cornerWidth: 2, cornerHeight: 2, transform: nil))
            ctx.fillPath()
            for lx in [3.0, 6.33, 9.67, 13.0] { ctx.fill(CGRect(x: lx, y: 12, width: 2, height: 3)) }
            ctx.setBlendMode(.clear)
            ctx.fill(CGRect(x: 5, y: 5, width: 2, height: 3))
            ctx.fill(CGRect(x: 11, y: 5, width: 2, height: 3))
            return true
        }
        img.isTemplate = true
        item.button?.image = img
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        add(menu, pet.stats.isOpen ? "Hide Status" : "Show Status", #selector(toggleStats))
        add(menu, "Send Window to Claude", #selector(share))
        menu.addItem(.separator())
        add(menu, "Walk on Windows", #selector(toggleWindows)).state = pet.world.includeWindows ? .on : .off
        add(menu, "Watch Me Type", #selector(toggleWatch)).state = pet.watchTyping ? .on : .off
        add(menu, "Follow My Clicks", #selector(toggleFollow)).state = pet.followClicks ? .on : .off
        add(menu, "Stay Put", #selector(togglePause)).state = pet.paused ? .on : .off
        let hours = NSMenuItem(title: "Sleeping Hours", action: nil, keyEquivalent: "")
        let hsub = NSMenu()
        for (start, end) in [(22, 6), (23, 7), (0, 8), (1, 9), (-1, -1)] {
            let it = add(hsub, start < 0 ? "Off" : String(format: "%02d:00 – %02d:00", start, end), #selector(setHours(_:)))
            it.representedObject = [start, end]
            it.state = pet.sleepStart == start && (start < 0 || pet.sleepEnd == end) ? .on : .off
        }
        hours.submenu = hsub
        menu.addItem(hours)
        let fans = NSMenuItem(title: "Fans", action: nil, keyEquivalent: "")
        let fsub = NSMenu()
        let fc = pet.fanCtl
        for mode in FanController.Mode.allCases {
            let it = add(fsub, mode.label, #selector(setFanMode(_:)))
            it.representedObject = mode.rawValue
            it.state = fc.mode == mode ? .on : .off
        }
        fsub.addItem(.separator())
        add(fsub, "Smart: Boost While Claude Works", #selector(toggleBoostClaude)).state = fc.boostClaude ? .on : .off
        add(fsub, "Smart: Boost When CPU Is Above 80%", #selector(toggleBoostCPU)).state = fc.boostCPU ? .on : .off
        add(fsub, "Smart: Quiet During Sleeping Hours", #selector(toggleQuietNight)).state = fc.quietAtNight ? .on : .off
        let lvl = NSMenuItem(title: "Smart Boost Level", action: nil, keyEquivalent: "")
        let lsub = NSMenu()
        for (name, v) in [("Medium", 50.0), ("High", 75.0), ("Max", 100.0)] {
            let it = add(lsub, name, #selector(setBoostLevel(_:)))
            it.representedObject = v
            it.state = fc.boostLevel == v ? .on : .off
        }
        lvl.submenu = lsub
        fsub.addItem(lvl)
        fsub.addItem(.separator())
        if FanHelper.installed { add(fsub, "Uninstall Fan Helper…", #selector(uninstallFans)) }
        else { add(fsub, "Install Fan Helper…", #selector(installFans)) }
        fans.submenu = fsub
        menu.addItem(fans)
        add(menu, "Open at Login", #selector(toggleLogin)).state = SMAppService.mainApp.status == .enabled ? .on : .off
        if !AXIsProcessTrusted() { add(menu, "Allow Accessibility (exact Dock, auto-paste)…", #selector(askAccessibility)) }
        add(menu, "Rename…", #selector(rename))
        add(menu, "Bring \(pet.name) to Mouse", #selector(bringHere))
        menu.addItem(.separator())
        add(menu, "Restart \(pet.name)", #selector(restart))
        add(menu, "Quit \(pet.name)", #selector(quit), "q")
    }

    @discardableResult
    private func add(_ m: NSMenu, _ title: String, _ sel: Selector, _ key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        it.target = self
        m.addItem(it)
        return it
    }

    @objc func toggleStats() { pet.syncStats(); pet.stats.toggle() }
    @objc func share() { pet.shareWindow() }
    @objc func setFanMode(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let m = FanController.Mode(rawValue: raw) { pet.fanCtl.mode = m }
    }
    @objc func toggleBoostClaude() { pet.fanCtl.boostClaude.toggle() }
    @objc func toggleBoostCPU() { pet.fanCtl.boostCPU.toggle() }
    @objc func toggleQuietNight() { pet.fanCtl.quietAtNight.toggle() }
    @objc func setBoostLevel(_ sender: NSMenuItem) { if let v = sender.representedObject as? Double { pet.fanCtl.boostLevel = v } }
    @objc func installFans() { pet.installFanHelper() }
    @objc func uninstallFans() { pet.fanCtl.uninstall { _ in } }
    @objc func setHours(_ sender: NSMenuItem) {
        guard let h = sender.representedObject as? [Int] else { return }
        pet.sleepStart = h[0]; pet.sleepEnd = h[1]; pet.save()
    }
    @objc func askAccessibility() {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }
    @objc func toggleWindows() { pet.world.includeWindows.toggle(); pet.save() }
    @objc func toggleWatch() { pet.watchTyping.toggle(); pet.save() }
    @objc func toggleFollow() { pet.followClicks.toggle(); pet.save() }
    @objc func togglePause() { pet.paused.toggle() }

    @objc func toggleLogin() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled { try svc.unregister() } else { try svc.register() }
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = "Couldn't change Open at Login"
            a.informativeText = "\(error.localizedDescription)\n\nYou can add Bitsy in System Settings > General > Login Items."
            a.runModal()
        }
    }

    @objc func rename() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Rename your pet"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = pet.name
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            let n = field.stringValue.trimmingCharacters(in: .whitespaces)
            if !n.isEmpty { pet.name = n; pet.save() }
        }
    }

    @objc func bringHere() {
        let p = pet.world.toCG(NSEvent.mouseLocation)
        pet.respawn(at: CGPoint(x: p.x, y: p.y + 60))
    }

    @objc func quit() { NSApp.terminate(nil) }

    /// macOS applies a new Screen Recording permission only after the app restarts.
    @objc func restart() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }
}
