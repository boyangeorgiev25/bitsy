import SwiftUI
import BitsyKit

// MARK: popup

final class StatsModel: ObservableObject {
    @Published var name = "Bitsy"
    @Published var doing = ""
    @Published var claude = ClaudeSnapshot()
    @Published var music: NowPlaying?
    @Published var artwork: NSImage?
    @Published var player: String?
    @Published var notice: String?
    @Published var canShare = false
    @Published var cpu = 0.0
    @Published var memUsed = 0.0
    @Published var memTotal = 1.0
    @Published var battery: Int? = nil
    @Published var charging = false
    @Published var uptime = ""
    var onMedia: (String) -> Void = { _ in }
    var onShare: () -> Void = {}
    @Published var usage: UsageLimits?
    @Published var fan = FanController.State()
    @Published var fanNotice: String?
    var onFanMode: (String) -> Void = { _ in }
    var onInstallFans: () -> Void = {}
    var onClose: () -> Void = {}
}

struct StatsView: View {
    @ObservedObject var m: StatsModel
    private let accent = Color(cgColor: pal.body)
    private let bg = Color(red: 0.122, green: 0.114, blue: 0.106)
    private let tile = Color(red: 0.16, green: 0.15, blue: 0.14)
    private let line = Color(red: 0.25, green: 0.23, blue: 0.21)
    private let muted = Color(red: 0.6, green: 0.56, blue: 0.53)
    private let text = Color(red: 0.94, green: 0.91, blue: 0.89)
    private let green = Color(red: 0.48, green: 0.78, blue: 0.49)
    private let blue = Color(red: 0.55, green: 0.69, blue: 0.95)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(m.name.uppercased()).font(.system(size: 15, weight: .heavy, design: .monospaced)).foregroundColor(accent)
                Text(m.doing).font(.system(size: 12)).foregroundColor(muted).lineLimit(1)
                Spacer()
                Button(action: { m.onClose() }) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundColor(muted)
                        .frame(width: 18, height: 18).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }

            claudeSection

            if m.player != nil { musicRow }

            macSection
        }
        .padding(14)
        .frame(width: 300)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(bg))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(line, lineWidth: 1))
    }

    // MARK: sections

    private var claudeSection: some View {
        let c = m.claude
        let (label, color): (String, Color) = switch c.state {
        case .working: ("Working", green)
        case .done: ("Done, your turn", blue)
        case .idle: ("Idle", muted)
        }
        let detail: String = {
            if c.working {
                let more = c.activeSessions > 1 ? " · \(c.activeSessions) sessions" : ""
                return "in \(c.project ?? "a project")\(more)"
            }
            guard let last = c.lastActive else { return "No Claude Code activity today" }
            return "last active \(fmtDuration(Date().timeIntervalSince(last))) ago\(c.project.map { " in \($0)" } ?? "")"
        }()

        return VStack(alignment: .leading, spacing: 8) {
            heading("CLAUDE CODE")
            HStack(spacing: 7) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(label).font(.system(size: 13, weight: .semibold)).foregroundColor(text)
                Spacer()
                if let model = c.model {
                    Text(model).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundColor(muted)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(tile))
                }
            }
            Text(detail).font(.system(size: 11.5)).foregroundColor(muted).lineLimit(1).padding(.top, -4)

            if let u = m.usage {
                ForEach(u.rows, id: \.label) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(row.label).font(.system(size: 12)).foregroundColor(text.opacity(0.85))
                            Spacer()
                            Text("\(Int(row.pct.rounded()))% · \(row.resets)").font(.system(size: 11, design: .monospaced)).foregroundColor(muted)
                        }
                        bar(row.pct / 100, accent)
                    }
                }
            } else if let start = c.blockStart {
                HStack {
                    Text("Session (estimate)").font(.system(size: 12)).foregroundColor(text.opacity(0.85))
                    Spacer()
                    Text("\(fmtTokens(c.blockTokens)) tokens since \(start.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 11, design: .monospaced)).foregroundColor(muted)
                }
            }

            HStack(spacing: 6) {
                num("\(c.todayMessages)", "replies today")
                num(fmtTokens(c.todayTokens), "tokens today")
                num("\(c.todaySessions)", "sessions")
            }

            // "All Systems Operational" is noise; only an incident earns a line.
            if ["minor", "major", "critical", "maintenance"].contains(c.serviceLevel) {
                HStack(spacing: 6) {
                    Circle().fill(serviceColor(c.serviceLevel)).frame(width: 6, height: 6)
                    Text(c.service).font(.system(size: 11)).foregroundColor(muted).lineLimit(1)
                }
            }

            Button(action: { m.onShare() }) {
                HStack(spacing: 6) {
                    Image(systemName: "rectangle.on.rectangle.angled").font(.system(size: 11, weight: .semibold))
                    Text("Send window to Claude").font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(m.canShare ? bg : muted)
                .frame(maxWidth: .infinity).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(m.canShare ? accent : tile))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!m.canShare)
            if let n = m.notice {
                Text(n).font(.system(size: 11)).foregroundColor(muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// CPU, memory, power and fans as one row of tiles, with the fan mode picker underneath.
    /// The old per-metric bars and the uptime tile cost a lot of height for numbers nobody acts on.
    private var macSection: some View {
        let f = m.fan
        let fanRpm = f.fans.map(\.rpm).max() ?? 0
        let memGB = m.memUsed / 1_073_741_824, totalGB = m.memTotal / 1_073_741_824
        let mem = memGB >= 10 ? String(format: "%.0f", memGB) : String(format: "%.1f", memGB)
        return VStack(alignment: .leading, spacing: 8) {
            heading("YOUR MAC")
            HStack(spacing: 6) {
                num("\(Int((m.cpu * 100).rounded()))%", "cpu")
                num("\(mem) GB", String(format: "of %.0f GB", totalGB))
                num(m.battery.map { "\($0)%" } ?? "AC", m.battery == nil ? "power" : (m.charging ? "charging" : "battery"))
                if !f.fans.isEmpty {
                    num(fanRpm < 50 ? "off" : "\(Int(fanRpm).formatted())", f.fans.count > 1 ? "fans rpm" : "fan rpm")
                }
            }
            if !f.fans.isEmpty {
                HStack(spacing: 4) {
                    ForEach(FanController.Mode.allCases, id: \.self) { mode in
                        let on = f.mode == mode
                        Button(action: { m.onFanMode(mode.rawValue) }) {
                            Text(mode.label).font(.system(size: 11, weight: .semibold))
                                .foregroundColor(on ? bg : text)
                                .frame(maxWidth: .infinity).padding(.vertical, 5)
                                .background(RoundedRectangle(cornerRadius: 7).fill(on ? accent : tile))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
                // The caption is worth a line when Bitsy is actually doing something to the fans,
                // or when something went wrong. "macOS controls the fans" is the default and stays silent.
                if let n = m.fanNotice ?? f.error {
                    Text(n).font(.system(size: 11)).foregroundColor(muted).fixedSize(horizontal: false, vertical: true)
                } else if f.appliedPct != nil || f.mode != .auto {
                    Text(f.reason).font(.system(size: 11)).foregroundColor(muted).fixedSize(horizontal: false, vertical: true)
                }
                if !f.helperInstalled {
                    Button(action: { m.onInstallFans() }) {
                        Text("Install fan helper…").font(.system(size: 12, weight: .semibold)).foregroundColor(text)
                            .frame(maxWidth: .infinity).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 8).fill(tile))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(line))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    /// One line: what's playing, and the transport buttons. No heading; the note icon says enough.
    private var musicRow: some View {
        let playing = m.music?.playing == true
        let title = m.music?.title.isEmpty == false ? m.music!.title : "Nothing playing"
        let sub = m.music.map { $0.artist } ?? (m.player ?? "")
        return HStack(spacing: 8) {
            if let art = m.artwork {
                Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 22, height: 22).clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else {
                Image(systemName: playing ? "music.note" : "music.note.list")
                    .font(.system(size: 11, weight: .semibold)).foregroundColor(playing ? accent : muted)
                    .frame(width: 22)
            }
            (Text(title).font(.system(size: 12, weight: .semibold)).foregroundColor(text)
             + Text(sub.isEmpty ? "" : "  ·  \(sub)").font(.system(size: 11)).foregroundColor(muted))
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            control("backward.fill", "previous track")
            control(playing ? "pause.fill" : "play.fill", "playpause")
            control("forward.fill", "next track")
        }
        .padding(.vertical, 2)
    }

    // MARK: pieces

    private func heading(_ s: String) -> some View {
        Text(s).font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(1).foregroundColor(muted).padding(.top, 2)
    }

    private func bar(_ v: Double, _ c: Color) -> some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(tile)
                RoundedRectangle(cornerRadius: 2).fill(c).frame(width: g.size.width * CGFloat(min(1, max(0, v))))
            }
        }.frame(height: 8)
    }

    private func num(_ v: String, _ label: String) -> some View {
        VStack(spacing: 1) {
            Text(v).font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundColor(text).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.system(size: 10)).foregroundColor(muted).lineLimit(1)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(tile))
    }

    private func control(_ icon: String, _ cmd: String) -> some View {
        Button(action: { m.onMedia(cmd) }) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundColor(text)
                .frame(width: 28, height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(tile))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func serviceColor(_ level: String) -> Color {
        switch level {
        case "none": return green
        case "minor", "maintenance": return Color(red: 0.95, green: 0.8, blue: 0.4)
        case "major", "critical": return Color(red: 0.95, green: 0.4, blue: 0.4)
        default: return muted
        }
    }
}

final class StatsController {
    let model = StatsModel()
    let sys = SystemStats()
    private let panel: NSPanel
    private let host: NSHostingView<StatsView>
    private var monitor: Any?
    private(set) var isOpen = false

    init() {
        host = NSHostingView(rootView: StatsView(m: model))
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 420),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = host
        model.onClose = { [weak self] in self?.close() }
        _ = sys.cpu()   // prime the CPU delta
    }

    func sampleSystem() {
        model.cpu = sys.cpu()
        let mem = sys.memory()
        model.memUsed = mem.used
        model.memTotal = mem.total
        let b = sys.battery()
        model.battery = b?.pct
        model.charging = b?.charging ?? false
        model.uptime = fmtDuration(ProcessInfo.processInfo.systemUptime)
        fit()
    }

    /// Content height changes with the music section and notices.
    private func fit() {
        guard isOpen else { return }
        let s = host.fittingSize
        if abs(s.height - panel.frame.height) > 0.5 {
            let top = panel.frame.maxY
            panel.setFrame(NSRect(x: panel.frame.minX, y: top - s.height, width: s.width, height: s.height), display: true)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        model.notice = nil
        panel.setContentSize(host.fittingSize)
        panel.orderFrontRegardless()
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.close() }
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        panel.orderOut(nil)
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }

    func toggle() { isOpen ? close() : open() }

    /// Sit above Bitsy's head (CG point), or below its feet if there's no room.
    func place(head: CGPoint, world: World) {
        let size = panel.frame.size, H = world.H
        let pc = NSPoint(x: head.x, y: H - head.y)
        guard let scr = NSScreen.screens.first(where: { $0.frame.contains(pc) }) ?? NSScreen.main else { return }
        let vf = scr.visibleFrame
        var ox = head.x - size.width / 2
        var oy = H - head.y + 10
        if oy + size.height > vf.maxY { oy = H - (head.y + 48) - 8 - size.height }
        ox = min(max(ox, vf.minX + 8), vf.maxX - size.width - 8)
        oy = min(max(oy, vf.minY + 4), vf.maxY - size.height - 4)
        let o = NSPoint(x: ox.rounded(), y: oy.rounded())
        if panel.frame.origin != o { panel.setFrameOrigin(o) }
    }
}
