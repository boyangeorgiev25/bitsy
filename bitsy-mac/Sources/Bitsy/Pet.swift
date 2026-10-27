import AppKit
import ApplicationServices

let DOING: [Anim: String] = [
    .idle: "chilling", .walk: "wandering", .run: "zooming around", .jump: "hopping", .wave: "saying hi",
    .love: "happy", .surprised: "startled", .think: "thinking", .work: "coding", .dance: "dancing",
    .sleep: "napping", .dangle: "being carried", .fall: "falling!", .land: "oof", .crouch: "about to jump",
    .leap: "jumping", .teeter: "losing balance!", .vibe: "listening to music", .hang: "in the Dynamic Island", .drowsy: "up late with you", .cheer: "celebrating",
]

final class PetView: NSView {
    var current = Frame(pose: Pose())
    weak var pet: Pet?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with e: NSEvent) { NSCursor.openHand.set() }
    override func mouseExited(with e: NSEvent) { NSCursor.arrow.set() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(bounds)
        drawPet(ctx, Pet.S, current.pose)
        current.fx.forEach { drawFX(ctx, Pet.S, $0) }
    }

    override func mouseDown(with e: NSEvent) { pet?.mouseDown(clicks: e.clickCount) }
    override func mouseDragged(with e: NSEvent) { pet?.mouseDragged() }
    override func mouseUp(with e: NSEvent) { pet?.mouseUp() }
}

/// Borderless panel that may sit anywhere, even half under the menu bar.
final class PetPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class Pet {
    static let S: CGFloat = 3          // points per logical pixel
    static let size: Double = 96       // 32 × S
    static let foot: Double = 84       // feet line from the window top (28 × S)

    let panel: PetPanel
    let view = PetView(frame: NSRect(x: 0, y: 0, width: 96, height: 96))
    let world = World()
    let stats = StatsController()
    let claude = ClaudeMonitor()
    let media = MediaMonitor()
    lazy var island = IslandController(stats: stats.model)
    let fanCtl = FanController()
    let bubble = BubbleController()
    let bridge = BridgeServer()
    let ropePanel = RopePanel()
    var rope: Rope?                                      // lowered on a rope to look at a window for Claude
    var perchNotch: CGRect?                              // the notch (or menu-bar spot) Bitsy is docked in
    var spotErrorsOn = true
    var errorCheckBusy = false, errorAcc = 0.0
    var seenErrors = Set<String>(), errorPIDs = Set<pid_t>()
    let confirm = ConfirmController()

    enum Mode { case ground, fall, leap, drag, perch, cling, rope }
    var mode: Mode = .fall
    var x = 0.0, y = 0.0, vx = 0.0, vy = 0.0, dir = 1   // feet point, global CG coords
    var anim: Anim = .fall, t = 0.0, dur = 99.0
    var supportID: Int?, supportRect: CGRect?
    var walkTarget: Double?
    var pendingHop: (Platform, Double)?
    var clingID: Int?, clingEdge = World.Edge.bottom, clingDX = 0.0   // hanging from a window edge; x is an offset into the window
    var pendingCling: (id: Int, edge: World.Edge, dx: Double)?     // where the next leap grabs on
    var pendingWindow: Int?                              // a window you clicked; go there once back on the ground
    var followClicks = true
    private var lastActiveID: Int?
    private var candidateID: Int?, candidateSince = 0.0   // the selected window, and since when
    var leapFrom = CGPoint.zero, leapTo = CGPoint.zero, leapT = 1.0, leapH = 80.0, leapID: Int?
    var shove = (x: 0.0, y: 0.0)                         // recent movement of the window under Bitsy
    var fellOff: Int?                                    // window Bitsy just lost balance on: fall past it
    var droppedByUser = false
    var paused = false
    var watchTyping = true
    var name = "Bitsy"
    var energy = 86.0
    var claudeWasWorking = false
    var seenFinish = 0
    var islandNote: (text: String, at: Date)?           // short message for the island, e.g. "Sent to Claude"
    var autoPerched = false                              // went into the island because an app went full screen
    private var islandPressed = false
    var notchLevel = 0                                   // while dragging: 1 near the notch, 2 touching it
    var demoCarry: (from: CGPoint, to: CGPoint, start: Double, dur: Double)?   // demo mode: carried along a path
    private var pendingClick: DispatchWorkItem?
    private var doubleClicked = false
    private var stayOut = false                          // pulled out of the island during this full-screen session
    var sleepStart = 23, sleepEnd = 7                    // sleeping hours; sleepStart < 0 turns them off
    var ide: String?

    private var downAt: NSPoint?
    var dragging = false
    private var mediaAcc = 0.0
    private var permAcc = 5.0
    private var last = CACurrentMediaTime(), refreshAcc = 0.0, trackAcc = 0.0, statsAcc = 0.0, saveAcc = 0.0
    private var timer: Timer?
    private var hz = 0.0
    private var lastOrigin = NSPoint(x: -1, y: -1)
    private let defaults = UserDefaults.standard
    private let debug = ProcessInfo.processInfo.environment["BITSY_DEBUG"] != nil
    private var debugAcc = 0.0

    init() {
        panel = PetPanel(contentRect: NSRect(x: 0, y: 0, width: 96, height: 96),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = view
        view.pet = self

        load()
        if ProcessInfo.processInfo.environment["BITSY_STAY"] != nil { paused = true }   // debugging
        stats.model.onMedia = { [weak self] cmd in self?.media.control(cmd) }
        stats.model.onShare = { [weak self] in self?.shareWindow() }
        stats.model.onFanMode = { [weak self] raw in
            guard let self, let mode = FanController.Mode(rawValue: raw) else { return }
            self.fanCtl.mode = mode
            self.stats.model.fanNotice = nil
        }
        stats.model.onInstallFans = { [weak self] in self?.installFanHelper() }
        island.model.onDragMove = { [weak self] in
            guard let self else { return }
            if !self.islandPressed { self.islandPressed = true; self.mouseDown() } else { self.mouseDragged() }
        }
        island.model.onDragEnd = { [weak self] in self?.islandPressed = false; self?.mouseUp() }
        island.model.onExpand = { [weak self] music in
            guard let self else { return }
            if self.media.now == nil { self.media.query() }
            self.syncStats()
            self.island.expand(music: music)
        }
        island.model.onDoubleTap = { [weak self] in self?.shareWindow() }
        bubble.model.onClick = { [weak self] in
            guard let self else { return }
            if let a = self.bubble.action { a() }
            else { NSRunningApplication.runningApplications(withBundleIdentifier: "com.anthropic.claudefordesktop").first?.activate() }
            self.bubble.hide()
        }
        bridge.pet = self
        bridge.start()
        fanCtl.start()
        claude.start()
        world.refresh()
        if let drop = ProcessInfo.processInfo.environment["BITSY_DROP"]?.split(separator: ",").compactMap({ Double($0) }), drop.count == 2 {
            respawn(at: CGPoint(x: drop[0], y: drop[1]))   // debugging: start falling from a point
        } else {
            respawn(at: nil)
        }
        panel.orderFrontRegardless()
        setRate(60)
        if ProcessInfo.processInfo.environment["BITSY_DEMO"] != nil { runDemo() }
    }

    /// 60 fps while moving, 30 when standing still (sprite frames never change faster than 14 fps).
    func setRate(_ r: Double) {
        guard r != hz else { return }
        hz = r
        timer?.invalidate()
        let tm = Timer(timeInterval: 1.0 / r, repeats: true) { [weak self] _ in self?.tick() }
        tm.tolerance = 0.2 / r
        RunLoop.main.add(tm, forMode: .common)
        timer = tm
    }

    // MARK: persistence

    func load() {
        name = defaults.string(forKey: "name") ?? "Bitsy"
        if defaults.object(forKey: "windows") != nil { world.includeWindows = defaults.bool(forKey: "windows") }
        if defaults.object(forKey: "watchTyping") != nil { watchTyping = defaults.bool(forKey: "watchTyping") }
        if defaults.object(forKey: "followClicks") != nil { followClicks = defaults.bool(forKey: "followClicks") }
        if defaults.object(forKey: "sleepStart") != nil { sleepStart = defaults.integer(forKey: "sleepStart"); sleepEnd = defaults.integer(forKey: "sleepEnd") }
    }

    func save() {
        defaults.set(name, forKey: "name")
        defaults.set(world.includeWindows, forKey: "windows")
        defaults.set(watchTyping, forKey: "watchTyping")
        defaults.set(followClicks, forKey: "followClicks")
        defaults.set(sleepStart, forKey: "sleepStart")
        defaults.set(sleepEnd, forKey: "sleepEnd")
    }

    // MARK: loop

    func tick() {
        let now = CACurrentMediaTime()
        let dt = min(0.05, now - last)
        last = now
        refreshAcc += dt
        trackAcc += dt
        if refreshAcc > 0.5 { refreshAcc = 0; trackAcc = 0; world.refresh(); ide = frontmostIDE(); noticeClick() }
        errorAcc += dt
        if errorAcc > 5 { errorAcc = 0; if spotErrorsOn && ide != nil { spotErrors() } }
        else if trackAcc > 1.0 / 15, let id = (mode == .ground ? supportID : mode == .cling ? clingID : nil), id >= 0 { trackAcc = 0; world.track(id) }
        t += dt
        reactToClaude()
        fanCtl.update(claudeWorking: claude.snap.working, night: isNight)
        mediaAcc += dt
        if mediaAcc > 30 { mediaAcc = 0; if media.now == nil { media.query() } }   // a player is open but hasn't said what it's doing

        switch mode {
        case .drag where demoCarry != nil:
            demoCarryStep()
        case .drag:
            // follow the cursor directly (the drag may have started in the island, which hides itself)
            let p = world.toCG(NSEvent.mouseLocation)
            x = p.x
            y = p.y + Pet.foot - 9 * Double(Pet.S)
            let c = world.toCG(NSEvent.mouseLocation)
            if let n = world.notchRect(near: c) {
                let gap = hypot(max(Double(n.minX) - c.x, 0, c.x - Double(n.maxX)), max(c.y - Double(n.maxY), 0))
                notchLevel = Pet.snapZone(n).contains(c) ? 2 : gap < 150 ? 1 : 0
                island.preview(notchLevel, notch: n, world: world)
            }
            if NSEvent.pressedMouseButtons & 1 == 0 { islandPressed = false; mouseUp() }
        case .perch:
            if let n = perchNotch { x = Double(n.midX); y = Double(n.maxY) + 69 } else { leaveIsland(); startFall() }
        case .rope:
            ropeStep()
        case .cling:
            followCling()
        case .fall:
            vy += 2600 * dt
            x += vx * dt
            vx *= max(0, 1 - 1.2 * dt)
            let ny = y + vy * dt
            if vy > 0, let p = world.landing(x: x, from: y, to: ny, skipping: fellOff) {
                y = p.y; vx = 0; vy = 0; fellOff = nil; attach(p); mode = .ground; go(.land, 0.22)
            } else {
                y = ny
                if y > world.lowest + 150 { respawn(at: nil, drop: true) }   // fell past the bottom: drop back onto the Dock
            }
        case .leap:
            let u = min(1, t / leapT)
            x = leapFrom.x + (leapTo.x - leapFrom.x) * u
            y = leapFrom.y + (leapTo.y - leapFrom.y) * u - leapH * 4 * u * (1 - u)
            if u >= 1 {
                if let c = pendingCling { pendingCling = nil; grab(c) }
                else if let p = world.platform(id: leapID, x: x, y: y) { y = p.y; attach(p); mode = .ground; go(.land, 0.22) }
                else { startFall() }
            }
        case .ground:
            followSupport()
            if mode == .ground { brain(dt) }
        }

        render()
        island.tick(content: islandContent())
        // full screen on the notch display: tuck into the island; come back out when it ends
        if !world.fullscreen { stayOut = false }
        if world.fullscreen, !stayOut, mode == .ground || mode == .fall, !dragging { enterIsland(auto: true) }
        else if !world.fullscreen, autoPerched, mode == .perch, !island.expanded { autoPerched = false; leaveIsland(); respawn(at: nil, drop: true) }
        setRate(mode == .ground && anim != .run && anim != .teeter || mode == .perch || mode == .cling ? 30 : 60)

        permAcc += dt
        if permAcc > 5 { permAcc = 0; writePermissions() }

        statsAcc += dt
        if (stats.isOpen || island.expanded) && statsAcc > 0.5 { statsAcc = 0; syncStats() }
        saveAcc += dt
        if saveAcc > 10 { saveAcc = 0; save() }
        if debug {
            debugAcc += dt
            if debugAcc > 1 {
                debugAcc = 0
                print(String(format: "mode=%@ anim=%@ x=%.0f y=%.0f support=%@ claude=%@ ide=%@ music=%@",
                             "\(mode)", anim.rawValue, x, y, supportID.map(String.init) ?? "-",
                             "\(claude.snap.state)", ide ?? "-", media.isPlaying ? "on" : "off"))
                fflush(stdout)
            }
        }
    }

    func go(_ a: Anim, _ d: Double) {
        anim = a; t = 0; dur = d
        if debug { print(String(format: "%.2f go %@ mode=%@ x=%.0f y=%.0f vx=%.0f support=%@", Date().timeIntervalSince1970, a.rawValue, "\(mode)", x, y, vx, supportID.map(String.init) ?? "-")); fflush(stdout) }
    }

    func attach(_ p: Platform) {
        supportID = p.id
        supportRect = p.id >= 0 ? world.windows[p.id] : nil
        shove = (0, 0)
    }

    func startFall() {
        fellOff = nil
        mode = .fall; vx = 0; vy = 0; supportID = nil; supportRect = nil; walkTarget = nil; pendingHop = nil
        clingID = nil; pendingCling = nil
        go(.fall, 99)
    }

    /// Put Bitsy on its home floor (the Dock), or drop it from a point / from the top of the screen.
    func respawn(at p: CGPoint?, drop: Bool = false) {
        if let p { x = p.x; y = p.y; startFall(); return }
        guard let floor = world.homeFloor else { return }
        x = floor.x0 + (floor.x1 - floor.x0) * 0.3
        if drop { y = floor.y - 500; startFall(); return }
        y = floor.y
        attach(floor); mode = .ground; go(.wave, 2)
    }

    /// Stay on whatever we're standing on. A window that moves knocks Bitsy off balance; one that
    /// disappears (minimized, closed, hidden) drops it.
    func followSupport() {
        guard let id = supportID else { startFall(); return }
        if id < 0 {
            guard let p = world.platforms.first(where: { $0.id == id }) else { startFall(); return }
            if x < p.x0 || x > p.x1 {
                x = min(max(x, p.x0 + 10), p.x1 - 10)   // the Dock got narrower
                walkTarget = walkTarget.map { min(max($0, p.x0 + 10), p.x1 - 10) }
            }
            y = p.y
            return
        }
        guard let r = world.windows[id] else { startFall(); return }
        if let old = supportRect, r.origin != old.origin {
            let ddx = Double(r.minX - old.minX), ddy = Double(r.minY - old.minY)
            x += ddx
            shove = (shove.x * 0.5 + ddx, shove.y * 0.5 + ddy)
            if anim != .teeter { walkTarget = nil; pendingHop = nil; go(.teeter, 0.35) }
        }
        supportRect = r
        y = Double(r.minY)
        if !world.includeWindows || !world.platforms.contains(where: { $0.id == id && x >= $0.x0 - 8 && x <= $0.x1 + 8 }) { startFall() }
    }

    /// Lost balance on a moving window: fall off, flung along with the window's motion.
    func knockOff() {
        let s = shove, from = supportID
        startFall()
        fellOff = from
        vx = max(-500, min(500, s.x * 9))
        vy = max(-500, min(0, s.y * 9 - 120))
    }

    var currentPlatform: Platform? {
        world.platforms.first { $0.id == supportID && x >= $0.x0 - 8 && x <= $0.x1 + 8 }
    }

    // MARK: what you're doing

    func sinceKey() -> Double { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown) }
    var typing: Bool { watchTyping && sinceKey() < 2.5 && world.activeID != nil }

    var isNight: Bool {
        guard sleepStart >= 0 else { return false }
        let h = Calendar.current.component(.hour, from: Date())
        return sleepStart > sleepEnd ? (h >= sleepStart || h < sleepEnd) : (h >= sleepStart && h < sleepEnd)
    }

    /// Seconds since any keyboard, mouse or trackpad input.
    func sinceInput() -> Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    /// Claude working or an IDE in front → code. Music playing → vibe. At night: sleep, or stay up drowsy with you.
    var focusAnim: Anim? {
        if isNight {
            if sinceInput() > 90 && !claude.snap.working { return .sleep }
            return claude.snap.working || ide != nil ? .work : .drowsy
        }
        if claude.snap.working || ide != nil { return .work }
        if media.isPlaying { return .vibe }
        return nil
    }

    func reactToClaude() {
        if let f = claude.snap.finish, f.id != seenFinish {
            seenFinish = f.id
            celebrate(f)
        }
        let working = claude.snap.working
        defer { claudeWasWorking = working }
        guard working, !claudeWasWorking, mode == .ground, !stats.isOpen, anim != .cheer else { return }
        walkTarget = nil
        go(.work, 5)
    }

    /// Claude finished a task: cheer and say which one. No sound: the hop and the bubble are enough.
    func celebrate(_ f: ClaudeSnapshot.Finish) {
        let task = f.title.count > 70 ? String(f.title.prefix(68)) + "…" : f.title
        bubble.show("Done!", task, seconds: 7)
        if mode == .ground { walkTarget = nil; pendingHop = nil; go(.cheer, 2.4) }
    }

    /// Where Bitsy should be looking: the window you're typing in, else the mouse.
    func gazeTarget() -> CGPoint? {
        if typing, let id = world.activeID, let r = world.windows[id] {
            return CGPoint(x: r.midX, y: r.maxY - 80)   // chat boxes usually sit near the bottom
        }
        if CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved) < 3 {
            return world.toCG(NSEvent.mouseLocation)
        }
        return nil
    }

    // MARK: brain

    func brain(_ dt: Double) {
        switch anim {
        case .walk, .run:
            guard let tx = walkTarget else { pickNext(); return }
            let sp = anim == .walk ? 45.0 : 140.0, d = tx - x
            let mv = (d > 0 ? 1.0 : -1.0) * min(abs(d), sp * dt)
            x += mv
            energy = max(0, energy - dt * (anim == .walk ? 0.5 : 2))
            if abs(d) < 1 { walkTarget = nil; go(.idle, 1 + .random(in: 0...2)) }
            return
        case .sleep:
            energy = min(100, energy + dt * 4)
        default:
            energy = max(0, energy - dt * 0.08)
        }

        // past bedtime and you touched the Mac: startle awake (then stay up drowsy with you)
        if isNight && anim == .sleep && t > 1 && sinceInput() < 1.5 { go(.surprised, 1.0); return }
        // something to focus on started: drop what you're doing
        if let f = focusAnim, f != anim, [.idle, .think, .sleep, .dance, .jump, .vibe, .drowsy, .work].contains(anim), t > 0.4,
           !(anim == .work && f != .sleep) {
            go(f, f == .sleep ? 30 : 5); return
        }
        if typing && [.sleep, .dance, .think].contains(anim) && t > 0.5 { go(.idle, 1.5); return }

        guard t >= dur else { return }
        switch anim {
        case .crouch: launch()
        case .teeter: knockOff()
        case .land:
            if droppedByUser { droppedByUser = false; go(.surprised, 1.1) } else { go(.idle, 0.8 + .random(in: 0...1)) }
        default: pickNext()
        }
    }

    func pickNext() {
        if let id = pendingWindow { pendingWindow = nil; if goToWindow(id) { return } }
        if stats.isOpen { go(focusAnim ?? .idle, 2.5); return }
        if paused { go(focusAnim ?? [.idle, .idle, .think].randomElement()!, 3); return }
        if typing, let active = world.activeID {
            // go sit on the window you're using, then watch you type
            if supportID != active, let h = hopTargets(only: active).randomElement() { hop(h); return }
            go(focusAnim ?? .idle, 2.5)
            return
        }
        if isNight, let f = focusAnim { go(f, f == .sleep ? 30 : .random(in: 6...10)); return }   // no wandering at night
        if let f = focusAnim, Double.random(in: 0...1) < 0.85 { go(f, .random(in: 4...8)); return }

        let targets = hopTargets()
        let w: [(String, Double)] = [
            ("idle", 3), ("walk", 4), ("run", energy > 45 ? 1 : 0), ("sleep", energy < 30 ? 8 : 0.3),
            ("think", 0.8), ("work", 1.1), ("jump", energy > 25 ? 0.4 : 0), ("wave", 0.4),
            ("hop", targets.isEmpty || energy < 20 ? 0 : 3),
        ]
        var roll = Double.random(in: 0..<w.reduce(0) { $0 + $1.1 })
        var choice = "idle"
        for (k, v) in w { roll -= v; if roll < 0 { choice = k; break } }

        switch choice {
        case "hop":
            hop(targets.randomElement()!)
        case "walk", "run":
            guard let p = currentPlatform, p.x1 - p.x0 > 140 else { go(.idle, 2); return }
            var tx = x
            for _ in 0..<10 { tx = .random(in: (p.x0 + 30)...(p.x1 - 30)); if abs(tx - x) > 80 { break } }
            walkTarget = tx
            dir = tx > x ? 1 : -1
            go(Anim(rawValue: choice)!, 99)
        default:
            let a = Anim(rawValue: choice)!
            let d: [Anim: ClosedRange<Double>] = [.idle: 2...4, .sleep: 8...14, .wave: 1.8...2.2,
                                                  .think: 2.6...3.6, .work: 5...8, .jump: 1.7...1.7]
            go(a, .random(in: d[a] ?? 2...3))
        }
    }

    /// Platforms within jumping reach, with a landing x on each.
    func hopTargets(only id: Int? = nil) -> [(Platform, Double)] {
        var out: [(Platform, Double)] = []
        for p in world.platforms where p.x1 - p.x0 >= 70 {
            if let id, p.id != id { continue }
            if p.id == supportID && x >= p.x0 && x <= p.x1 { continue }
            let lx = min(max(x + .random(in: -60...60), p.x0 + 30), p.x1 - 30)
            let dxv = abs(lx - x), up = y - p.y
            if dxv < 40 && abs(up) < 20 { continue }
            if id == nil && (dxv > 800 || up > maxRise) { continue }   // heading to your active window ignores range
            out.append((p, lx))
        }
        return out
    }

    /// Super-jumps reach most of the way up the screen Bitsy is on.
    var maxRise: Double {
        let v = world.visible.first { x >= Double($0.minX) && x <= Double($0.maxX) } ?? world.visible.first ?? .zero
        return Double(v.height) * 0.85
    }

    func hop(_ target: (Platform, Double)) {
        pendingHop = target
        walkTarget = nil
        dir = target.1 > x ? 1 : -1
        go(.crouch, 0.2)
    }

    func launch() {
        if let c = pendingCling {
            if let to = clingPoint(c) { leap(to: to, id: nil); return }   // the leap keeps pendingCling and grabs on at the end
            pendingCling = nil
        }
        guard let (p, lx) = pendingHop else { go(.idle, 1); return }
        pendingHop = nil
        leap(to: CGPoint(x: lx, y: p.y), id: p.id)
    }

    func leap(to: CGPoint, id: Int?) {
        leapFrom = CGPoint(x: x, y: y)
        leapTo = to
        leapID = id
        // arc height H so the apex rises R above the start (a small hop down, or clear the target going up)
        let D = to.y - y, R = D < 0 ? -D + 60 : 45, b = 8 * D + 16 * R
        leapH = (b + (b * b - 64 * D * D).squareRoot()) / 32
        leapT = 0.45 + hypot(to.x - x, to.y - y) / 1400
        mode = .leap; supportID = nil; supportRect = nil
        go(.leap, 99)
    }

    // MARK: the window you're using

    /// You selected a window (a click, ⌘-Tab, the Dock, Mission Control, a new app): go there, on any display.
    /// It has to stay selected for a moment first, so a popup or notification that grabs focus doesn't send Bitsy off.
    func noticeClick() {
        let id = world.activeID
        if id != candidateID { candidateID = id; candidateSince = CACurrentMediaTime(); return }
        guard followClicks, !paused, !dragging, let id, id != lastActiveID,
              CACurrentMediaTime() - candidateSince > 0.45 else { return }
        lastActiveID = id
        if (mode == .ground && supportID == id) || (mode == .cling && clingID == id) { return }
        switch mode {
        case .ground where ![.crouch, .teeter, .land].contains(anim): goToWindow(id)
        case .cling: pendingWindow = id; letGo()                 // drop off this one, head over after landing
        case .ground, .fall, .leap: pendingWindow = id
        case .drag, .perch, .rope: break                                // docked in the notch: it stays there
        }
    }

    /// Jump onto a window: its top edge when a bit of it shows with headroom, otherwise grab its bottom
    /// edge (room below permitting) or its top edge and hang there. False when none of that is possible.
    @discardableResult
    func goToWindow(_ id: Int) -> Bool {
        guard mode == .ground, supportID != id, let r = world.windows[id] else { return false }
        if let h = hopTargets(only: id).randomElement() { hop(h); return true }
        let screen = world.visible.first { Double(r.maxY) >= Double($0.minY) && Double(r.maxY) <= Double($0.maxY) + 1 }
        for edge in [World.Edge.bottom, .top] {
            if edge == .bottom, Double(r.maxY) + 70 > Double(screen?.maxY ?? 0) { continue }   // nothing to dangle into
            let segs = world.edgeSegments(id, edge)
            guard let s = segs.min(by: { abs(($0.0 + $0.1) / 2 - x) < abs(($1.0 + $1.1) / 2 - x) }) else { continue }
            let lx = min(max(x, s.0 + 30), s.1 - 30)
            pendingCling = (id, edge, lx - Double(r.minX))
            walkTarget = nil; pendingHop = nil
            dir = lx > x ? 1 : -1
            go(.crouch, 0.2)
            return true
        }
        return false
    }

    /// Feet point while hanging from a window edge: the hands overlap the edge by a few pixels, like under the notch.
    func clingPoint(_ c: (id: Int, edge: World.Edge, dx: Double)) -> CGPoint? {
        guard let r = world.windows[c.id] else { return nil }
        return CGPoint(x: Double(r.minX) + c.dx, y: Double(c.edge == .bottom ? r.maxY : r.minY) + 69)
    }

    func grab(_ c: (id: Int, edge: World.Edge, dx: Double)) {
        clingID = c.id; clingEdge = c.edge; clingDX = c.dx
        mode = .cling; vx = 0; vy = 0; supportID = nil; supportRect = nil; walkTarget = nil; pendingHop = nil
        if let p = clingPoint(c) { x = p.x; y = p.y }
        go(.hang, .random(in: 10...16))
    }

    func letGo() {
        droppedByUser = false
        startFall()
    }

    /// Hang on while the window is there and this bit of its edge still shows; drop off when the arms give out.
    func followCling() {
        guard let id = clingID, let p = clingPoint((id, clingEdge, clingDX)),
              world.edgeSegments(id, clingEdge).contains(where: { p.x >= $0.0 - 8 && p.x <= $0.1 + 8 }) else { letGo(); return }
        x = p.x; y = p.y
        if typing && world.activeID == id { t = min(t, dur - 4) }   // you're working in it: keep holding on
        if t >= dur { letGo() }
    }

    // MARK: mouse

    func mouseDown(clicks: Int = 1) {
        downAt = NSEvent.mouseLocation
        dragging = false
        if clicks >= 2 {   // double-click: cancel the pending single click and send a screenshot instead
            pendingClick?.cancel()
            pendingClick = nil
            doubleClicked = true
            shareWindow()
        }
    }

    func mouseDragged() {
        guard let d = downAt else { return }
        let ml = NSEvent.mouseLocation
        if !dragging && hypot(ml.x - d.x, ml.y - d.y) > 4 {
            dragging = true
            if mode == .perch { autoPerched = false; stayOut = world.fullscreen; leaveIsland() }
            mode = .drag; supportID = nil; supportRect = nil; walkTarget = nil; pendingHop = nil; clingID = nil; pendingCling = nil
            go(.dangle, 99)
            stats.close()
            NSCursor.closedHand.set()
        }
        if dragging {
            let p = world.toCG(ml)
            x = p.x
            y = p.y + Pet.foot - 9 * Double(Pet.S)   // hold it by the top of its head
        }
    }

    func mouseUp() {
        guard downAt != nil else { return }
        downAt = nil
        if dragging {
            dragging = false
            NSCursor.openHand.set()
            // dropped near the notch: grab on and hang there
            let cursor = world.toCG(NSEvent.mouseLocation)
            notchLevel = 0
            if let n = world.notchRect(near: cursor) {
                if Pet.snapZone(n).contains(cursor) { enterIsland(auto: false, notch: n); return }   // only when the cursor touches the notch
                island.preview(0, notch: n, world: world)
            }
            droppedByUser = true
            startFall()
        } else if doubleClicked {
            doubleClicked = false
        } else {
            // wait to see whether this becomes a double-click
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingClick = nil
                self.stats.toggle()
                if self.stats.isOpen {
                    if self.media.now == nil { self.media.query() }
                    self.syncStats()
                    if self.mode == .ground { self.walkTarget = nil; self.pendingHop = nil; self.go(.surprised, 0.9) }
                }
            }
            pendingClick = work
            DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
        }
    }

    // MARK: drawing

    func render() {
        let o = NSPoint(x: (x - Pet.size / 2).rounded(), y: (world.H - y + Pet.foot - Pet.size).rounded())
        if o != lastOrigin { lastOrigin = o; panel.setFrameOrigin(o) }

        var f = frame(anim, t, dir)
        if anim == .idle || anim == .work, let g = gazeTarget() {
            let ddx = g.x - x, ddy = g.y - (y - 39)   // relative to the eyes
            if anim == .idle { f.pose.look = abs(ddx) < 40 ? 0 : (ddx > 0 ? 1 : -1); f.pose.dy = 0 }
            f.pose.lookY = ddy > 60 ? 1 : (ddy < -60 ? -1 : 0)
        }
        if mode == .rope { ropeDecorate(&f) }
        f.pose.headphones = media.isPlaying
        if mode == .drag && notchLevel == 2 {   // about to dock: excited
            f.pose.eyes = .happy; f.pose.mouth = .smile; f.pose.armL = .up2; f.pose.armR = .up2
        }
        if fanCtl.state.windy && mode != .perch {   // fans roaring: wind streaks blow past
            for i in 0..<3 {
                let ph = m(t * 1.4 + Double(i) / 3, 1)
                f.fx.append(FX(g: "wind", x: -3 + ph * 32, y: Double(9 + i * 6), c: rgb(0xE8EEF5), a: 0.45 * fade(ph)))
            }
        }
        if isNight {
            f.pose.nightcap = true
            if anim == .sleep {   // moon and twinkling stars
                f.fx.append(FX(g: "moon", x: 3, y: 2, c: rgb(0xF3E6B0), a: 0.9))
                for (i, s) in [(9.0, 4.0), (27.0, 8.0), (1.0, 11.0)].enumerated() {
                    f.fx.append(FX(g: i == 0 ? "spark" : "dot", x: s.0, y: s.1, c: rgb(0xFFF3C4), a: 0.35 + 0.65 * abs(sin(t * 1.3 + Double(i) * 2))))
                }
            }
        }
        if f != view.current { view.current = f; view.needsDisplay = true }

        if mode == .perch { bubble.hide() } else { bubble.follow(head: CGPoint(x: x, y: y - 50), world: world) }
        if stats.isOpen {
            if mode == .perch, let n = perchNotch { stats.place(head: CGPoint(x: n.midX, y: n.maxY - 48), world: world) }
            else { stats.place(head: CGPoint(x: x, y: y - 48), world: world) }
        }
    }

    /// What macOS currently grants Bitsy, written where it's easy to check when a permission seems stuck.
    func writePermissions() {
        let info: [String: Any] = [
            "screen_recording": CGPreflightScreenCaptureAccess(),
            "accessibility": AXIsProcessTrusted(),
            "checked": Date().timeIntervalSince1970,
            "app": Bundle.main.bundlePath,
        ]
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Bitsy")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let d = try? JSONSerialization.data(withJSONObject: info) { try? d.write(to: dir.appendingPathComponent("permissions.json")) }
    }

    func installFanHelper() {
        stats.model.fanNotice = "Waiting for your password…"
        fanCtl.install { [weak self] err in self?.stats.model.fanNotice = err ?? "Fan helper installed." }
    }

    // MARK: Dynamic Island

    /// The notch itself plus a few points around it.
    static func snapZone(_ n: CGRect) -> CGRect { CGRect(x: n.minX - 8, y: n.minY - 20, width: n.width + 16, height: n.height + 28) }

    func enterIsland(auto: Bool, notch: CGRect? = nil) {
        guard let n = notch ?? world.notchRect() else { return }
        perchNotch = n
        mode = .perch; vx = 0; vy = 0; supportID = nil; walkTarget = nil; pendingHop = nil
        autoPerched = auto
        go(.hang, 99)
        stats.close()
        bubble.hide()
        island.show(notch: n, world: world)
        panel.orderOut(nil)
    }

    func leaveIsland() {
        island.hide()
        panel.orderFrontRegardless()
    }

    /// Bitsy's face and the most useful bit of status for the island.
    func islandContent() -> IslandContent {
        var c = IslandContent()
        var p = frame(.idle, t).pose
        p.dy = 0
        let snap = claude.snap
        if let note = islandNote, Date().timeIntervalSince(note.at) < 3 {
            c.kind = .claudeDone
            c.text = note.text
            p.eyes = .happy
        } else if let f = snap.finish, Date().timeIntervalSince(f.at) < 10 {
            c.kind = .claudeDone
            c.text = "Done · \(f.title)"
            p.eyes = .happy
        } else if snap.working {
            c.kind = .claudeWorking
            let secs = Int(Date().timeIntervalSince(snap.workingSince ?? Date()))
            c.text = String(format: "Working · %d:%02d", secs / 60, secs % 60)
            p.eyes = blink(t) ? .blink : .focus
            p.look = 1
        } else if snap.state == .done {
            c.kind = .claudeDone
            c.text = "Your turn"
            p.eyes = .happy
        } else if let n = media.now, n.playing {
            c.kind = .music
            c.text = n.artist.isEmpty ? n.title : "\(n.title) — \(n.artist)"
            p.eyes = m(t, 4) < 2.5 ? .closed : .happy
        } else {
            c.kind = .clock
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            c.text = f.string(from: Date()) + (isNight ? " · bedtime" : "")
        }
        p.headphones = media.isPlaying
        if isNight {
            p.nightcap = true
            if !snap.working { p.eyes = m(t, 2.6) < 0.45 ? .blink : .focus }
        }
        c.pose = p
        c.musicPlaying = media.isPlaying
        c.artwork = media.artwork
        return c
    }

    func syncStats() {
        let m = stats.model
        m.name = name
        var doing = DOING[anim] ?? ""
        if mode == .cling {
            doing = "hanging on"
        } else if mode == .ground && anim == .work {
            doing = claude.snap.working ? "coding with Claude" : ide.map { "coding in \($0)" } ?? "coding"
        } else if typing && mode == .ground && anim == .idle {
            doing = "watching you type"
        } else if anim == .sleep && isNight {
            doing = "asleep, it's bedtime"
        }
        m.doing = doing
        m.claude = claude.snap
        m.usage = claude.snap.usage
        m.music = media.now
        m.artwork = media.artwork
        m.player = media.runningPlayer
        m.canShare = shareableWindow != nil
        m.fan = fanCtl.state
        if island.expanded { stats.sampleSystem() }
        stats.sampleSystem()
    }
}

func fmtDuration(_ s: Double) -> String {
    let s = Int(max(0, s)), mi = s / 60, h = mi / 60, d = h / 24
    if d > 0 { return "\(d)d\(h % 24)h" }
    if h > 0 { return "\(h)h\(mi % 60)m" }
    if mi > 0 { return "\(mi)m\(s % 60)s" }
    return "\(s)s"
}
