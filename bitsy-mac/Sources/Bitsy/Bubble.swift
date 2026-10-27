import SwiftUI

// Speech bubble over Bitsy's head, e.g. "Done! · Fix the login bug". Click it to jump to Claude.

final class BubbleModel: ObservableObject {
    @Published var title = ""
    @Published var detail = ""
    var onClick: () -> Void = {}
}

struct BubbleView: View {
    @ObservedObject var m: BubbleModel
    private let bg = Color(red: 0.122, green: 0.114, blue: 0.106)
    private let line = Color(red: 0.25, green: 0.23, blue: 0.21)

    var body: some View {
        VStack(spacing: -1) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 15))
                    .foregroundColor(Color(red: 0.48, green: 0.83, blue: 0.54))
                VStack(alignment: .leading, spacing: 1) {
                    Text(m.title).font(.system(size: 13, weight: .bold)).foregroundColor(.white)
                    Text(m.detail).font(.system(size: 11.5)).foregroundColor(Color(white: 0.72)).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(maxWidth: 250, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(bg))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(line))
            Tail().fill(bg).frame(width: 14, height: 8)
        }
        .fixedSize()
        .contentShape(Rectangle())
        .onTapGesture { m.onClick() }
    }

    struct Tail: Shape {
        func path(in r: CGRect) -> Path {
            Path { p in p.move(to: .zero); p.addLine(to: CGPoint(x: r.maxX, y: 0)); p.addLine(to: CGPoint(x: r.midX, y: r.maxY)); p.closeSubpath() }
        }
    }
}

final class BubbleController {
    let model = BubbleModel()
    private let panel: NSPanel
    private let host: NSHostingView<BubbleView>
    private var until = Date.distantPast
    private(set) var isShown = false

    init() {
        host = NSHostingView(rootView: BubbleView(m: model))
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 250, height: 60),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = host
    }

    /// What a click on the bubble does this time (nil: the default, which brings Claude forward).
    private(set) var action: (() -> Void)?

    func show(_ title: String, _ detail: String, seconds: Double, action: (() -> Void)? = nil) {
        self.action = action
        model.title = title
        model.detail = detail
        panel.setContentSize(host.fittingSize)
        until = Date().addingTimeInterval(seconds)
        if !isShown {
            isShown = true
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.18; panel.animator().alphaValue = 1 }
        }
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; panel.animator().alphaValue = 0 }) { [panel] in panel.orderOut(nil) }
    }

    /// Keep the tail pointing at Bitsy's head (CG point); hide when time is up.
    func follow(head: CGPoint, world: World) {
        guard isShown else { return }
        if Date() > until { hide(); return }
        let s = panel.frame.size, H = CGFloat(world.H)
        let pc = NSPoint(x: head.x, y: H - head.y)
        let vf = (NSScreen.screens.first { $0.frame.contains(pc) } ?? NSScreen.main)?.visibleFrame ?? .zero
        let x = min(max(head.x - s.width / 2, vf.minX + 6), vf.maxX - s.width - 6)
        let y = min(H - head.y + 4, vf.maxY - s.height)
        let o = NSPoint(x: x.rounded(), y: y.rounded())
        if panel.frame.origin != o { panel.setFrameOrigin(o) }
    }
}
