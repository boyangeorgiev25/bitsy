import SwiftUI

// When Bitsy is dropped on the MacBook notch it becomes a Dynamic Island: a black shape that grows out
// of the notch with Bitsy's face on the left and live status on the right. Click it and it springs open
// into a bigger island with one card at a time: Claude, Music, Mac, Fans.

struct IslandContent: Equatable {
    enum Kind: Equatable { case claudeWorking, claudeDone, music, clock }
    var kind = Kind.clock
    var text = ""
    var pose = Pose()
    var musicPlaying = false
    var artwork: NSImage?
}

final class IslandModel: ObservableObject {
    enum Phase { case hidden, near, target, compact, expanded }   // near/target: Bitsy is being dragged toward the notch
    enum Tab: String, CaseIterable {
        case claude, music, mac, fans
        var label: String { ["claude": "Claude", "music": "Music", "mac": "Mac", "fans": "Fans"][rawValue]! }
        var icon: String { ["claude": "sparkle", "music": "music.note", "mac": "cpu", "fans": "fan"][rawValue]! }
    }

    @Published var phase = Phase.hidden
    @Published var tab = Tab.claude
    @Published var content = IslandContent()
    @Published var musicOnly = false        // opened as a music player (no tabs)
    @Published var expandedHeight: CGFloat = 0   // measured from the content, so the island is as tall as what it shows
    var notch = CGSize(width: 190, height: 32)
    var onDragMove: () -> Void = {}
    var onDragEnd: () -> Void = {}
    var onExpand: (_ music: Bool) -> Void = { _ in }   // true: open straight to the music player
    var onDoubleTap: () -> Void = {}

    static let wingL: CGFloat = 50, wingR: CGFloat = 64, targetWing: CGFloat = 92, expandedW: CGFloat = 370, expandedBody: CGFloat = 198

    /// The black shape's size and horizontal offset from the notch centre in each phase.
    var shape: (size: CGSize, dx: CGFloat, radius: CGFloat) {
        switch phase {
        case .hidden: return (notch, 0, 8)
        case .near: return (CGSize(width: notch.width + 24, height: notch.height + 6), 0, 12)
        case .target: return (CGSize(width: notch.width + 2 * Self.targetWing, height: notch.height + 10), 0, 16)
        case .compact: return (CGSize(width: notch.width + Self.wingL + Self.wingR, height: notch.height), (Self.wingR - Self.wingL) / 2, 12)
        case .expanded: return (CGSize(width: Self.expandedW, height: expandedHeight > 0 ? expandedHeight : notch.height + Self.expandedBody), 0, 26)
        }
    }
}

private struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Flat top that flares into the menu bar like the notch does, rounded bottom; the radius animates.
/// `outlineOnly` leaves the top open, for drawing a border along the sides and bottom only.
struct IslandShape: Shape {
    var radius: CGFloat
    var flare: CGFloat = 6
    var outlineOnly = false
    var animatableData: CGFloat { get { radius } set { radius = newValue } }

    func path(in r: CGRect) -> Path {
        let k = min(radius, r.height / 2, r.width / 2), f = min(flare, r.height / 3)
        return Path { p in
            p.move(to: CGPoint(x: r.minX - f, y: r.minY))
            p.addQuadCurve(to: CGPoint(x: r.minX, y: r.minY + f), control: CGPoint(x: r.minX, y: r.minY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY - k))
            p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX + k, y: r.maxY), radius: k)
            p.addLine(to: CGPoint(x: r.maxX - k, y: r.maxY))
            p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.maxX, y: r.maxY - k), radius: k)
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY + f))
            p.addQuadCurve(to: CGPoint(x: r.maxX + f, y: r.minY), control: CGPoint(x: r.maxX, y: r.minY))
            if !outlineOnly { p.closeSubpath() }
        }
    }
}

/// Glowing border shown while Bitsy is dragged toward the notch: a soft pulse plus a highlight sweeping along it.
struct DockGlow: View {
    var radius: CGFloat
    var strong: Bool
    var accent: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let pulse = 0.65 + 0.35 * abs(sin(t * 3))
            let x = CGFloat((t * 0.55).truncatingRemainder(dividingBy: 1)) * 1.7 - 0.35
            let highlight = Color(red: 1, green: 0.84, blue: 0.72)
            IslandShape(radius: radius, outlineOnly: true)
                .stroke(LinearGradient(stops: [.init(color: accent.opacity(0.55), location: 0),
                                               .init(color: highlight, location: 0.5),
                                               .init(color: accent.opacity(0.55), location: 1)],
                                       startPoint: UnitPoint(x: x - 0.3, y: 0.5), endPoint: UnitPoint(x: x + 0.3, y: 0.5)),
                        style: StrokeStyle(lineWidth: strong ? 2 : 1.25, lineCap: .round, lineJoin: .round))
                .shadow(color: accent.opacity((strong ? 0.95 : 0.6) * pulse), radius: strong ? 4 : 2.5)
                .shadow(color: accent.opacity((strong ? 0.65 : 0.35) * pulse), radius: strong ? 16 : 9)
        }
    }
}

/// Bitsy drawn with the pixel rig, cropped to the head and body.
struct PetFace: View {
    var pose: Pose
    var scale: CGFloat = 2
    var body: some View {
        Canvas { ctx, _ in
            ctx.withCGContext { cg in
                cg.translateBy(x: -5 * scale, y: -9 * scale)
                var p = pose
                p.noShadow = true
                drawPet(cg, scale, p)
            }
        }
        .frame(width: 22 * scale, height: 14 * scale)
    }
}

struct IslandView: View {
    @ObservedObject var island: IslandModel
    @ObservedObject var m: StatsModel
    @Namespace private var tabNS

    private let accent = Color(cgColor: pal.body)
    private let soft = Color.white.opacity(0.08)
    private let muted = Color.white.opacity(0.55)
    private let green = Color(red: 0.48, green: 0.82, blue: 0.5)
    private let blue = Color(red: 0.55, green: 0.7, blue: 1)

    var body: some View {
        let s = island.shape
        ZStack(alignment: .top) {
            IslandShape(radius: s.radius).fill(Color.black)
            if island.phase == .expanded {
                IslandShape(radius: s.radius, outlineOnly: true).stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                    .transition(.opacity)
            }
            if island.phase == .near || island.phase == .target {
                DockGlow(radius: s.radius, strong: island.phase == .target, accent: accent)
            }
            if island.phase == .target {
                HStack(spacing: 0) {
                    Image(systemName: "arrow.down.circle.fill").font(.system(size: 15)).foregroundColor(accent)
                        .frame(width: IslandModel.targetWing)
                    Color.clear.frame(width: island.notch.width)
                    Text("Drop here").font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                        .frame(width: IslandModel.targetWing)
                }
                .frame(height: island.notch.height)
                .transition(.opacity)
            }
            if island.phase == .compact {   // only laid out when shown, so it never stretches the shape
                compact.transition(.opacity.animation(.easeInOut(duration: 0.22)))
            }
            if island.phase == .expanded {
                expanded.transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.28).delay(0.1)),
                                                removal: .opacity.animation(.easeIn(duration: 0.12))))
            }
        }
        .frame(width: s.size.width, height: s.size.height)
        .offset(x: s.dx)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // the shape morphs on a soft spring: long enough to read as one motion, damped so it doesn't wobble
        .animation(.spring(response: 0.55, dampingFraction: 0.88), value: island.phase)
        .animation(.spring(response: 0.5, dampingFraction: 0.88), value: island.musicOnly)
        .animation(.spring(response: 0.45, dampingFraction: 0.88), value: island.expandedHeight)
    }

    // MARK: compact

    private var compact: some View {
        HStack(spacing: 0) {
            PetFace(pose: island.content.pose, scale: 1.15).frame(width: IslandModel.wingL)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { island.onDoubleTap() }
                .onTapGesture { island.onExpand(true) }   // the avatar always opens the music player
            Color.clear.frame(width: island.notch.width)
            // right wing: only moving bars when music plays, tucked against the notch. No words, no status:
            // the expanded island has all of that, the bar should stay a glance.
            HStack(spacing: 0) {
                if island.content.musicPlaying {
                    equaliser(bars: 4, height: 12, width: 2.5).transition(.opacity)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 10)
            .frame(width: IslandModel.wingR)
            .animation(.easeInOut(duration: 0.25), value: island.content.musicPlaying)
        }
        .frame(height: island.notch.height)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { island.onDoubleTap() }
        .onTapGesture { island.onExpand(false) }
        .gesture(DragGesture(minimumDistance: 6)
            .onChanged { _ in island.onDragMove() }
            .onEnded { _ in island.onDragEnd() })
    }

    @ViewBuilder private var statusMark: some View {
        switch island.content.kind {
        case .claudeWorking:
            TimelineView(.animation(minimumInterval: 1 / 15)) { tl in
                let t = tl.date.timeIntervalSinceReferenceDate
                Circle().fill(green.opacity(0.55 + 0.45 * abs(sin(t * 3)))).frame(width: 7, height: 7)
            }
        case .claudeDone:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundColor(green)
        case .music:
            TimelineView(.animation(minimumInterval: 1 / 15)) { tl in
                let t = tl.date.timeIntervalSinceReferenceDate
                HStack(alignment: .bottom, spacing: 1.5) {
                    ForEach(0..<4) { i in
                        Capsule().fill(accent).frame(width: 2.5, height: 4 + 9 * abs(sin(t * (4 + Double(i) * 1.7) + Double(i))))
                    }
                }.frame(height: 13, alignment: .bottom)
            }
        case .clock:
            EmptyView()
        }
    }

    // MARK: expanded

    private var expanded: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                PetFace(pose: island.content.pose, scale: 1)
                Spacer(minLength: island.notch.width)
                if island.musicOnly {
                    Button(action: { withAnimation(.spring(response: 0.5, dampingFraction: 0.88)) { island.musicOnly = false } }) {
                        Image(systemName: "ellipsis").font(.system(size: 12, weight: .bold)).foregroundColor(muted)
                            .frame(width: 24, height: 20).contentShape(Rectangle())
                    }.buttonStyle(.plain).help("Claude, Mac and Fans")
                }
                Button(action: { island.phase = .compact }) {
                    Image(systemName: "chevron.up").font(.system(size: 11, weight: .bold)).foregroundColor(muted)
                        .frame(width: 24, height: 20).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            .frame(height: island.notch.height)

            if island.musicOnly {
                musicCard.transition(.opacity)
            } else {
            HStack(spacing: 6) {
                ForEach(IslandModel.Tab.allCases, id: \.self) { tab in
                    let on = island.tab == tab
                    Button(action: { withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) { island.tab = tab } }) {
                        HStack(spacing: 5) {
                            Image(systemName: tab.icon).font(.system(size: 10.5, weight: .semibold))
                            Text(tab.label).font(.system(size: 11.5, weight: .semibold))
                        }
                        .foregroundColor(on ? .black : .white.opacity(0.85))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background {
                            if on { Capsule().fill(accent).matchedGeometryEffect(id: "pill", in: tabNS) }
                            else { Capsule().fill(soft) }
                        }
                        .contentShape(Capsule())
                    }.buttonStyle(.plain)
                }
            }

            ZStack(alignment: .topLeading) {
                card(island.tab)
                    .id(island.tab)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 24)), removal: .opacity))
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .padding(.horizontal, 14).padding(.bottom, 12)
        .frame(width: IslandModel.expandedW)
        .fixedSize(horizontal: false, vertical: true)
        // report the natural height, and the black shape follows it
        .background(GeometryReader { g in Color.clear.preference(key: HeightKey.self, value: g.size.height) })
        .onPreferenceChange(HeightKey.self) { h in if h > 0, abs(h - island.expandedHeight) > 0.5 { island.expandedHeight = h } }
    }

    @ViewBuilder private func card(_ tab: IslandModel.Tab) -> some View {
        switch tab {
        case .claude: claudeCard
        case .music: musicCard
        case .mac: macCard
        case .fans: fansCard
        }
    }

    private var claudeCard: some View {
        let c = m.claude
        let secs = Int(Date().timeIntervalSince(c.workingSince ?? Date()))
        let (label, color): (String, Color) = switch c.state {
        case .working: (String(format: "Working · %d:%02d", secs / 60, secs % 60), green)
        case .done: ("Done, your turn", blue)
        case .idle: ("Idle", muted)
        }
        let task = c.working ? c.task : c.finish?.title
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(label).font(.system(size: 13.5, weight: .semibold)).foregroundColor(.white).lineLimit(1)
                if let task { Text(task).font(.system(size: 12)).foregroundColor(muted).lineLimit(1) }
                Spacer()
                if let model = c.model { chip(model) }
            }
            ForEach(usageRows, id: \.label) { row in
                meter(row.label, row.pct, accent, row.value)
            }
            HStack(spacing: 8) {
                Button(action: { m.onShare() }) {
                    HStack(spacing: 5) {
                        Image(systemName: "rectangle.on.rectangle.angled").font(.system(size: 10.5, weight: .semibold))
                        Text("Send window to Claude").font(.system(size: 11.5, weight: .semibold))
                    }
                    .foregroundColor(.black).padding(.horizontal, 11).padding(.vertical, 5)
                    .background(Capsule().fill(m.canShare ? accent : soft))
                }.buttonStyle(.plain).disabled(!m.canShare)
                Text(m.notice ?? c.service).font(.system(size: 11.5)).foregroundColor(muted).lineLimit(1)
            }
        }
    }

    private struct UsageRow { var label: String; var pct: Double; var value: String }

    private var usageRows: [UsageRow] {
        if let u = m.usage {
            return u.rows.map { UsageRow(label: $0.label, pct: $0.pct / 100, value: "\(Int($0.pct.rounded()))% · \($0.resets.replacingOccurrences(of: "resets ", with: ""))") }
        }
        let c = m.claude
        guard let start = c.blockStart else { return [UsageRow(label: "Session", pct: 0, value: "not started")] }
        return [UsageRow(label: "Session", pct: min(1, Date().timeIntervalSince(start) / (5 * 3600)),
                         value: "\(fmtTokens(c.blockTokens)) tok · est.")]
    }

    /// One row, like the phone's island: cover art, title and artist, transport.
    private var musicCard: some View {
        let playing = m.music?.playing == true
        return HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(soft)
                if let art = m.artwork {
                    Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .transition(.opacity)
                } else if playing {
                    equaliser(bars: 4, height: 22, width: 4)
                } else {
                    Image(systemName: "music.note").font(.system(size: 20, weight: .semibold)).foregroundColor(muted)
                }
            }
            .frame(width: 56, height: 56)
            .animation(.easeInOut(duration: 0.3), value: m.artwork == nil)
            VStack(alignment: .leading, spacing: 2) {
                if let n = m.music {
                    Text(n.title.isEmpty ? "Unknown track" : n.title).font(.system(size: 14, weight: .semibold)).foregroundColor(.white).lineLimit(1)
                    Text(n.artist).font(.system(size: 12)).foregroundColor(muted).lineLimit(1)
                } else {
                    Text("Nothing playing").font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
                    Text(m.player.map { "\($0) is open" } ?? "Open a player to start").font(.system(size: 12)).foregroundColor(muted)
                }
            }
            .id(m.music?.title)
            .transition(.opacity)
            Spacer(minLength: 6)
            HStack(spacing: 6) {
                roundButton("backward.fill", 30) { m.onMedia("previous track") }
                roundButton(playing ? "pause.fill" : "play.fill", 38) { m.onMedia("playpause") }
                roundButton("forward.fill", 30) { m.onMedia("next track") }
            }
            .opacity(m.player == nil ? 0.35 : 1)
            .disabled(m.player == nil)
        }
        .animation(.easeInOut(duration: 0.25), value: m.music?.title)
    }

    private func equaliser(bars: Int, height: CGFloat, width: CGFloat) -> some View {
        TimelineView(.animation(minimumInterval: 1 / 20)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: width * 0.6) {
                ForEach(0..<bars, id: \.self) { i in
                    Capsule().fill(accent)
                        .frame(width: width, height: height * (0.25 + 0.75 * abs(sin(t * (2.6 + Double(i) * 0.9) + Double(i) * 1.3))))
                }
            }.frame(height: height, alignment: .bottom)
        }
    }

    private var macCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            meter("CPU", m.cpu, blue, "\(Int((m.cpu * 100).rounded()))%")
            meter("Memory", m.memUsed / max(1, m.memTotal), Color(red: 0.73, green: 0.63, blue: 0.95),
                  String(format: "%.1f / %.0f GB", m.memUsed / 1_073_741_824, m.memTotal / 1_073_741_824))
            HStack(spacing: 8) {
                tile(m.battery.map { "\($0)%" } ?? "AC", m.battery == nil ? "power" : (m.charging ? "charging" : "battery"))
                tile(m.uptime, "uptime")
            }
        }
    }

    private var fansCard: some View {
        let f = m.fan
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ForEach(f.fans, id: \.index) { fan in
                    tile(fan.rpm < 50 ? "off" : "\(Int(fan.rpm).formatted()) rpm", "fan \(fan.index + 1)")
                }
            }
            HStack(spacing: 5) {
                ForEach(FanController.Mode.allCases, id: \.self) { mode in
                    let on = f.mode == mode
                    Button(action: { m.onFanMode(mode.rawValue) }) {
                        Text(mode.label).font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(on ? .black : .white.opacity(0.85))
                            .frame(maxWidth: .infinity).padding(.vertical, 5)
                            .background(Capsule().fill(on ? accent : soft))
                    }.buttonStyle(.plain)
                }
            }
            Text(m.fanNotice ?? f.error ?? f.reason).font(.system(size: 11.5)).foregroundColor(muted).lineLimit(1)
        }
    }

    // MARK: pieces

    private func chip(_ s: String) -> some View {
        Text(s).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundColor(muted)
            .padding(.horizontal, 7).padding(.vertical, 2).background(Capsule().fill(soft))
    }

    private func meter(_ label: String, _ v: Double, _ c: Color, _ value: String) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 12)).foregroundColor(.white.opacity(0.85)).frame(width: 60, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(soft)
                    Capsule().fill(c).frame(width: max(8, g.size.width * CGFloat(min(1, max(0, v)))))
                        .animation(.easeInOut(duration: 0.4), value: v)
                }
            }.frame(height: 7)
            Text(value).font(.system(size: 11, design: .monospaced)).foregroundColor(muted).frame(width: 112, alignment: .trailing).lineLimit(1)
        }
    }

    private func tile(_ v: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(v).font(.system(size: 15, weight: .bold, design: .monospaced)).foregroundColor(.white).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.system(size: 10.5)).foregroundColor(muted)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(soft))
    }

    private func roundButton(_ icon: String, _ size: CGFloat, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: size * 0.36, weight: .bold)).foregroundColor(.white)
                .frame(width: size, height: size).background(Circle().fill(soft))
        }.buttonStyle(.plain)
    }
}

final class IslandController {
    let model = IslandModel()
    private let panel: PetPanel
    private var monitor: Any?
    private(set) var isShown = false
    private var hideWork: DispatchWorkItem?

    var expanded: Bool { model.phase == .expanded }

    private let stats: StatsModel

    init(stats: StatsModel) {
        self.stats = stats
        panel = PetPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 320),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)   // above the menu bar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: IslandView(island: model, m: stats))
        model.onExpand = { [weak self] music in self?.expand(music: music) }
    }

    /// While Bitsy is dragged: 0 = away from the notch, 1 = getting close (glow), 2 = touching it (drop here).
    func preview(_ level: Int, notch: CGRect, world: World) {
        let want: IslandModel.Phase? = level == 2 ? .target : level == 1 ? .near : nil
        guard let want else {
            if model.phase == .near || model.phase == .target { hide() }
            return
        }
        if model.phase != want { show(notch: notch, world: world, phase: want) }
    }

    func show(notch: CGRect, world: World, phase: IslandModel.Phase = .compact) {
        hideWork?.cancel()
        if isShown { model.phase = phase; return }   // already out (e.g. the drop preview): just morph
        model.notch = notch.size
        let w: CGFloat = 600, h = notch.height + IslandModel.expandedBody + 80
        panel.setFrame(NSRect(x: notch.midX - w / 2, y: CGFloat(world.H) - notch.minY - h, width: w, height: h), display: false)
        model.phase = .hidden
        panel.orderFrontRegardless()
        isShown = true
        DispatchQueue.main.async { self.model.phase = phase }   // let it render once tucked in, then grow
    }

    func hide() {
        guard isShown else { return }
        collapseMonitor(false)
        model.phase = .hidden
        let work = DispatchWorkItem { [weak self] in self?.panel.orderOut(nil); self?.isShown = false }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    /// Opens on the Music tab whenever a player is running (that's what you reach for most), tabs kept so
    /// Claude, Mac and Fans are one click away. `music` is kept for callers; it no longer hides the tabs.
    func expand(music: Bool = false) {
        model.musicOnly = false
        if music || stats.player != nil || stats.music != nil { model.tab = .music }
        model.phase = .expanded
        collapseMonitor(true)
    }

    func collapse() {
        if model.phase == .expanded { model.phase = .compact }
        collapseMonitor(false)
    }

    private func collapseMonitor(_ on: Bool) {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        if on {
            monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.collapse() }
        }
    }

    /// Update the face/status, and let clicks outside the black shape fall through to whatever is underneath.
    func tick(content: IslandContent) {
        guard isShown else { return }
        if model.phase == .near || model.phase == .target { panel.ignoresMouseEvents = true; return }
        if model.content != content { model.content = content }
        let s = model.shape, f = panel.frame
        let rect = NSRect(x: f.midX + s.dx - s.size.width / 2, y: f.maxY - s.size.height, width: s.size.width, height: s.size.height)
        let inside = rect.contains(NSEvent.mouseLocation) && model.phase != .near && model.phase != .target
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
    }
}
