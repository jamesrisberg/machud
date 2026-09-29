import AppKit
import HUDKit
import SwiftUI

/// The overlay's content: a dimmed screen with one dark glass card, one step at a time.
/// Return (or ⌘→) goes on, ⌘← goes back, Esc leaves to finish later.
struct OnboardingRootView: View {
    @ObservedObject var model: OnboardingModel
    /// Renders this step instead of the model's (snapshots).
    var forcedStep: OnboardingStep?

    static let cardSize = CGSize(width: 880, height: 640)

    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
            OnboardingCard(model: model, step: forcedStep ?? model.step)
                .frame(width: Self.cardSize.width, height: Self.cardSize.height)
                .shadow(color: .black.opacity(0.5), radius: 40, y: 12)
        }
        .environment(\.colorScheme, .dark)
        .tint(OnboardingStyle.accent)
    }
}

enum OnboardingStyle {
    static let accent = Color(red: 0.38, green: 0.78, blue: 1.0)
    static let good = Color(red: 0.35, green: 0.85, blue: 0.55)
    static let warn = Color(red: 1.0, green: 0.72, blue: 0.3)
    static let panel = Color.white.opacity(0.06)
    static let stroke = Color.white.opacity(0.12)
    static let secondary = Color.white.opacity(0.62)
}

struct OnboardingCard: View {
    @ObservedObject var model: OnboardingModel
    let step: OnboardingStep

    var body: some View {
        VStack(spacing: 0) {
            OnboardingHeader(model: model, step: step)
            Rectangle().fill(OnboardingStyle.stroke).frame(height: 1)
            Group {
                switch step {
                case .welcome: WelcomeStep(model: model)
                case .permissions: PermissionsStep(model: model)
                case .voice: VoiceStep(model: model, settings: model.voiceSettings)
                case .brain: BrainStep(model: model, settings: model.voiceSettings, apps: model.apps)
                case .apps: AppsStep(model: model, apps: model.apps)
                case .tour: TourStep(model: model)
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 26)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Rectangle().fill(OnboardingStyle.stroke).frame(height: 1)
            OnboardingFooter(model: model, step: step)
        }
        .foregroundStyle(.white)
        .background(Color(white: 0.06).opacity(0.84))
        .hudGlass(HUDGlassView.Style(cornerRadius: 28, borderWidth: 1, borderAlpha: 0.22))
    }
}

// MARK: - Chrome

struct OnboardingHeader: View {
    @ObservedObject var model: OnboardingModel
    let step: OnboardingStep

    var body: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingStep.allCases, id: \.self) { s in
                Button { model.go(to: s) } label: {
                    HStack(spacing: 6) {
                        ZStack {
                            Circle().fill(s == step ? OnboardingStyle.accent : Color.white.opacity(s.index < step.index ? 0.22 : 0.08))
                                .frame(width: 20, height: 20)
                            if s.index < step.index {
                                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                            } else {
                                Text("\(s.index + 1)").font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(s == step ? Color.black : Color.white.opacity(0.7))
                            }
                        }
                        Text(s.title).font(.system(size: 12, weight: s == step ? .semibold : .regular))
                            .foregroundStyle(s == step ? Color.white : OnboardingStyle.secondary)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Capsule().fill(s == step ? Color.white.opacity(0.08) : .clear))
                }
                .buttonStyle(.plain)
                .help("Go to \(s.title)")
            }
            Spacer()
            Button { model.later() } label: {
                HStack(spacing: 4) {
                    Text("Finish later").font(.system(size: 12))
                    Image(systemName: "xmark.circle.fill").font(.system(size: 14))
                }
                .foregroundStyle(OnboardingStyle.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close; pick up here next time (Esc)")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

struct OnboardingFooter: View {
    @ObservedObject var model: OnboardingModel
    let step: OnboardingStep

    var body: some View {
        HStack(spacing: 12) {
            if step.previous != nil {
                Button("Back") { model.back() }
                    .buttonStyle(HUDButtonStyle(kind: .secondary))
                    .keyboardShortcut(.leftArrow, modifiers: .command)
            }
            if step == .welcome {
                Button("Skip setup") { model.skip() }
                    .buttonStyle(HUDButtonStyle(kind: .quiet))
            }
            Spacer()
            Text("Return: next  ·  ⌘←: back  ·  Esc: later")
                .font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.4))
            Button(primaryTitle) { model.next() }
                .buttonStyle(HUDButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
            // ⌘→ as well as Return, for keyboard walkers.
            Button("") { model.next() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var primaryTitle: String {
        switch step {
        case .welcome: return "Get started"
        case .permissions: return model.permissionsGranted ? "Continue" : "Continue anyway"
        case .brain: return model.brainReady ? "Continue" : "Set up later"
        case .tour: return "Finish"
        default: return "Continue"
        }
    }
}

struct HUDButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, quiet }
    var kind: Kind
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: kind == .primary ? .semibold : .medium))
            .padding(.horizontal, kind == .quiet ? 8 : 16)
            .padding(.vertical, 7)
            .foregroundStyle(kind == .primary ? Color.black : kind == .quiet ? OnboardingStyle.secondary : Color.white)
            .background(Capsule().fill(fill.opacity(configuration.isPressed ? 0.7 : 1)))
            .overlay(Capsule().stroke(kind == .secondary ? OnboardingStyle.stroke : .clear))
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Capsule())
    }

    private var fill: Color {
        switch kind {
        case .primary: return OnboardingStyle.accent
        case .secondary: return Color.white.opacity(0.1)
        case .quiet: return .clear
        }
    }
}

/// A heading and a line under it, at the top of each step.
struct StepTitle: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 26, weight: .semibold))
            Text(subtitle).font(.system(size: 14)).foregroundStyle(OnboardingStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 18)
    }
}

struct StatusPill: View {
    let text: String
    let ok: Bool

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(ok ? OnboardingStyle.good : OnboardingStyle.warn).frame(width: 7, height: 7)
            Text(text).font(.system(size: 11, weight: .semibold))
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill((ok ? OnboardingStyle.good : OnboardingStyle.warn).opacity(0.16)))
    }
}

/// A rounded panel on the card.
struct OnboardingPanel<Content: View>: View {
    var highlighted = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(OnboardingStyle.panel))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(highlighted ? OnboardingStyle.accent : OnboardingStyle.stroke, lineWidth: highlighted ? 2 : 1))
    }
}

struct KeyCap: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold, design: .rounded))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.14)))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.25)))
    }
}

// MARK: - Steps

struct WelcomeStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "rectangle.3.group.fill").font(.system(size: 40)).foregroundStyle(OnboardingStyle.accent)
                StepTitle(title: "Welcome to MacHUD",
                          subtitle: "Your screen as a grid you design, a dock of HUD tools, and a voice you can dictate with or hand work to.")
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                feature("rectangle.split.3x1", "Loadouts", "Every window in its place: snap with Shift, or apply a whole workspace at once.")
                feature("dock.rectangle", "Tool dock", "A strip of HUD apps (file manager, scratchpad, agent dashboard) one click away.")
                feature("waveform", "Voice", "Hold fn to dictate anywhere. Tap then hold to talk to your agent.")
                feature("brain", "Brain", "An agent (Codex, Claude Code, Hermes or mclaude) working in a folder you choose.")
            }
            Spacer(minLength: 16)
            Text("Setup takes a couple of minutes. Esc leaves it for later; it opens again where you left it, and the menu bar's Setup Guide… or `machud onboarding show` bring it back any time.")
                .font(.system(size: 12)).foregroundStyle(OnboardingStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func feature(_ symbol: String, _ title: String, _ text: String) -> some View {
        OnboardingPanel {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(OnboardingStyle.accent).frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(text).font(.system(size: 12)).foregroundStyle(OnboardingStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

struct PermissionsStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepTitle(title: "Permissions",
                      subtitle: "macOS asks you, not MacHUD. Grant these once; the status below updates by itself.")
            permission(symbol: "macwindow.on.rectangle", title: "Accessibility",
                       why: "To see and move other apps' windows: snapping, loadouts and parking.",
                       granted: model.accessibility, status: model.accessibility ? "Granted" : "Needed") {
                if !model.accessibility {
                    Button("Ask macOS") { model.requestAccessibility() }.buttonStyle(HUDButtonStyle(kind: .primary))
                }
                Button("Open System Settings") { model.openAccessibilitySettings() }.buttonStyle(HUDButtonStyle(kind: .secondary))
            }
            permission(symbol: "mic.fill", title: "Microphone",
                       why: "So the voice host hears you while you hold fn, and listens for the wake word when it is on. Nothing is recorded otherwise.",
                       granted: model.microphone == .granted, status: micStatus) {
                switch model.microphone {
                case .notAsked:
                    Button("Allow Microphone") { model.requestMicrophone() }.buttonStyle(HUDButtonStyle(kind: .primary))
                case .denied, .restricted:
                    Button("Open System Settings") { model.openMicrophoneSettings() }.buttonStyle(HUDButtonStyle(kind: .primary))
                case .granted:
                    EmptyView()
                }
            }
            if let note = model.permissionNote {
                Label(note, systemImage: "info.circle").font(.system(size: 12)).foregroundStyle(OnboardingStyle.secondary)
            }
            Spacer()
        }
    }

    private var micStatus: String {
        switch model.microphone {
        case .granted: return "Granted"
        case .notAsked: return "Not asked yet"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        }
    }

    private func permission<Buttons: View>(symbol: String, title: String, why: String, granted: Bool, status: String,
                                           @ViewBuilder buttons: () -> Buttons) -> some View {
        OnboardingPanel(highlighted: !granted) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(granted ? OnboardingStyle.good : OnboardingStyle.accent)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(title).font(.system(size: 15, weight: .semibold))
                        StatusPill(text: status, ok: granted)
                    }
                    Text(why).font(.system(size: 12)).foregroundStyle(OnboardingStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                HStack(spacing: 8) { buttons() }
            }
        }
    }
}

struct VoiceStep: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var settings: VoiceSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepTitle(title: "Voice", subtitle: "Dictate into any app with the fn key, or hand a request to your agent.")
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 14) {
                    OnboardingPanel {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle(isOn: Binding(get: { model.voiceOn }, set: { model.setVoice(on: $0) })) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Voice on").font(.system(size: 14, weight: .semibold))
                                    Text("The fn gestures, the orb under the camera and the wake word.")
                                        .font(.system(size: 11)).foregroundStyle(OnboardingStyle.secondary)
                                }
                            }
                            .toggleStyle(.switch)
                            if case .unavailable(let why) = settings.status, !model.voiceOn {
                                Text(why).font(.system(size: 11)).foregroundStyle(OnboardingStyle.warn)
                            }
                            Picker("fn key", selection: Binding(get: { model.keyMode }, set: { model.setKeyMode($0) })) {
                                Text("Hold to talk").tag("hold")
                                Text("Tap to start and stop").tag("toggle")
                            }
                            .pickerStyle(.segmented)
                            .disabled(!model.voiceOn)
                            Toggle("Talk to the agent with fn", isOn: Binding(get: { settings.bool("agentGesture") },
                                                                             set: { model.setAgentGesture($0) }))
                                .toggleStyle(.switch).font(.system(size: 13)).disabled(!model.voiceOn)
                        }
                    }
                    OnboardingPanel {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Gestures").font(.system(size: 12, weight: .semibold)).foregroundStyle(OnboardingStyle.secondary)
                            ForEach(gestures, id: \.1) { keys, text in
                                HStack(spacing: 10) {
                                    HStack(spacing: 3) { ForEach(keys, id: \.self) { KeyCap(text: $0) } }.frame(width: 118, alignment: .leading)
                                    Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
                .frame(width: 380)
                TryItPanel(model: model)
            }
        }
    }

    private var gestures: [([String], String)] {
        var rows: [([String], String)]
        if model.keyMode == "toggle" {
            rows = [(["tap fn"], "Start dictating; tap again to stop and paste at the cursor.")]
            if settings.bool("agentGesture") { rows.append((["double-tap fn"], "Talk to the agent instead.")) }
        } else {
            rows = [(["hold fn"], "Dictate while held; let go to paste at the cursor.")]
            if settings.bool("agentGesture") { rows.append((["tap fn", "hold"], "Talk to the agent instead.")) }
        }
        rows.append((["click orb"], "A hands-free turn with the agent; it listens until you stop."))
        return rows
    }
}

/// The live "try it" area: the voice host's phase, level and words as you speak, and a text
/// box that dictation pastes into while the overlay has focus.
struct TryItPanel: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        OnboardingPanel(highlighted: model.live.isActive) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Try it").font(.system(size: 14, weight: .semibold))
                    Spacer()
                    StatusPill(text: model.live.connected ? model.live.phase : "offline",
                               ok: model.live.connected && model.live.phase != "failed")
                }
                Text(model.live.headline(keyMode: model.keyMode)).font(.system(size: 13))
                    .foregroundStyle(model.live.phase == "failed" ? OnboardingStyle.warn : .white)
                LevelMeter(level: model.live.isActive ? model.live.inputLevel : 0)
                    .frame(height: 26)
                Text(model.live.partialTranscript.isEmpty ? "Your words appear here as you speak." : model.live.partialTranscript)
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(model.live.partialTranscript.isEmpty ? Color.white.opacity(0.35) : .white)
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $model.tryText)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                    if model.tryText.isEmpty {
                        Text("Click here, then dictate: the words are pasted here.")
                            .font(.system(size: 13)).foregroundStyle(Color.white.opacity(0.35))
                            .padding(.horizontal, 11).padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                }
                .frame(maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.3)))
            }
        }
        .frame(maxHeight: .infinity)
    }
}

struct LevelMeter: View {
    let level: Double
    private let bars = 24

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<bars, id: \.self) { i in
                    let shape = sin(Double(i) / Double(bars - 1) * .pi)
                    let height = max(0.12, min(1, level * 1.6 * (0.45 + 0.55 * shape)))
                    Capsule().fill(level > 0.02 ? OnboardingStyle.accent : Color.white.opacity(0.18))
                        .frame(height: geo.size.height * height)
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}

struct BrainStep: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var settings: VoiceSettingsModel
    @ObservedObject var apps: AppsTabModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepTitle(title: "Brain",
                      subtitle: "The agent you talk to with the agent gesture or by clicking the orb. It works in one folder you choose.")
            let choices = BrainRuntimeChoice.all
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                ForEach(Array(stride(from: 0, to: choices.count, by: 2)), id: \.self) { i in
                    GridRow {
                        ForEach(choices[i..<min(i + 2, choices.count)]) { runtime in
                            runtimeCard(runtime).frame(maxHeight: .infinity)
                        }
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            OnboardingPanel {
                HStack(spacing: 12) {
                    Image(systemName: "folder.fill").font(.system(size: 20)).foregroundStyle(OnboardingStyle.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Workspace folder").font(.system(size: 13, weight: .semibold))
                        Text(model.workspace.isEmpty ? "Required: none chosen yet." : model.workspace)
                            .font(.system(size: 12, design: model.workspace.isEmpty ? .default : .monospaced))
                            .foregroundStyle(model.workspace.isEmpty ? OnboardingStyle.warn : OnboardingStyle.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button(model.workspace.isEmpty ? "Choose Folder…" : "Change…") { model.chooseWorkspace() }
                        .buttonStyle(HUDButtonStyle(kind: model.workspace.isEmpty ? .primary : .secondary))
                        .disabled(!model.voiceHostUp)
                }
            }
            .padding(.top, 12)
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
            .padding(.top, 12)
        }
    }

    private func runtimeCard(_ runtime: BrainRuntimeChoice) -> some View {
        let selected = model.brainEnabled && model.selectedRuntime == runtime.id
        return Button { model.chooseRuntime(runtime.id) } label: {
            OnboardingPanel(highlighted: selected) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(runtime.title).font(.system(size: 14, weight: .semibold))
                        Spacer()
                        detection(runtime.id)
                        Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(selected ? OnboardingStyle.accent : OnboardingStyle.secondary)
                    }
                    Text(runtime.blurb).font(.system(size: 11)).foregroundStyle(OnboardingStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if runtime.id == "mclaude" { mechaHUDLine }
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

    @ViewBuilder private var mechaHUDLine: some View {
        if let row = model.mechaHUD {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.stack").font(.system(size: 11))
                switch row.status.state {
                case .notInstalled:
                    Text("MechaHUD is not installed.").font(.system(size: 11))
                    if let phase = row.phase { Text(phase.text).font(.system(size: 11)).foregroundStyle(OnboardingStyle.secondary) }
                    Button("Install MechaHUD") { apps.install(row.id) }
                        .buttonStyle(HUDButtonStyle(kind: .secondary)).disabled(row.busy)
                default:
                    Text("MechaHUD is installed.").font(.system(size: 11)).foregroundStyle(OnboardingStyle.good)
                }
            }
        } else {
            Text("Get MechaHUD from the Apps step to see the session there too.").font(.system(size: 11))
                .foregroundStyle(OnboardingStyle.secondary)
        }
    }
}

struct AppsStep: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var apps: AppsTabModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepTitle(title: "Apps",
                      subtitle: "HUD apps join the tool dock. Install what you want now; Get Apps… in the menu bar adds more later.")
            if apps.rows.isEmpty {
                OnboardingPanel {
                    HStack {
                        if apps.refreshing { ProgressView().controlSize(.small) }
                        Text(apps.catalogError ?? (apps.refreshing ? "Fetching the app catalog…" : "No apps in the catalog yet."))
                            .font(.system(size: 13)).foregroundStyle(OnboardingStyle.secondary)
                        Spacer()
                        Button("Refresh") { apps.refresh() }.buttonStyle(HUDButtonStyle(kind: .secondary)).disabled(apps.refreshing)
                    }
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12),
                                        GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        ForEach(apps.rows) { row in AppTile(row: row, apps: apps) }
                    }
                }
            }
            Spacer(minLength: 10)
            HStack(spacing: 12) {
                let selected = apps.selectedToInstall
                if !selected.isEmpty {
                    Button("Install selected (\(selected.count))") { apps.installSelected() }
                        .buttonStyle(HUDButtonStyle(kind: .primary))
                }
                Text(apps.catalogError ?? apps.catalogNote).font(.system(size: 11))
                    .foregroundStyle(apps.catalogError == nil ? OnboardingStyle.secondary : .red)
                Spacer()
            }
        }
    }
}

struct AppTile: View {
    let row: AppsTabModel.Row
    @ObservedObject var apps: AppsTabModel

    var body: some View {
        let selected = apps.selected.contains(row.id)
        OnboardingPanel(highlighted: selected && row.status.state == .notInstalled) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    icon.frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.entry.name).font(.system(size: 13, weight: .semibold))
                        Text(row.entry.isBundled ? "\(row.entry.kind) · bundled" : row.entry.kind)
                            .font(.system(size: 10)).foregroundStyle(OnboardingStyle.secondary)
                    }
                    Spacer()
                    if row.status.state == .notInstalled {
                        Button {
                            if selected { apps.selected.remove(row.id) } else { apps.selected.insert(row.id) }
                        } label: {
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 16))
                                .foregroundStyle(selected ? OnboardingStyle.accent : OnboardingStyle.secondary)
                        }
                        .buttonStyle(.plain).disabled(row.busy).help("Select to install")
                    }
                }
                Text(row.entry.summary ?? "").font(.system(size: 11)).foregroundStyle(OnboardingStyle.secondary)
                    .lineLimit(2).frame(minHeight: 28, alignment: .topLeading)
                HStack {
                    if let phase = row.phase {
                        if phase.isBusy { ProgressView().controlSize(.mini) }
                        Text(phase.text).font(.system(size: 10))
                            .foregroundStyle({ if case .failed = phase { return Color.red } else { return OnboardingStyle.secondary } }())
                            .lineLimit(1)
                    }
                    Spacer()
                    switch row.status.state {
                    case .notInstalled:
                        Button("Install") { apps.install(row.id) }.buttonStyle(HUDButtonStyle(kind: .secondary)).disabled(row.busy)
                    case .updateAvailable:
                        Button("Update") { apps.update(row.id) }.buttonStyle(HUDButtonStyle(kind: .secondary)).disabled(row.busy)
                    case .installed, .newerInstalled:
                        StatusPill(text: "Installed", ok: true)
                        Button("Open") { apps.open(row.id) }.buttonStyle(HUDButtonStyle(kind: .quiet))
                    }
                }
            }
        }
    }

    @ViewBuilder private var icon: some View {
        if let path = row.status.installed?.bundleURL.path {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable()
        } else if let url = row.iconURL {
            AsyncImage(url: url) { image in image.resizable().scaledToFit() } placeholder: {
                Image(systemName: "app.dashed").resizable().scaledToFit().foregroundStyle(OnboardingStyle.secondary)
            }
        } else {
            Image(systemName: "app.dashed").resizable().scaledToFit().foregroundStyle(OnboardingStyle.secondary)
        }
    }
}

struct TourStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepTitle(title: "A quick tour", subtitle: "Four things to know. Everything here is also in the menu bar menu.")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                card("circle.fill", "The orb",
                     "Sits under the camera. Click it to talk to the agent; its card shows replies and approvals. Right-click for Mute and Dismiss.",
                     keys: ["click"])
                card("dock.rectangle", "Tool dock",
                     "A strip of your HUD apps at the screen edge. Click an icon to summon the app; drop files on it to hand them over.",
                     keys: [model.tour.toolDock])
                card("rectangle.split.3x1", "Loadouts",
                     "Hold Shift while dragging a window to snap it into a region. Hold the wheel hotkey and drag toward a loadout to apply it.",
                     keys: ["⇧ drag", model.tour.radialWheel])
                card("terminal", "The machud CLI",
                     "Everything is scriptable: machud apply loadout=Work, machud voice status, machud apps install sift, machud onboarding show.",
                     keys: ["machud help"])
            }
            Spacer(minLength: 12)
            Label("Setup Guide… in the menu bar menu opens this again.", systemImage: "menubar.rectangle")
                .font(.system(size: 12)).foregroundStyle(OnboardingStyle.secondary)
        }
    }

    private func card(_ symbol: String, _ title: String, _ text: String, keys: [String]) -> some View {
        OnboardingPanel {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(OnboardingStyle.accent).frame(width: 24)
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Spacer()
                    HStack(spacing: 4) { ForEach(keys, id: \.self) { KeyCap(text: $0) } }
                }
                Text(text).font(.system(size: 12)).foregroundStyle(OnboardingStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(minHeight: 96, alignment: .topLeading)
        }
    }
}
