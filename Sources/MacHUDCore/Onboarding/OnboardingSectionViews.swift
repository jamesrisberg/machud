import AppKit
import HUDKit
import SwiftUI

// MARK: - Brain

struct BrainStep: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var settings: VoiceSettingsModel
    @ObservedObject var apps: AppsTabModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StepTitle(title: "Brain", subtitle: "Choose your agent to strap into the MacHUD mech suit.")
            let choices = BrainRuntimeChoice.all
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                ForEach(Array(stride(from: 0, to: choices.count, by: 2)), id: \.self) { i in
                    GridRow {
                        ForEach(choices[i..<min(i + 2, choices.count)]) { runtime in
                            runtimeCard(runtime).frame(maxHeight: .infinity)
                        }
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            workspacePanel
            repliesPanel
            HStack(spacing: 8) {
                if let problem = model.brainProblem {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(OnboardingStyle.warn)
                    Text(problem).font(.system(size: 12)).foregroundStyle(OnboardingStyle.warn)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(OnboardingStyle.good)
                    Text("The brain is ready. Try it: tap fn then hold, or click the orb.").font(.system(size: 12))
                }
                Spacer()
                if let note = model.brainNote { Text(note).font(.system(size: 11)).foregroundStyle(.red).lineLimit(2) }
            }
        }
    }

    private var workspacePanel: some View {
        OnboardingPanel {
            HStack(spacing: 12) {
                Image(systemName: "folder.fill").font(.system(size: 18)).foregroundStyle(OnboardingStyle.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Workspace folder").font(.system(size: 13, weight: .semibold))
                    HStack(spacing: 6) {
                        Text(model.workspaceDisplay).font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(OnboardingStyle.secondary).lineLimit(1).truncationMode(.middle)
                        if model.workspaceIsDefault {
                            Text("your home folder, the default").font(.system(size: 11)).foregroundStyle(OnboardingStyle.secondary)
                        }
                    }
                }
                Spacer()
                if !model.workspaceIsDefault {
                    Button("Use Home") { model.useHomeWorkspace() }
                        .buttonStyle(HUDButtonStyle(kind: .quiet)).disabled(!model.voiceHostUp)
                }
                Button("Change…") { model.chooseWorkspace() }
                    .buttonStyle(HUDButtonStyle(kind: .secondary))
                    .disabled(!model.voiceHostUp)
            }
        }
    }

    private var repliesPanel: some View {
        OnboardingPanel {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: "speaker.wave.2.fill").font(.system(size: 16)).foregroundStyle(OnboardingStyle.accent)
                        .frame(width: 20)
                    Toggle(isOn: Binding(get: { model.speakReplies }, set: { model.setSpeakReplies($0) })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Speak replies").font(.system(size: 13, weight: .semibold))
                            Text("Read the agent's answers aloud; off shows them as text only.")
                                .font(.system(size: 11)).foregroundStyle(OnboardingStyle.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .disabled(!model.voiceHostUp)
                }
                HStack(spacing: 10) {
                    Picker("Voice", selection: Binding(get: { model.replyVoice }, set: { model.setReplyVoice($0) })) {
                        ForEach(ReplyVoiceChoice.all) { Text($0.title).tag($0.id) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 380)
                    .disabled(!model.voiceHostUp)
                    Spacer()
                    if model.saying { ProgressView().controlSize(.small) }
                    Button { model.testVoice() } label: { Label("Test voice", systemImage: "play.fill") }
                        .buttonStyle(HUDButtonStyle(kind: .secondary))
                        .disabled(!model.voiceHostUp || model.saying)
                }
                if model.replyVoice == "kokoro" { kokoroRow }
                if model.replyVoice == "grok" {
                    Text("Grok needs an API key: add it in Settings › Voice.").font(.system(size: 11))
                        .foregroundStyle(OnboardingStyle.secondary)
                }
                if let note = model.sayNote {
                    Text(note).font(.system(size: 11)).foregroundStyle(OnboardingStyle.warn).lineLimit(2)
                }
            }
        }
    }

    @ViewBuilder private var kokoroRow: some View {
        HStack(spacing: 8) {
            if let kokoro = model.kokoro {
                if kokoro.installed {
                    StatusPill(text: "Kokoro voice installed", ok: true)
                } else if kokoro.downloading {
                    Text("Downloading the Kokoro voice…").font(.system(size: 11))
                    ProgressView(value: kokoro.progress).frame(width: 180)
                    Text("\(Int(kokoro.progress * 100))%").font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(OnboardingStyle.secondary)
                } else {
                    StatusPill(text: "Kokoro voice not downloaded", ok: false)
                    Text(kokoro.bytes.map { "about \(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)), runs on this Mac" }
                         ?? "runs on this Mac")
                        .font(.system(size: 11)).foregroundStyle(OnboardingStyle.secondary)
                    Spacer()
                    Button("Download") { model.downloadKokoro() }.buttonStyle(HUDButtonStyle(kind: .primary))
                }
            } else {
                Text(model.kokoroNote ?? "Kokoro's download state shows here once voice is on.")
                    .font(.system(size: 11)).foregroundStyle(OnboardingStyle.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func runtimeCard(_ runtime: BrainRuntimeChoice) -> some View {
        let selected = model.brainEnabled && model.selectedRuntime == runtime.id
        return Button { model.chooseRuntime(runtime.id) } label: {
            OnboardingPanel(highlighted: selected) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(runtime.title).font(.system(size: 14, weight: .semibold))
                        Spacer()
                        detection(runtime.id)
                        Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(selected ? OnboardingStyle.accent : OnboardingStyle.secondary)
                    }
                    Text(runtime.blurb).font(.system(size: 11)).foregroundStyle(OnboardingStyle.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!model.voiceHostUp)
    }

    @ViewBuilder private func detection(_ id: String) -> some View {
        switch model.runtimeInstalled(id) {
        case true?: StatusPill(text: "Found", ok: true).help(model.runtimePath(id) ?? "")
        case false?: StatusPill(text: "Not found", ok: false)
        case nil: EmptyView()
        }
    }

            HStack(spacing: 6) {
                Image(systemName: "rectangle.stack").font(.system(size: 11))
                switch row.status.state {
                case .notInstalled:
                    if let phase = row.phase { Text(phase.text).font(.system(size: 11)).foregroundStyle(OnboardingStyle.secondary) }
                        .buttonStyle(HUDButtonStyle(kind: .secondary)).disabled(row.busy)
                default:
                }
            }
        } else {
                .foregroundStyle(OnboardingStyle.secondary)
        }
    }
}

// MARK: - Tool dock

struct ToolDockStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepTitle(title: "Tool dock",
                      subtitle: "A glass strip of your HUD apps: hover a tool to drop its panel out, click a windowed app to summon it, drop files on an icon to hand them over.")
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    OnboardingPanel {
                        Toggle(isOn: Binding(get: { model.dockEnabled }, set: { model.setDock(enabled: $0) })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Show the tool dock").font(.system(size: 14, weight: .semibold))
                                Text("On by default, at the bottom of the main display. Changes apply right away.")
                                    .font(.system(size: 11)).foregroundStyle(OnboardingStyle.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .toggleStyle(.switch)
                    }
                    OnboardingPanel {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Good to know").font(.system(size: 12, weight: .semibold)).foregroundStyle(OnboardingStyle.secondary)
                            tip("keyboard", "\(model.hotkeys.toolDock) shows or hides it from anywhere.")
                            tip("hand.draw", "Drag the strip to any edge or corner; it snaps to the nearest spot.")
                            tip("contextualmenu.and.cursorarrow", "Right-click it for auto-hide and magnification.")
                            tip("square.grid.2x2", "Apps you install join it by themselves.")
                        }
                    }
                }
                .frame(width: 330)
                OnboardingPanel {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Position").font(.system(size: 14, weight: .semibold))
                            Spacer()
                            Text(ToolDock.title(of: model.dockPosition)).font(.system(size: 12)).foregroundStyle(OnboardingStyle.secondary)
                        }
                        DockPositionPicker(position: model.dockPosition, enabled: model.dockEnabled) { model.moveDock(to: $0) }
                            .frame(height: 230)
                        Text(model.dockScreen.map { "On \($0)." } ?? "On the main display.")
                            .font(.system(size: 11)).foregroundStyle(OnboardingStyle.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func tip(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(OnboardingStyle.accent).frame(width: 18)
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A miniature display with the eight places the dock can sit; the current one is drawn as
/// the strip (a row, a column or an L), the others as targets to click.
struct DockPositionPicker: View {
    let position: HUDDockPosition
    let enabled: Bool
    let choose: (HUDDockPosition) -> Void

    var body: some View {
        GeometryReader { geo in
            let screen = CGRect(origin: .zero, size: geo.size).insetBy(dx: 6, dy: 6)
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.2, green: 0.28, blue: 0.45), Color(red: 0.45, green: 0.33, blue: 0.5)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.3)))
                    .frame(width: screen.width, height: screen.height)
                    .position(x: screen.midX, y: screen.midY)
                Rectangle().fill(Color.black.opacity(0.35)).frame(width: screen.width - 2, height: 8)
                    .position(x: screen.midX, y: screen.minY + 5)
                ForEach(ToolDock.menuPositions, id: \.self) { p in
                    ForEach(Array(Self.segments(p, in: screen).enumerated()), id: \.offset) { _, rect in
                        segment(rect, of: p)
                    }
                }
            }
        }
    }

    /// One piece of `position`'s strip, tappable to choose it. Its own function so the
    /// expression type-checks quickly.
    private func segment(_ rect: CGRect, of position: HUDDockPosition) -> some View {
        let selected = position == self.position
        let fill: Color = selected ? (enabled ? OnboardingStyle.accent : Color.white.opacity(0.35)) : Color.white.opacity(0.12)
        let stroke: Color = selected ? Color.white.opacity(0.8) : Color.white.opacity(0.28)
        let style = StrokeStyle(lineWidth: 1, dash: selected ? [] : [3, 3])
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        return shape.fill(fill)
            .overlay(shape.stroke(stroke, style: style))
            .frame(width: rect.width, height: rect.height)
            // Hit area = this piece only: sized and made tappable before `.position`, which
            // would otherwise stretch it over the whole miniature and let the last position
            // drawn take every tap.
            .contentShape(Rectangle())
            .onTapGesture { choose(position) }
            .help(ToolDock.title(of: position))
            .position(x: rect.midX, y: rect.midY)
    }

    /// The strip's pieces for `position` on the miniature `screen` (SwiftUI coordinates, y down).
    /// The usable area (below the menu-bar strip) is a three-by-three grid of cells with a
    /// `gap` between them; every position's region stays inside its own cell (an edge in the
    /// middle cell of its side, a corner's L in the corner cell), so no two positions' regions
    /// ever overlap.
    static func segments(_ position: HUDDockPosition, in screen: CGRect) -> [CGRect] {
        let t: CGFloat = 10, inset: CGFloat = 6, gap: CGFloat = 6
        let usable = CGRect(x: screen.minX, y: screen.minY + 14, width: screen.width, height: screen.height - 14)
        let colW = usable.width / 3, rowH = usable.height / 3
        let leftColMax = usable.minX + colW, rightColMin = usable.maxX - colW
        let topRowMax = usable.minY + rowH, bottomRowMin = usable.maxY - rowH
        let top = usable.minY + inset, bottom = usable.maxY - inset - t
        let left = usable.minX + inset, right = usable.maxX - inset - t
        let midXStart = leftColMax + gap, midXEnd = rightColMin - gap
        let midYStart = topRowMax + gap, midYEnd = bottomRowMin - gap
        switch position {
        case .top: return [CGRect(x: midXStart, y: top, width: midXEnd - midXStart, height: t)]
        case .bottom: return [CGRect(x: midXStart, y: bottom, width: midXEnd - midXStart, height: t)]
        case .left: return [CGRect(x: left, y: midYStart, width: t, height: midYEnd - midYStart)]
        case .right: return [CGRect(x: right, y: midYStart, width: t, height: midYEnd - midYStart)]
        case .topLeft:
            return [CGRect(x: left, y: top, width: leftColMax - gap - left, height: t),
                    CGRect(x: left, y: top, width: t, height: topRowMax - gap - top)]
        case .topRight:
            return [CGRect(x: rightColMin + gap, y: top, width: right + t - (rightColMin + gap), height: t),
                    CGRect(x: right, y: top, width: t, height: topRowMax - gap - top)]
        case .bottomLeft:
            return [CGRect(x: left, y: bottom, width: leftColMax - gap - left, height: t),
                    CGRect(x: left, y: bottomRowMin + gap, width: t, height: bottom - (bottomRowMin + gap))]
        case .bottomRight:
            return [CGRect(x: rightColMin + gap, y: bottom, width: right + t - (rightColMin + gap), height: t),
                    CGRect(x: right, y: bottomRowMin + gap, width: t, height: bottom - (bottomRowMin + gap))]
        }
    }
}

// MARK: - First loadout

struct LoadoutStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepTitle(title: "Your first loadout",
                      subtitle: "A loadout remembers which windows go where. Arrange a few, capture them, and MacHUD can put them back in one move.")
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    numbered(1, "Arrange", "Open two or three apps you use together and place them side by side. This card gets out of the way while you do.")
                    numbered(2, "Name and capture", "MacHUD saves one region per window, with the app that fills it.")
                    numbered(3, "See the regions", "They appear here; the radial menu applies them next.")
                    HStack(spacing: 8) {
                        TextField("Loadout name", text: $model.loadoutName)
                            .textFieldStyle(.roundedBorder).frame(width: 150)
                        Button(model.firstLoadout == nil ? "Arrange windows…" : "Rearrange…") { model.startArranging() }
                            .buttonStyle(HUDButtonStyle(kind: model.firstLoadout == nil ? .primary : .secondary))
                    }
                    .padding(.top, 4)
                    if let note = model.loadoutNote {
                        Text(note).font(.system(size: 11)).foregroundStyle(OnboardingStyle.warn).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(width: 300)
                OnboardingPanel(highlighted: model.firstLoadout != nil) {
                    VStack(alignment: .leading, spacing: 8) {
                        if let loadout = model.firstLoadout {
                            HStack {
                                Text(loadout.name).font(.system(size: 14, weight: .semibold))
                                StatusPill(text: "\(loadout.regions.count) region\(loadout.regions.count == 1 ? "" : "s")", ok: true)
                                Spacer()
                            }
                            RegionsMiniMap(summary: loadout).frame(height: 240)
                            Text(loadout.savedNote)
                                .font(.system(size: 11)).foregroundStyle(OnboardingStyle.secondary)
                        } else {
                            Text("Regions").font(.system(size: 14, weight: .semibold))
                            ZStack {
                                RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                                Text("Your captured regions show up here.").font(.system(size: 12)).foregroundStyle(OnboardingStyle.secondary)
                            }
                            .frame(height: 240)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func numbered(_ n: Int, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(.system(size: 12, weight: .bold)).foregroundStyle(.black)
                .frame(width: 22, height: 22).background(Circle().fill(OnboardingStyle.accent))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(text).font(.system(size: 12)).foregroundStyle(OnboardingStyle.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A loadout's regions on a miniature of the display, each labelled with its window.
struct RegionsMiniMap: View {
    let summary: OnboardingLoadoutSummary

    var body: some View {
        GeometryReader { geo in
            let aspect = max(summary.aspect, 0.5)
            let width = min(geo.size.width, geo.size.height * aspect)
            let height = width / aspect
            let origin = CGPoint(x: (geo.size.width - width) / 2, y: (geo.size.height - height) / 2)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.35))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.3)))
                    .frame(width: width, height: height)
                ForEach(Array(summary.regions.enumerated()), id: \.offset) { i, region in
                    let r = CGRect(x: region.frame.x * width, y: region.frame.y * height,
                                   width: region.frame.w * width, height: region.frame.h * height).insetBy(dx: 3, dy: 3)
                    let hue = Self.hues[i % Self.hues.count]
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hue.opacity(0.28))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(hue, lineWidth: 1.5))
                        .overlay(Text(region.label).font(.system(size: 11, weight: .semibold)).lineLimit(2)
                            .multilineTextAlignment(.center).padding(4))
                        .frame(width: max(r.width, 1), height: max(r.height, 1))
                        .offset(x: r.minX, y: r.minY)
                }
            }
            .offset(x: origin.x, y: origin.y)
        }
    }

    static let hues: [Color] = [OnboardingStyle.accent, OnboardingStyle.good, OnboardingStyle.warn,
                                Color(red: 0.8, green: 0.55, blue: 1.0), Color(red: 1.0, green: 0.5, blue: 0.6)]
}

// MARK: - Radial menu

struct RadialStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepTitle(title: "The radial menu",
                      subtitle: "Hold \(model.hotkeys.radialWheel) anywhere and a small wheel opens under the pointer. Move up onto Apply Loadout, on to a loadout, on to Apply, and let go: your windows jump into place.")
            HStack(alignment: .top, spacing: 18) {
                RadialDiagram(target: model.practiceTarget ?? "Your loadout", hotkey: model.hotkeys.radialWheel,
                              widgets: model.wheelOffersWidgets)
                    .frame(width: 300, height: 300)
                VStack(alignment: .leading, spacing: 12) {
                    if let target = model.practiceTarget {
                        practiceSteps(target)
                    } else {
                        OnboardingPanel {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Make a loadout first").font(.system(size: 14, weight: .semibold))
                                Text("Apply Loadout on the wheel lists your loadouts; there are none yet.").font(.system(size: 12))
                                    .foregroundStyle(OnboardingStyle.secondary)
                                Button("Go to First loadout") { model.go(to: .loadout) }.buttonStyle(HUDButtonStyle(kind: .primary))
                            }
                        }
                    }
                    result
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private func practiceSteps(_ target: String) -> some View {
        OnboardingPanel {
            VStack(alignment: .leading, spacing: 10) {
                Text("Practice").font(.system(size: 14, weight: .semibold))
                step(1, "Nudge a window or two out of place, so you can see them go back.")
                step(2, "Hold \(model.hotkeys.radialWheel). Keep holding: the wheel opens and stays open while you do.")
                step(3, "Move up onto Apply Loadout: your loadouts unfold beyond it.")
                step(4, "Move on to \(target), then on to Apply.")
                step(5, "Let go. MacHUD applies it, and this step ticks itself off.")
                HStack(spacing: 8) {
                    Button("Try it on the desktop") { model.startPractice() }.buttonStyle(HUDButtonStyle(kind: .primary))
                    Text("The setup shrinks to a small card.").font(.system(size: 11)).foregroundStyle(OnboardingStyle.secondary)
                }
                .padding(.top, 2)
            }
        }
        OnboardingPanel {
            VStack(alignment: .leading, spacing: 6) {
                Text("A loadout's actions").font(.system(size: 12, weight: .semibold)).foregroundStyle(OnboardingStyle.secondary)
                action("Preview", "Draws where each window would go first.")
                action("Apply", "Straight on: apply the loadout.")
                action("Clear + Apply", "Clear this screen, then apply.")
                Text("Letting go anywhere but on an action, or in the centre, cancels. A quick tap of the key does not open the wheel. \(model.wheelOffersWidgets ? "Capture, Park and Widgets" : "Capture and Park") are on the wheel too.")
                    .font(.system(size: 11)).foregroundStyle(OnboardingStyle.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var result: some View {
        if let applied = model.practice {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(OnboardingStyle.good).font(.system(size: 18))
                Text(applied.failed == 0 ? "Nicely done: \(applied.loadout) applied, \(applied.placed) window\(applied.placed == 1 ? "" : "s") placed."
                     : "\(applied.loadout) applied: \(applied.placed) placed, \(applied.failed) could not be placed.")
                    .font(.system(size: 13, weight: .medium))
            }
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(n)").font(.system(size: 11, weight: .bold)).foregroundStyle(.black)
                .frame(width: 18, height: 18).background(Circle().fill(OnboardingStyle.accent))
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func action(_ name: String, _ text: String) -> some View {
        HStack(spacing: 8) {
            Text(name).font(.system(size: 11, weight: .semibold)).frame(width: 84, alignment: .leading)
            Text(text).font(.system(size: 11))
        }
    }
}

/// The wheel as a picture, along the path the practice takes: the top petals around the hotkey
/// (Widgets only while the wheel has it), Apply Loadout lit, the loadout beyond it and its three actions beyond that, Apply lit,
/// with the pointer on it and a line showing the way it came.
struct RadialDiagram: View {
    let target: String
    let hotkey: String
    let widgets: Bool

    private static let petals: [(name: String, angle: Double, radius: Double, lit: Bool)] = [
        ("Apply Loadout", 0, 0.36, true), ("Capture", 90, 0.5, false), ("Park", 180, 0.36, false), ("Widgets", 270, 0.5, false),
    ]
    private static let actions: [(name: String, angle: Double, lit: Bool)] = [("Preview", -28, false), ("Apply", 0, true),
                                                                               ("Clear + Apply", 28, false)]

    /// The point `radius` (a fraction of `r`) out from `c` at `degrees` clockwise from straight up.
    private static func at(_ c: CGPoint, _ r: CGFloat, _ degrees: Double, _ radius: Double) -> CGPoint {
        let a = degrees * .pi / 180
        return CGPoint(x: c.x + CGFloat(sin(a)) * r * CGFloat(radius), y: c.y - CGFloat(cos(a)) * r * CGFloat(radius))
    }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2 + side * 0.1)
            diagram(centre: c, r: side / 2, frame: geo.size)
        }
    }

    private func diagram(centre c: CGPoint, r: CGFloat, frame: CGSize) -> some View {
        let pointer = Self.at(c, r, 0, 0.8)
        // The dark disc and its soft edge stay inside the frame.
        let blur: CGFloat = 14
        let disc = min(frame.width, frame.height) - 2 * blur
        return ZStack {
            Circle().fill(Color.black.opacity(0.35)).frame(width: disc, height: disc)
                .position(x: frame.width / 2, y: frame.height / 2).blur(radius: blur)
            // The way the pointer goes, in the gaps between the words.
            Path { p in
                for (from, to) in [(0.12, 0.28), (0.43, 0.52), (0.67, 0.72)] {
                    p.move(to: Self.at(c, r, 0, from))
                    p.addLine(to: Self.at(c, r, 0, to))
                }
            }
            .stroke(OnboardingStyle.accent.opacity(0.6), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [3, 4]))
            ForEach(Self.petals.indices.filter { widgets || Self.petals[$0].name != "Widgets" }, id: \.self) { i in
                petal(Self.petals[i].name, lit: Self.petals[i].lit)
                    .position(Self.at(c, r, Self.petals[i].angle, Self.petals[i].radius))
            }
            Text(target).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.white)
                .lineLimit(1).frame(maxWidth: r * 0.9).position(Self.at(c, r, 0, 0.6))
            ForEach(Self.actions.indices, id: \.self) { i in
                action(Self.actions[i].name, lit: Self.actions[i].lit).position(Self.at(c, r, Self.actions[i].angle, 0.8))
            }
            KeyCap(text: hotkey).position(c)
            Image(systemName: "cursorarrow").font(.system(size: 18)).foregroundStyle(Color.white)
                .shadow(radius: 2)
                .position(x: pointer.x + 10, y: pointer.y + 14)
        }
    }

    private func petal(_ name: String, lit: Bool) -> some View {
        Text(name).font(.system(size: 12, weight: lit ? .semibold : .regular))
            .foregroundStyle(lit ? Color.white : Color.white.opacity(0.45))
            .lineLimit(1).fixedSize()
    }

    private func action(_ name: String, lit: Bool) -> some View {
        Text(name).font(.system(size: 11, weight: lit ? .bold : .medium))
            .foregroundStyle(lit ? OnboardingStyle.accent : Color.white.opacity(0.7))
            .lineLimit(1).fixedSize()
    }
}

// MARK: - Done

struct DoneStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        let open = OnboardingStep.sections.filter { model.status(of: $0) != .done }
        VStack(alignment: .leading, spacing: 14) {
            StepTitle(title: open.isEmpty ? "You're all set" : "Nearly there",
                      subtitle: open.isEmpty ? "Everything is set up."
                        : "The rest can wait. Pick any of these up now, or later from Setup Guide… in the menu bar.")
            if !open.isEmpty {
                VStack(spacing: 6) {
                    ForEach(open, id: \.self) { section in
                        Button { model.go(to: section) } label: {
                            HStack(spacing: 12) {
                                StatusMark(status: model.status(of: section))
                                Text(section.title).font(.system(size: 13, weight: .semibold))
                                Text(section.summary).font(.system(size: 12)).foregroundStyle(OnboardingStyle.secondary)
                                Spacer()
                                Text("Set up").font(.system(size: 12)).foregroundStyle(OnboardingStyle.accent)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(OnboardingStyle.panel))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                card("waveform", "Talk", "Hold fn to dictate; tap then hold, or click the orb, for the agent.")
                card("circle.circle", "Arrange", "Hold \(model.hotkeys.radialWheel), then Apply Loadout, a loadout, Apply.")
                card("dock.rectangle", "Tools", "\(model.hotkeys.toolDock) shows or hides the tool dock.")
                card("terminal", "Script it", "machud help lists every command; agents use it too.")
            }
            Spacer(minLength: 0)
        }
    }

    private func card(_ symbol: String, _ title: String, _ text: String) -> some View {
        OnboardingPanel {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(OnboardingStyle.accent).frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(text).font(.system(size: 12)).foregroundStyle(OnboardingStyle.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - Compact card

/// The small card the overlay becomes while the user arranges windows or tries the wheel.
struct OnboardingCompactCard: View {
    @ObservedObject var model: OnboardingModel
    let kind: OnboardingModel.Compact

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: kind == .arrange ? "rectangle.split.3x1" : "circle.circle")
                    .foregroundStyle(OnboardingStyle.accent)
                Text(kind == .arrange ? "Arrange your windows" : "Try the radial menu").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Back to setup") { model.expand() }.buttonStyle(HUDButtonStyle(kind: .quiet))
            }
            switch kind {
            case .arrange:
                Text("Place two or three windows the way you like them on this display, then capture.")
                    .font(.system(size: 12)).foregroundStyle(OnboardingStyle.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    TextField("Loadout name", text: $model.loadoutName).textFieldStyle(.roundedBorder).frame(width: 170)
                    if model.capturing { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Capture") { model.captureLoadout() }
                        .buttonStyle(HUDButtonStyle(kind: .primary))
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.capturing)
                }
                if let note = model.loadoutNote {
                    Text(note).font(.system(size: 11)).foregroundStyle(OnboardingStyle.warn).lineLimit(2)
                }
            case .practice:
                HStack(spacing: 6) {
                    Text("Hold").font(.system(size: 13))
                    KeyCap(text: model.hotkeys.radialWheel, large: true)
                    Text("→ Apply Loadout →").font(.system(size: 13))
                    Text(model.practiceTarget ?? "your loadout").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(OnboardingStyle.accent)
                    Text("→ Apply → let go").font(.system(size: 13))
                }
                Text("Waiting for you to apply it… the setup comes back when it lands.")
                    .font(.system(size: 12)).foregroundStyle(OnboardingStyle.secondary)
            }
        }
        .foregroundStyle(.white)
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onboardingGlass(radius: 20)
    }
}
