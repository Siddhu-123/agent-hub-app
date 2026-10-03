import SwiftUI
import AppKit
import HubCore

/// Polls the live feed, the job store and the job logs once a second and builds the session trees.
@MainActor
final class TreeModel: ObservableObject {
    @Published private(set) var roots: [HubNode] = []
    @Published private(set) var tails: [String: [String]] = [:]
    @Published private(set) var sessions: [String: LiveSession] = [:]
    @Published private(set) var jobs: [String: Job] = [:]
    @Published private(set) var detail = ""
    /// When each node was first seen active; drives the dispatch flash.
    private(set) var firstActive: [String: Date] = [:]
    var detailId: String?
    private var timer: Timer?
    private var loading = false
    private var loadedOnce = false

    func start(paths: HubPaths, modelHarness: @escaping @MainActor () -> [String: String]) {
        guard timer == nil else { return }
        refresh(paths: paths, modelHarness: modelHarness())
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] t in
            // Stops itself if the model went away without onDisappear.
            guard self != nil else { t.invalidate(); return }
            Task { @MainActor in self?.refresh(paths: paths, modelHarness: modelHarness()) }
        }
        RunLoop.current.add(t, forMode: .common)
        timer = t
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func refresh(paths: HubPaths, modelHarness: [String: String]) {
        guard !loading else { return }
        loading = true
        let detailId = self.detailId
        DispatchQueue.global(qos: .userInitiated).async {
            let now = Date()
            let live = LiveFeed(paths: paths).sessions(now: now)
            let all = JobStore(paths: paths).all()
            let roots = HubTree.build(sessions: live, jobs: all, modelHarness: modelHarness, now: now)
            var tails: [String: [String]] = [:]
            func walk(_ n: HubNode) {
                if n.role == .worker, let id = n.jobId { tails[id] = TreeModel.lines(JobLog.tail(paths, id, maxBytes: 6_000), keep: 40) }
                n.children.forEach(walk)
            }
            roots.forEach(walk)
            var detail = ""
            if let detailId, detailId.hasPrefix("j:") { detail = TreeModel.readable(JobLog.tail(paths, String(detailId.dropFirst(2)), maxBytes: 96_000)) }
            let sessions = Dictionary(live.map { ("s:\($0.platform):\($0.sessionId)", $0) }, uniquingKeysWith: { a, _ in a })
            let jobs = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            Task { @MainActor in
                self.loading = false
                self.track(roots, now: now)
                if self.roots != roots { self.roots = roots }
                if self.tails != tails { self.tails = tails }
                self.sessions = sessions
                self.jobs = jobs
                if self.detail != detail { self.detail = detail }
            }
        }
    }

    private func track(_ roots: [HubNode], now: Date) {
        var seen = Set<String>()
        func walk(_ n: HubNode) {
            if n.active {
                seen.insert(n.id)
                // Nodes already running when the view opens do not flash.
                if firstActive[n.id] == nil { firstActive[n.id] = loadedOnce ? now : .distantPast }
            }
            n.children.forEach(walk)
        }
        roots.forEach(walk)
        firstActive = firstActive.filter { seen.contains($0.key) }
        loadedOnce = true
    }

    nonisolated static func lines(_ text: String, keep: Int) -> [String] {
        Array(text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { pretty(String($0)) }
            .flatMap { $0.split(separator: "\n").map(String.init) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(keep))
    }

    nonisolated static func readable(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { pretty(String($0)) }.joined(separator: "\n")
    }

    /// Worker CLIs stream JSON events (codex exec --json, claude -p stream-json): show them as terminal lines.
    /// Plain text passes through; JSON events with nothing worth showing are dropped.
    nonisolated static func pretty(_ line: String) -> String? {
        guard line.hasPrefix("{"), let data = line.data(using: .utf8),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let type = j["type"] as? String else { return line }
        func clip(_ s: String) -> String { let one = s.replacingOccurrences(of: "\n", with: " "); return one.count > 220 ? String(one.prefix(220)) + "…" : one }
        if let item = j["item"] as? [String: Any] {
            switch (type, item["type"] as? String ?? "") {
            case ("item.started", "command_execution"):
                var cmd = item["command"] as? String ?? ""
                for shell in ["/bin/zsh -lc ", "/bin/bash -lc ", "bash -lc "] where cmd.hasPrefix(shell) {
                    cmd = String(cmd.dropFirst(shell.count)).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                }
                return "$ " + clip(cmd)
            case ("item.completed", "command_execution"):
                guard let code = item["exit_code"] as? Int, code != 0 else { return nil }
                return "  exit \(code)"
            case ("item.completed", "agent_message"), ("item.completed", "reasoning"):
                return (item["text"] as? String).map { "› " + clip($0) }
            case ("item.completed", "file_change"):
                let files = (item["changes"] as? [[String: Any]])?.compactMap { $0["path"] as? String } ?? []
                return "✎ " + clip(files.joined(separator: ", "))
            case ("item.completed", "error"):
                return "error: " + clip(item["message"] as? String ?? "")
            default: return nil
            }
        }
        if type == "assistant", let content = (j["message"] as? [String: Any])?["content"] as? [[String: Any]] {
            let parts = content.compactMap { c -> String? in
                if c["type"] as? String == "text" { return (c["text"] as? String).map { "› " + clip($0) } }
                if c["type"] as? String == "tool_use" {
                    let input = c["input"] as? [String: Any] ?? [:]
                    let arg = input["command"] ?? input["file_path"] ?? input["pattern"] ?? input["description"] ?? ""
                    return "$ \(c["name"] as? String ?? "tool") " + clip("\(arg)")
                }
                return nil
            }
            return parts.isEmpty ? nil : parts.joined(separator: "\n")
        }
        if type == "result" { return (j["result"] as? String).map { "── result ──\n" + $0 } }
        if type == "error" { return "error: " + clip(j["message"] as? String ?? "\(j)") }
        return nil
    }
}

// MARK: Layout

struct PlacedNode: Identifiable {
    let node: HubNode
    let frame: CGRect
    let parent: CGRect?
    var id: String { node.id }
}

enum TreeLayout {
    static let hGap: CGFloat = 36, vGap: CGFloat = 96, rootGap: CGFloat = 140, margin: CGFloat = 60

    static func size(_ role: HubNode.Role) -> CGSize {
        switch role {
        case .main: return CGSize(width: 400, height: 250)
        case .subagent: return CGSize(width: 300, height: 196)
        case .worker: return CGSize(width: 340, height: 230)
        case .broker: return CGSize(width: 230, height: 112)
        case .check: return CGSize(width: 250, height: 112)
        }
    }

    static func span(_ n: HubNode) -> CGFloat {
        let kids = n.children.map(span)
        let row = kids.reduce(0, +) + hGap * CGFloat(max(0, kids.count - 1))
        return max(size(n.role).width, row)
    }

    static func place(_ roots: [HubNode]) -> (nodes: [PlacedNode], size: CGSize) {
        var out: [PlacedNode] = []
        var maxY: CGFloat = 0
        func put(_ n: HubNode, left: CGFloat, top: CGFloat, parent: CGRect?) {
            let s = size(n.role), w = span(n)
            let frame = CGRect(x: left + (w - s.width) / 2, y: top, width: s.width, height: s.height)
            out.append(PlacedNode(node: n, frame: frame, parent: parent))
            maxY = max(maxY, frame.maxY)
            let row = n.children.map(span).reduce(0, +) + hGap * CGFloat(max(0, n.children.count - 1))
            var x = left + (w - row) / 2
            for c in n.children {
                put(c, left: x, top: frame.maxY + vGap, parent: frame)
                x += span(c) + hGap
            }
        }
        var x = margin
        for r in roots {
            put(r, left: x, top: margin, parent: nil)
            x += span(r) + rootGap
        }
        return (out, CGSize(width: max(x - rootGap + margin, 400), height: maxY + margin))
    }
}

// MARK: Style

extension HubNode.Role {
    var color: Color {
        switch self {
        case .main: return Color(red: 0.55, green: 0.42, blue: 1.0)
        case .subagent: return Color(red: 0.16, green: 0.78, blue: 0.80)
        case .worker: return Color(red: 1.0, green: 0.60, blue: 0.18)
        case .broker: return Color(red: 0.95, green: 0.38, blue: 0.62)
        case .check: return Color(red: 0.45, green: 0.62, blue: 0.95)
        }
    }
    var icon: String {
        switch self {
        case .main: return "brain.head.profile"
        case .subagent: return "magnifyingglass"
        case .worker: return "hammer"
        case .broker: return "theatermasks"
        case .check: return "checkmark.seal"
        }
    }
}

extension HubNode {
    var roleLabel: String {
        switch role {
        case .main: return "MAIN MODEL"
        case .subagent:
            let t = title.lowercased()
            return t.contains("explore") || t.contains("research") || t.contains("general") ? "RESEARCHER" : "SUBAGENT"
        case .worker: return "WORKER"
        case .broker: return "BROKER"
        case .check: return "GATE"
        }
    }
    var platform: String? {
        guard role == .main, id.hasPrefix("s:") else { return nil }
        return id.split(separator: ":").dropFirst().first.map(String.init)
    }
}

func statusColor(_ status: String) -> Color {
    switch status.lowercased() {
    case "working", "running": return .green
    case "waiting", "queued": return .orange
    case "done", "verified", "passed": return .blue
    case "error", "failed", "needs_review", "blocked": return .red
    default: return .gray
    }
}

func platformIcon(_ platform: String?) -> String {
    switch platform {
    case "claude": return "sparkle"
    case "codex": return "chevron.left.forwardslash.chevron.right"
    case "antigravity": return "airplane"
    case "opencode": return "terminal"
    default: return "tray.full"
    }
}

// MARK: View

struct TreeView: View {
    @MainActor static var filledScreen = false
    @EnvironmentObject var engine: Engine
    @StateObject private var model = TreeModel()
    @State private var focus: String? = nil
    @State private var selected: String? = nil
    @State private var zoom: CGFloat = 1
    @State private var pinch: CGFloat = 1
    @State private var autoFit = true

    private var shown: [HubNode] {
        guard let focus, let r = model.roots.first(where: { $0.id == focus }) else { return model.roots }
        return [r]
    }

    var body: some View {
        VStack(spacing: 0) {
            sessionStrip
            Divider()
            GeometryReader { geo in
                let layout = TreeLayout.place(shown)
                ZStack {
                    TreeBackground()
                    if model.roots.isEmpty {
                        ContentUnavailableView("No live sessions", systemImage: "point.3.connected.trianglepath.dotted",
                                               description: Text("Start Claude Code, Codex, Antigravity or OpenCode and its tree appears here."))
                    } else {
                        canvas(layout, viewport: geo.size)
                    }
                }
                .onChange(of: layout.size) { _, s in if autoFit { zoom = fit(s, geo.size) } }
                .onChange(of: geo.size) { _, v in if autoFit { zoom = fit(layout.size, v) } }
                .onAppear { zoom = fit(layout.size, geo.size) }
                .overlay(alignment: .bottomTrailing) { zoomControls(layout.size, geo.size) }
            }
            if let selected, let node = find(selected) {
                Divider()
                DetailDrawer(node: node, model: model, close: { self.selected = nil; model.detailId = nil })
                    .environmentObject(engine)
                    .frame(height: 300)
                    .transition(.move(edge: .bottom))
            }
        }
        .onAppear {
            let engine = engine
            model.start(paths: engine.paths) { Dictionary(engine.config.models.map { ($0.id, $0.harness) }, uniquingKeysWith: { a, _ in a }) }
            // The tree wants the whole screen: grow the window once per launch (the user can shrink it again).
            if !TreeView.filledScreen {
                TreeView.filledScreen = true
                DispatchQueue.main.async {
                    guard let w = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }), let s = w.screen,
                          !w.styleMask.contains(.fullScreen) else { return }
                    w.setFrame(s.visibleFrame, display: true, animate: true)
                }
            }
        }
        .onDisappear { model.stop() }
        .onChange(of: focus) { _, _ in autoFit = true }
        .toolbar {
            ToolbarItem {
                Button { NSApp.keyWindow?.toggleFullScreen(nil) } label: { Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") }
                    .help("Toggle full screen")
            }
        }
    }

    // MARK: Session strip

    private var sessionStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(id: nil, icon: "square.grid.3x3.topleft.filled", title: "All sessions", detail: "\(model.roots.count)", status: nil)
                ForEach(model.roots) { r in
                    let s = model.sessions[r.id]
                    chip(id: r.id, icon: platformIcon(r.platform), title: r.subtitle.isEmpty ? r.title : r.subtitle,
                         detail: [s?.project, count(r)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "), status: r.status)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        .background(.bar)
    }

    private func count(_ r: HubNode) -> String? {
        let n = r.children.count
        return n == 0 ? nil : "\(n) child\(n == 1 ? "" : "ren")"
    }

    private func chip(id: String?, icon: String, title: String, detail: String, status: String?) -> some View {
        let on = focus == id
        return Button { withAnimation(.snappy) { focus = id } } label: {
            HStack(spacing: 7) {
                if let status { PulseDot(color: statusColor(status), pulsing: ["working", "running"].contains(status)) }
                Image(systemName: icon).font(.caption)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.caption.weight(.semibold)).lineLimit(1)
                    if !detail.isEmpty { Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                }
                .frame(maxWidth: 210, alignment: .leading)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(on ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? Color.accentColor : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: Canvas

    private func canvas(_ layout: (nodes: [PlacedNode], size: CGSize), viewport: CGSize) -> some View {
        let scale = zoom * pinch
        return ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                Connectors(nodes: layout.nodes, firstActive: model.firstActive)
                    .frame(width: layout.size.width, height: layout.size.height)
                ForEach(layout.nodes) { p in
                    NodeCard(node: p.node, lines: lines(p.node), selected: selected == p.node.id)
                        .frame(width: p.frame.width, height: p.frame.height)
                        .position(x: p.frame.midX, y: p.frame.midY)
                        .onTapGesture {
                            withAnimation(.snappy) {
                                selected = selected == p.node.id ? nil : p.node.id
                                model.detailId = selected
                            }
                        }
                }
            }
            .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
            .scaleEffect(scale, anchor: .topLeading)
            // scaleEffect does not change layout size: give the scaled tree its real box before centring it.
            .frame(width: layout.size.width * scale, height: layout.size.height * scale, alignment: .topLeading)
            .frame(width: max(layout.size.width * scale, viewport.width), height: max(layout.size.height * scale, viewport.height),
                   alignment: layout.size.width * scale < viewport.width ? .top : .topLeading)
        }
        .gesture(MagnifyGesture()
            .onChanged { pinch = $0.magnification }
            .onEnded { v in zoom = clamp(zoom * v.magnification); pinch = 1; autoFit = false })
    }

    private func lines(_ n: HubNode) -> [String] {
        if n.role == .worker, let id = n.jobId { return model.tails[id] ?? [] }
        return n.lines
    }

    private func zoomControls(_ content: CGSize, _ viewport: CGSize) -> some View {
        HStack(spacing: 2) {
            Button { zoom = clamp(zoom / 1.2); autoFit = false } label: { Image(systemName: "minus.magnifyingglass") }
                .keyboardShortcut("-", modifiers: .command)
            Text("\(Int((zoom * 100).rounded()))%").font(.caption.monospacedDigit()).frame(width: 44)
            Button { zoom = clamp(zoom * 1.2); autoFit = false } label: { Image(systemName: "plus.magnifyingglass") }
                .keyboardShortcut("=", modifiers: .command)
            Divider().frame(height: 16)
            Button { autoFit = true; withAnimation(.snappy) { zoom = fit(content, viewport) } } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }
                .keyboardShortcut("0", modifiers: .command)
                .help("Fit")
            Button { autoFit = false; zoom = 1 } label: { Text("1:1").font(.caption) }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .padding(14)
    }

    private func fit(_ content: CGSize, _ viewport: CGSize) -> CGFloat {
        guard content.width > 0, content.height > 0, viewport.width > 0 else { return 1 }
        return clamp(min(1, min(viewport.width / content.width, viewport.height / content.height)))
    }

    private func clamp(_ z: CGFloat) -> CGFloat { min(2.5, max(0.25, z)) }

    private func find(_ id: String) -> HubNode? {
        func walk(_ n: HubNode) -> HubNode? { n.id == id ? n : n.children.lazy.compactMap(walk).first }
        return model.roots.lazy.compactMap(walk).first
    }
}

// MARK: Background

struct TreeBackground: View {
    var body: some View {
        Canvas { ctx, size in
            let step: CGFloat = 26
            var p = Path()
            var y: CGFloat = 0
            while y < size.height {
                var x: CGFloat = 0
                while x < size.width { p.addEllipse(in: CGRect(x: x, y: y, width: 1.6, height: 1.6)); x += step }
                y += step
            }
            ctx.fill(p, with: .color(.primary.opacity(0.10)))
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .allowsHitTesting(false)
    }
}

// MARK: Connectors

struct Connectors: View {
    let nodes: [PlacedNode]
    let firstActive: [String: Date]

    private var animating: Bool {
        nodes.contains { $0.parent != nil && ($0.node.active || ["running", "working"].contains($0.node.status)) }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 40, paused: !animating)) { tl in
            Canvas { ctx, _ in
                let t = tl.date.timeIntervalSinceReferenceDate
                for p in nodes {
                    guard let parent = p.parent else { continue }
                    draw(&ctx, from: parent, to: p.frame, node: p.node, t: t, now: tl.date)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func draw(_ ctx: inout GraphicsContext, from a: CGRect, to b: CGRect, node: HubNode, t: Double, now: Date) {
        let spread = max(-a.width * 0.38, min(a.width * 0.38, (b.midX - a.midX) * 0.3))
        let p0 = CGPoint(x: a.midX + spread, y: a.maxY), p3 = CGPoint(x: b.midX, y: b.minY)
        let dy = (p3.y - p0.y) * 0.55
        let p1 = CGPoint(x: p0.x, y: p0.y + dy), p2 = CGPoint(x: p3.x, y: p3.y - dy)
        var path = Path()
        path.move(to: p0)
        path.addCurve(to: p3, control1: p1, control2: p2)

        let color = node.role.color
        let failed = ["failed", "error", "needs_review", "blocked"].contains(node.status)
        guard node.active else {
            ctx.stroke(path, with: .color(failed ? Color.red.opacity(0.45) : Color.secondary.opacity(0.35)),
                       style: StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: node.status == "queued" ? [5, 6] : []))
            // Socket dots at both ends.
            for q in [p0, p3] { ctx.fill(Path(ellipseIn: CGRect(x: q.x - 3, y: q.y - 3, width: 6, height: 6)), with: .color(.secondary.opacity(0.5))) }
            return
        }

        // Live wire: glow, core and marching current.
        ctx.drawLayer { g in
            g.addFilter(.blur(radius: 5))
            g.stroke(path, with: .color(color.opacity(0.55)), lineWidth: 7)
        }
        ctx.stroke(path, with: .color(color.opacity(0.85)), lineWidth: 2.2)
        ctx.stroke(path, with: .color(.white.opacity(0.75)),
                   style: StrokeStyle(lineWidth: 1.4, lineCap: .round, dash: [3, 13], dashPhase: CGFloat(-t * 46)))

        // Packets travelling from parent to child.
        let packets = 3
        for k in 0..<packets {
            let u = (t * 0.42 + Double(k) / Double(packets)).truncatingRemainder(dividingBy: 1)
            packet(&ctx, at: u, p0, p1, p2, p3, color: color, size: 1)
        }

        // A freshly dispatched task: a bright comet runs down the wire once.
        if let first = firstActive[node.id] {
            let age = now.timeIntervalSince(first)
            if age >= 0 && age < 1.6 {
                let u = min(1, age / 1.1)
                ctx.drawLayer { g in
                    g.addFilter(.blur(radius: 10))
                    let c = bezier(u, p0, p1, p2, p3)
                    g.fill(Path(ellipseIn: CGRect(x: c.x - 14, y: c.y - 14, width: 28, height: 28)), with: .color(color))
                }
                packet(&ctx, at: u, p0, p1, p2, p3, color: .white, size: 1.6)
                if age > 1.0 {
                    let r = CGFloat((age - 1.0) / 0.6) * 46
                    ctx.stroke(Path(ellipseIn: CGRect(x: p3.x - r, y: p3.y - r, width: r * 2, height: r * 2)),
                               with: .color(color.opacity(1 - (age - 1.0) / 0.6)), lineWidth: 2)
                }
            }
        }
        for q in [p0, p3] {
            ctx.fill(Path(ellipseIn: CGRect(x: q.x - 4, y: q.y - 4, width: 8, height: 8)), with: .color(color))
            ctx.fill(Path(ellipseIn: CGRect(x: q.x - 1.8, y: q.y - 1.8, width: 3.6, height: 3.6)), with: .color(.white))
        }
    }

    private func packet(_ ctx: inout GraphicsContext, at u: Double, _ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, color: Color, size s: CGFloat) {
        let c = bezier(u, p0, p1, p2, p3), d = tangent(u, p0, p1, p2, p3)
        let fade = min(1, min(u, 1 - u) * 8)
        var g = ctx
        g.opacity = fade
        g.translateBy(x: c.x, y: c.y)
        g.rotate(by: .radians(atan2(d.y, d.x)))
        let r = CGRect(x: -6 * s, y: -4 * s, width: 12 * s, height: 8 * s)
        g.drawLayer { l in
            l.addFilter(.blur(radius: 4))
            l.fill(Path(roundedRect: r.insetBy(dx: -2, dy: -2), cornerRadius: 3), with: .color(color))
        }
        g.fill(Path(roundedRect: r, cornerRadius: 2.5), with: .color(color))
        g.fill(Path(roundedRect: r.insetBy(dx: 3 * s, dy: 2.4 * s), cornerRadius: 1), with: .color(.white.opacity(0.9)))
    }

    private func bezier(_ t: Double, _ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint) -> CGPoint {
        let u = CGFloat(t), m = 1 - u
        let a = m * m * m, b = 3 * m * m * u, c = 3 * m * u * u, d = u * u * u
        return CGPoint(x: a * p0.x + b * p1.x + c * p2.x + d * p3.x, y: a * p0.y + b * p1.y + c * p2.y + d * p3.y)
    }

    private func tangent(_ t: Double, _ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint) -> CGPoint {
        let u = CGFloat(t), m = 1 - u
        let a = 3 * m * m, b = 6 * m * u, c = 3 * u * u
        return CGPoint(x: a * (p1.x - p0.x) + b * (p2.x - p1.x) + c * (p3.x - p2.x),
                       y: a * (p1.y - p0.y) + b * (p2.y - p1.y) + c * (p3.y - p2.y))
    }
}

// MARK: Node card

struct NodeCard: View {
    let node: HubNode
    let lines: [String]
    let selected: Bool

    private var live: Bool { node.active || ["working", "running"].contains(node.status) }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            VStack(alignment: .leading, spacing: 3) {
                Text(node.title).font(.system(.callout, design: .monospaced).weight(.semibold)).lineLimit(1)
                if !node.subtitle.isEmpty {
                    Text(node.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(node.role == .broker || node.role == .check ? 1 : 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 7)
            TerminalPane(lines: shownLines, live: live, placeholder: placeholder)
        }
        .background(RoundedRectangle(cornerRadius: 11).fill(Color(nsColor: .controlBackgroundColor)))
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11)
            .stroke(selected ? Color.accentColor : node.role.color.opacity(live ? 0.9 : 0.35), lineWidth: selected ? 2.5 : (live ? 1.6 : 1)))
        .shadow(color: live ? node.role.color.opacity(0.45) : .black.opacity(0.18), radius: live ? 14 : 6, y: live ? 0 : 3)
        .contentShape(Rectangle())
        .help(node.subtitle)
    }

    private var shownLines: [String] {
        if node.role == .check || node.role == .broker { return [node.activity].filter { !$0.isEmpty } }
        let base = lines.isEmpty && !node.activity.isEmpty ? [node.activity] : lines
        return Array(base.suffix(node.role == .main ? 9 : 7))
    }

    private var placeholder: String {
        switch node.status {
        case "queued": return "waiting for a worker…"
        case "pending": return "waits for the worker"
        default: return live ? "waiting for output…" : "no output"
        }
    }

    private var titleBar: some View {
        HStack(spacing: 6) {
            HStack(spacing: 5) {
                ForEach([Color.red, .yellow, .green], id: \.self) { c in Circle().fill(c.opacity(0.85)).frame(width: 8, height: 8) }
            }
            Image(systemName: node.role == .main ? platformIcon(node.platform) : node.role.icon)
                .font(.system(size: 10, weight: .bold)).foregroundStyle(node.role.color)
            Text(node.roleLabel).font(.system(size: 9.5, weight: .heavy)).tracking(0.6).foregroundStyle(node.role.color)
            Spacer(minLength: 4)
            if let start = node.startedAt {
                Group {
                    if live { Text(start, style: .timer) } else { Text(start, style: .relative) }
                }
                .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 4) {
                PulseDot(color: statusColor(node.status), pulsing: live)
                Text(node.status.replacingOccurrences(of: "_", with: " ")).font(.system(size: 10, weight: .medium))
            }
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(statusColor(node.status).opacity(0.14)))
        }
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(node.role.color.opacity(0.10))
    }
}

struct TerminalPane: View {
    let lines: [String]
    let live: Bool
    let placeholder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1.5) {
            Spacer(minLength: 0)
            if lines.isEmpty {
                Text(placeholder).foregroundStyle(Color.white.opacity(0.35))
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                HStack(spacing: 0) {
                    Text(styled(l)).lineLimit(1).truncationMode(.tail)
                    if live && i == lines.count - 1 { Cursor() }
                }
            }
            if live && lines.isEmpty { Cursor() }
        }
        .font(.system(size: 10, design: .monospaced))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(.horizontal, 9).padding(.vertical, 7)
        .background(Color(red: 0.06, green: 0.07, blue: 0.09))
        .clipped()
    }

    private func styled(_ l: String) -> AttributedString {
        var a = AttributedString(l)
        let lower = l.lowercased()
        if l.hasPrefix("──") { a.foregroundColor = Color(red: 0.45, green: 0.85, blue: 1.0) }
        else if lower.contains("error") || lower.contains("fail") || lower.contains("denied") { a.foregroundColor = Color(red: 1.0, green: 0.45, blue: 0.42) }
        else if lower.contains("passed") || lower.contains("verified") || lower.contains("✓") { a.foregroundColor = Color(red: 0.45, green: 0.95, blue: 0.55) }
        else if l.hasPrefix("›") || l.hasPrefix("$") { a.foregroundColor = Color(red: 0.98, green: 0.85, blue: 0.45) }
        else { a.foregroundColor = Color.white.opacity(0.82) }
        return a
    }
}

struct Cursor: View {
    @State private var on = false
    var body: some View {
        Rectangle().fill(Color.white.opacity(0.85)).frame(width: 6, height: 11)
            .opacity(on ? 1 : 0.1)
            .onAppear { withAnimation(.easeInOut(duration: 0.55).repeatForever()) { on = true } }
    }
}

struct PulseDot: View {
    let color: Color
    let pulsing: Bool
    @State private var phase = false
    var body: some View {
        ZStack {
            if pulsing {
                Circle().fill(color.opacity(0.5)).frame(width: 7, height: 7)
                    .scaleEffect(phase ? 2.4 : 1).opacity(phase ? 0 : 0.9)
            }
            Circle().fill(color).frame(width: 7, height: 7)
        }
        .frame(width: 8, height: 8)
        .onAppear { withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) { phase = true } }
    }
}

// MARK: Detail drawer

struct DetailDrawer: View {
    @EnvironmentObject var engine: Engine
    let node: HubNode
    @ObservedObject var model: TreeModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: node.role == .main ? platformIcon(node.platform) : node.role.icon).foregroundStyle(node.role.color)
                Text(node.roleLabel).font(.caption.weight(.heavy)).foregroundStyle(node.role.color)
                Text(node.title).font(.system(.body, design: .monospaced).weight(.semibold)).lineLimit(1)
                PulseDot(color: statusColor(node.status), pulsing: node.active)
                Text(node.status).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let job = job, job.state == .running || job.state == .queued {
                    Button("Cancel job", role: .destructive) { engine.cancel(jobId: job.id) }
                }
                if let job = job, let wt = job.worktree {
                    Button("Reveal worktree") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: wt)]) }
                }
                if let jobId = node.jobId {
                    Button("Open log") { NSWorkspace.shared.open(JobLog.url(engine.paths, jobId)) }
                }
                Button { close() } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless).keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            if !header.isEmpty {
                Text(header).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).lineLimit(3)
                    .padding(.horizontal, 14).padding(.bottom, 6)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(colored(text))
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                    Color.clear.frame(height: 1).id("end")
                }
                .background(Color(red: 0.06, green: 0.07, blue: 0.09))
                .onChange(of: text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
        .background(.bar)
    }

    private var job: Job? { node.jobId.flatMap { model.jobs[$0] } }

    private var header: String {
        switch node.role {
        case .main:
            let s = model.sessions[node.id]
            return [s?.cwd, s?.lastPrompt.map { "Prompt: \($0)" }].compactMap { $0 }.joined(separator: "\n")
        case .worker, .broker, .check:
            guard let job else { return node.subtitle }
            return "\(job.objective)\nFiles: \(job.allowedFiles.joined(separator: ", "))  ·  Check: \(job.checkArgv.joined(separator: " "))"
        case .subagent: return node.subtitle
        }
    }

    private var text: String {
        switch node.role {
        case .worker: return model.detail.isEmpty ? "No output yet." : model.detail
        case .broker, .check:
            guard let job else { return node.activity }
            var out = [String]()
            if let g = job.gate {
                out.append("Check exit \(g.acceptance.exitCode)\(g.acceptance.timedOut ? " (timed out)" : "")")
                out.append("Changed: \(g.changedFiles.joined(separator: ", "))")
                if !g.outsideAllowed.isEmpty { out.append("Outside allowed: \(g.outsideAllowed.joined(separator: ", "))") }
                out.append("")
                out.append(g.acceptance.output)
            }
            if let note = job.note { out.append("Note: \(note)") }
            return out.isEmpty ? "Waiting for the gate." : out.joined(separator: "\n")
        case .main:
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
            let recent = model.sessions[node.id]?.recent ?? []
            return recent.isEmpty ? node.lines.joined(separator: "\n") : recent.map { "\(f.string(from: Date(timeIntervalSince1970: $0.t)))  \($0.text)" }.joined(separator: "\n")
        case .subagent:
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
            let agent = model.sessions.values.lazy.compactMap { $0.agents?.first { "a:\($0.id)" == node.id } }.first
            let recent = agent?.recent ?? []
            return recent.isEmpty ? node.lines.joined(separator: "\n") : recent.map { "\(f.string(from: Date(timeIntervalSince1970: $0.t)))  \($0.text)" }.joined(separator: "\n")
        }
    }

    private func colored(_ text: String) -> AttributedString {
        var out = AttributedString()
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var a = AttributedString(String(line) + "\n")
            let lower = line.lowercased()
            if line.hasPrefix("──") { a.foregroundColor = Color(red: 0.45, green: 0.85, blue: 1.0) }
            else if lower.contains("error") || lower.contains("fail") { a.foregroundColor = Color(red: 1.0, green: 0.45, blue: 0.42) }
            else { a.foregroundColor = Color.white.opacity(0.85) }
            out.append(a)
        }
        return out
    }
}
