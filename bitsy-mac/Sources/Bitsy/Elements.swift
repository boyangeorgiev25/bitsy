import AppKit
import ApplicationServices

// Seeing and pressing a window's buttons, links and fields through Accessibility, so Claude can work a window
// from a short numbered list instead of a screenshot and guessed coordinates.

enum Elements {
    private static let lock = NSLock()
    private static var refs: [Int: AXUIElement] = [:]
    private static var refsPID: pid_t = 0

    private static let interactive: Set<String> = [
        "AXButton", "AXLink", "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXCheckBox", "AXRadioButton",
        "AXPopUpButton", "AXMenuButton", "AXTab", "AXMenuItem", "AXDisclosureTriangle", "AXSlider", "AXIncrementor",
    ]
    private static let kinds = [
        "AXButton": "button", "AXLink": "link", "AXTextField": "text field", "AXTextArea": "text area", "AXSearchField": "search field",
        "AXComboBox": "combo box", "AXCheckBox": "checkbox", "AXRadioButton": "radio", "AXPopUpButton": "pop-up",
        "AXMenuButton": "menu button", "AXTab": "tab", "AXMenuItem": "menu item", "AXDisclosureTriangle": "disclosure",
        "AXSlider": "slider", "AXIncrementor": "stepper", "AXGroup": "clickable", "AXRow": "row", "AXCell": "cell",
    ]
    private static let attrs = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
                                kAXValueAttribute, kAXChildrenAttribute, kAXPositionAttribute, kAXSizeAttribute] as CFArray

    /// The numbered list of what can be pressed or typed into in the app's front window, top to bottom.
    static func list(pid: pid_t, query: String?, limit: Int = 200) -> [String: Any] {
        guard AXIsProcessTrusted() else { return ["error": "Bitsy needs Accessibility permission."] }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        guard let win = AXReader.attr(app, kAXFocusedWindowAttribute) ?? AXReader.attr(app, kAXMainWindowAttribute) else {
            return ["error": "That app has no window open."]
        }
        let root = win as! AXUIElement
        let frame = Self.frame(root) ?? .zero
        var found: [(AXUIElement, String, String, CGRect)] = []   // element, kind, label, frame
        var stack = [root], nodes = 0
        let deadline = Date().addingTimeInterval(4)
        let q = query?.lowercased().trimmingCharacters(in: .whitespaces) ?? ""
        while let el = stack.popLast(), nodes < 15_000, Date() < deadline {
            nodes += 1
            var raw: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(el, attrs, [], &raw) == .success, let v = raw as? [AnyObject], v.count == 8 else { continue }
            let role = v[0] as? String ?? "", sub = v[1] as? String ?? ""
            let r = rect(v[6], v[7])
            if let r, !r.intersects(frame) { continue }   // off screen: skip it and what's inside
            var pressable = interactive.contains(role)
            if !pressable, ["AXGroup", "AXRow", "AXCell", "AXStaticText", "AXImage"].contains(role) {
                var names: CFArray?
                pressable = AXUIElementCopyActionNames(el, &names) == .success && ((names as? [String])?.contains(kAXPressAction) ?? false)
                    && role != "AXStaticText"
            }
            if pressable, let r, r.width > 1, r.height > 1 {
                let secure = sub == "AXSecureTextField"
                var label = [v[2], v[3]].compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? ""
                if label.isEmpty { label = innerText(el) }
                var kind = kinds[role] ?? "clickable"
                if secure { kind = "password field" }
                else if let s = v[4] as? String, !s.isEmpty, ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"].contains(role) {
                    label += " = \"\(String(s.prefix(60)))\""
                } else if let n = v[4] as? NSNumber, ["AXCheckBox", "AXRadioButton"].contains(role) { label += n.boolValue ? " (on)" : " (off)" }
                if !label.isEmpty || role != "AXGroup" {
                    if q.isEmpty || label.lowercased().contains(q) { found.append((el, kind, label, r)) }
                }
                if !["AXGroup", "AXRow", "AXCell"].contains(role) { continue }   // a button's insides are just its label
            }
            if let kids = v[5] as? [AXUIElement] { stack.append(contentsOf: kids.reversed()) }
        }
        found.sort { abs($0.3.minY - $1.3.minY) > 4 ? $0.3.minY < $1.3.minY : $0.3.minX < $1.3.minX }   // reading order
        lock.lock(); refs = [:]; refsPID = pid
        var lines: [String] = []
        for (i, f) in found.prefix(limit).enumerated() {
            refs[i + 1] = f.0
            let label = f.2.replacingOccurrences(of: "\n", with: " ")
            lines.append("[\(i + 1)] \(f.1)\(label.isEmpty ? "" : " \"\(String(label.prefix(90)))\"")")
        }
        lock.unlock()
        var out: [String: Any] = ["app": NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?", "elements": lines.joined(separator: "\n")]
        if let t = AXReader.attr(root, kAXTitleAttribute) as? String { out["window"] = t }
        if found.count > limit { out["more"] = "\(found.count - limit) more; pass a query to narrow it down." }
        if found.isEmpty { out["elements"] = q.isEmpty ? "Nothing pressable found." : "Nothing matching \"\(q)\"." }
        return out
    }

    /// The element from the last list, its app, and where it is on screen.
    static func get(_ ref: Int) -> (AXUIElement, pid_t, CGRect)? {
        lock.lock(); defer { lock.unlock() }
        guard let el = refs[ref], let r = frame(el) else { return nil }
        return (el, refsPID, r)
    }

    static func isSecure(_ el: AXUIElement) -> Bool { AXReader.attr(el, kAXSubroleAttribute) as? String == "AXSecureTextField" }

    static func describe(_ el: AXUIElement) -> String {
        let role = AXReader.attr(el, kAXRoleAttribute) as? String ?? ""
        let label = [kAXTitleAttribute, kAXDescriptionAttribute].compactMap { AXReader.attr(el, $0) as? String }.first { !$0.isEmpty } ?? innerText(el)
        return "\(kinds[role] ?? "element") \"\(label.prefix(60))\""
    }

    private static func innerText(_ el: AXUIElement, depth: Int = 0) -> String {
        guard depth < 4, let kids = AXReader.attr(el, kAXChildrenAttribute) as? [AXUIElement] else { return "" }
        var parts: [String] = []
        for k in kids.prefix(12) {
            if let s = (AXReader.attr(k, kAXValueAttribute) as? String) ?? (AXReader.attr(k, kAXTitleAttribute) as? String)
                ?? (AXReader.attr(k, kAXDescriptionAttribute) as? String), !s.trimmingCharacters(in: .whitespaces).isEmpty {
                parts.append(s.trimmingCharacters(in: .whitespacesAndNewlines))
            } else {
                let t = innerText(k, depth: depth + 1); if !t.isEmpty { parts.append(t) }
            }
            if parts.joined(separator: " ").count > 100 { break }
        }
        return parts.joined(separator: " · ")
    }

    private static func frame(_ el: AXUIElement) -> CGRect? { rect(AXReader.attr(el, kAXPositionAttribute), AXReader.attr(el, kAXSizeAttribute)) }

    private static func rect(_ pos: AnyObject?, _ size: AnyObject?) -> CGRect? {
        guard let pos, let size, CFGetTypeID(pos) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pos as! AXValue, .cgPoint, &p); AXValueGetValue(size as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }
}
