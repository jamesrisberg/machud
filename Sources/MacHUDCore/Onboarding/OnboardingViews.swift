import AppKit
import HUDKit
import SwiftUI

/// The overlay's content. Full: the desktop shows through a light tint (the window blurs it),
/// with the checklist beside one glass card per section; the welcome page is the checklist
/// itself. Compact: a small card while the user arranges windows or tries the radial menu.
/// Return (or ⌘→) goes on, ⌘← goes back, Esc leaves to finish later.
struct OnboardingRootView: View {
    @ObservedObject var model: OnboardingModel
    /// Renders this step instead of the model's (snapshots).
    var forcedStep: OnboardingStep?
    /// Renders this compact card (snapshots); `.some(nil)` forces the full overlay.
    var forcedCompact: OnboardingModel.Compact??
    /// Whether the window behind blurs the desktop (false in snapshots, which cannot render it).
    var live = true

    static let cardSize = CGSize(width: 800, height: 640)
    static let welcomeSize = CGSize(width: 860, height: 640)
    static let sidebarWidth: CGFloat = 236
    static let compactSize = CGSize(width: 500, height: 164)

    var body: some View {
        let compact = forcedCompact ?? model.compact
        let step = forcedStep ?? model.step
        Group {
            if let compact {
                OnboardingCompactCard(model: model, kind: compact)
                    .frame(width: Self.compactSize.width, height: Self.compactSize.height)
                    .padding(.top, live ? 0 : 44)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                ZStack {
                    // A light tint only: the desktop stays visible through the window's blur.
                    Color.black.opacity(OnboardingStyle.tint)
                    HStack(alignment: .top, spacing: 16) {
                        if step != .welcome {
                            ChecklistSidebar(model: model, step: step)
                                .frame(width: Self.sidebarWidth, height: Self.cardSize.height)
                        }
                        OnboardingCard(model: model, step: step)
                            .frame(width: step == .welcome ? Self.welcomeSize.width : Self.cardSize.width,
                                   height: Self.cardSize.height)
                    }
                    .shadow(color: .black.opacity(0.35), radius: 30, y: 10)
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .environment(\.onboardingLive, live)
        .tint(OnboardingStyle.accent)
    }
}

private struct OnboardingLiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// The overlay is on screen over a live blur (false: an offscreen snapshot).
    var onboardingLive: Bool {
        get { self[OnboardingLiveKey.self] }
        set { self[OnboardingLiveKey.self] = newValue }
    }
}

enum OnboardingStyle {
    static let accent = Color(red: 0.38, green: 0.78, blue: 1.0)
    static let good = Color(red: 0.35, green: 0.85, blue: 0.55)
    static let warn = Color(red: 1.0, green: 0.72, blue: 0.3)
    static let panel = Color.white.opacity(0.07)
    static let stroke = Color.white.opacity(0.14)
    static let secondary = Color.white.opacity(0.66)
    /// Over the whole screen, on top of the blur: enough to settle the desktop, never a cover.
    static let tint = 0.16

    /// A glass card's fill: light over the live blur, heavier in snapshots, where the card
    /// sits on an unblurred picture and the glass itself cannot render.
    static func cardFill(live: Bool) -> Color { Color.black.opacity(live ? 0.24 : 0.5) }
}

/// A glass card: the HUD's frosted glass with a light dark fill, rounded.
struct OnboardingGlass: ViewModifier {
    var radius: CGFloat = 24
    @Environment(\.onboardingLive) private var live

    func body(content: Content) -> some View {
        content
            .background(OnboardingStyle.cardFill(live: live))
            .hudGlass(HUDGlassView.Style(cornerRadius: radius, borderWidth: 1, borderAlpha: 0.22))
    }
}

extension View {
    func onboardingGlass(radius: CGFloat = 24) -> some View { modifier(OnboardingGlass(radius: radius)) }
}

struct OnboardingCard: View {
    @ObservedObject var model: OnboardingModel
    let step: OnboardingStep

    var body: some View {
        VStack(spacing: 0) {
            OnboardingHeader(model: model, step: step)
            Group {
                switch step {
                case .welcome: WelcomeStep(model: model)
                case .permissions: PermissionsStep(model: model)
                case .voice: VoiceStep(model: model, settings: model.voiceSettings)
                case .brain: BrainStep(model: model, settings: model.voiceSettings, apps: model.apps)
                case .apps: AppsStep(model: model, apps: model.apps)
                case .toolDock: ToolDockStep(model: model)
                case .loadout: LoadoutStep(model: model)
                case .radial: RadialStep(model: model)
                case .done: DoneStep(model: model)
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 6)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Rectangle().fill(OnboardingStyle.stroke).frame(height: 1)
            OnboardingFooter(model: model, step: step)
        }
        .foregroundStyle(.white)
        .onboardingGlass(radius: 28)
    }
}

// MARK: - Chrome

/// The close button at the top right of the card.
struct OnboardingHeader: View {
    @ObservedObject var model: OnboardingModel
    let step: OnboardingStep

    var body: some View {
        HStack(spacing: 8) {
            if step.isSection {
                Text("\(OnboardingStep.sections.firstIndex(of: step).map { $0 + 1 } ?? 0) of \(OnboardingStep.sections.count)")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(OnboardingStyle.secondary)
                SectionStatusPill(status: model.status(of: step))
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
        .padding(.top, 14)
        .padding(.bottom, 4)
    }
}

/// The checklist beside every section: each section's state, updating in place; click one to
/// go there.
struct ChecklistSidebar: View {
    @ObservedObject var model: OnboardingModel
    let step: OnboardingStep

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { model.go(to: .welcome) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.3.group.fill").foregroundStyle(OnboardingStyle.accent)
                    Text("MacHUD setup").font(.system(size: 14, weight: .semibold))
                }
            }
            .buttonStyle(.plain)
            .help("Back to the checklist")
            .padding(.bottom, 10)
            ForEach(OnboardingStep.sections, id: \.self) { section in
                Button { model.go(to: section) } label: {
                    HStack(spacing: 10) {
                        StatusMark(status: model.status(of: section), current: section == step)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(section.title).font(.system(size: 13, weight: section == step ? .semibold : .regular))
                            Text(section.summary).font(.system(size: 10)).foregroundStyle(OnboardingStyle.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(section == step ? Color.white.opacity(0.12) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Go to \(section.title)")
            }
            Spacer()
            let done = OnboardingStep.sections.filter { model.status(of: $0) == .done }.count
            Text("\(done) of \(OnboardingStep.sections.count) done").font(.system(size: 11))
                .foregroundStyle(OnboardingStyle.secondary)
            ProgressView(value: Double(done), total: Double(OnboardingStep.sections.count)).tint(OnboardingStyle.good)
        }
        .foregroundStyle(.white)
        .padding(16)
        .onboardingGlass(radius: 22)
    }
}

/// A section's state as a round mark: a check (done), an arrow (skipped), a ring (to do).
struct StatusMark: View {
    let status: OnboardingSectionStatus
    var current = false

    var body: some View {
        ZStack {
            switch status {
            case .done:
                Circle().fill(OnboardingStyle.good)
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.black)
            case .skipped:
                Circle().fill(Color.white.opacity(0.14))
                Image(systemName: "arrow.uturn.right").font(.system(size: 9, weight: .bold)).foregroundStyle(OnboardingStyle.warn)
            case .todo:
                Circle().stroke(current ? OnboardingStyle.accent : Color.white.opacity(0.4), lineWidth: 1.5)
                if current { Circle().fill(OnboardingStyle.accent).frame(width: 8, height: 8) }
            }
        }
        .frame(width: 20, height: 20)
        .accessibilityLabel(status.title)
    }
}

struct SectionStatusPill: View {
    let status: OnboardingSectionStatus

    var body: some View {
        Text(status.title).font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(color)
            .background(Capsule().fill(color.opacity(0.16)))
    }

    private var color: Color {
        switch status {
        case .done: return OnboardingStyle.good
        case .skipped: return OnboardingStyle.warn
        case .todo: return Color.white.opacity(0.75)
        }
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
            if step.isSection, model.status(of: step) != .done {
                Button("Skip for now") { model.skipSection() }
                    .buttonStyle(HUDButtonStyle(kind: .quiet))
            }
            Spacer()
            Text("Return: next  ·  ⌘←: back  ·  Esc: later")
                .font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.45))
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
        case .welcome:
            let started = OnboardingStep.sections.contains { model.status(of: $0) != .todo }
            return started ? "Continue setup" : "Get started"
        case .permissions: return model.permissionsGranted ? "Continue" : "Continue anyway"
        case .brain: return model.brainReady ? "Continue" : "Set up later"
        case .done: return "Finish"
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
        case .secondary: return Color.white.opacity(0.12)
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
        .padding(.bottom, 16)
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
    var large = false

    var body: some View {
        Text(text).font(.system(size: large ? 15 : 11, weight: .semibold, design: .rounded))
            .padding(.horizontal, large ? 10 : 7).padding(.vertical, large ? 5 : 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.14)))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.25)))
    }
}

// MARK: - Steps

/// The welcome page: what MacHUD is, and the checklist of every section with its state.
struct WelcomeStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "rectangle.3.group.fill").font(.system(size: 38)).foregroundStyle(OnboardingStyle.accent)
                StepTitle(title: "Welcome to MacHUD", subtitle: "Let's get you set up:")
            }
            VStack(spacing: 6) {
                ForEach(OnboardingStep.sections, id: \.self) { section in
                    Button { model.go(to: section) } label: {
                        HStack(spacing: 12) {
                            StatusMark(status: model.status(of: section))
                            Image(systemName: section.symbol).font(.system(size: 15)).foregroundStyle(OnboardingStyle.accent)
                                .frame(width: 22)
                            Text(section.title).font(.system(size: 14, weight: .semibold)).frame(width: 120, alignment: .leading)
                            Text(section.summary).font(.system(size: 12)).foregroundStyle(OnboardingStyle.secondary)
                            Spacer()
                            SectionStatusPill(status: model.status(of: section))
                            Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(OnboardingStyle.secondary)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(OnboardingStyle.panel))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Go to \(section.title)")
                }
            }
            Spacer(minLength: 12)
            Text("Setup takes a few minutes. Press Esc or ✕ to dismiss; open it again from the menu bar anytime.")
                .font(.system(size: 12)).foregroundStyle(OnboardingStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct PermissionsStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepTitle(title: "Permissions", subtitle: "Grant these permissions so MacHUD can work at full power.")
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
            StepTitle(title: "Voice", subtitle: "Dictate into any app and talk to your MacHUD agent.")
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 14) {
                    OnboardingPanel {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle(isOn: Binding(get: { model.voiceOn }, set: { model.setVoice(on: $0) })) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Voice on").font(.system(size: 14, weight: .semibold))
                                    Text("The fn gestures, the orb at the top of your screen and the wake word.")
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
                    SpeechModelPanel(model: model, settings: settings)
                    WakeWordPanel(model: model, settings: settings)
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

/// The wake word (off by default): on/off, the phrase from those there is a model for, and
/// that model's state with Download and its terms.
struct WakeWordPanel: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var settings: VoiceSettingsModel

    var body: some View {
        OnboardingPanel {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("Wake word").font(.system(size: 13, weight: .semibold)).fixedSize()
                    Toggle("Wake word", isOn: Binding(get: { model.wakeWordOn }, set: { model.setWakeWord(on: $0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(!model.voiceOn || model.wakePhrase == nil)
                    Spacer(minLength: 8)
                    if let chosen = model.wakePhrase, model.wakePhrases.count > 1 {
                        Picker("Phrase", selection: Binding(get: { chosen.id }, set: { id in
                            if let phrase = model.wakePhrases.first(where: { $0.id == id }) { model.setWakePhrase(phrase.phrase) }
                        })) {
                            ForEach(model.wakePhrases) { Text($0.phrase).tag($0.id) }
                        }
                        .labelsHidden().fixedSize().disabled(!model.voiceOn)
                    } else if let chosen = model.wakePhrase {
                        Text("“\(chosen.phrase)”").font(.system(size: 12, weight: .medium)).fixedSize()
                    }
                    modelState
                }
                Text(caption).font(.system(size: 11))
                    .foregroundStyle(model.wakeProblem == nil && model.wakeNote == nil ? OnboardingStyle.secondary : OnboardingStyle.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var modelState: some View {
        if let chosen = model.wakePhrase {
            if chosen.model.installed {
                StatusPill(text: "Installed", ok: true)
            } else if chosen.model.downloading {
                ProgressView(value: chosen.model.progress).frame(width: 70)
                Text("\(Int(chosen.model.progress * 100))%").font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(OnboardingStyle.secondary)
            } else {
                Button("Download") { model.downloadWakeModel() }
                    .help("About \(chosen.model.size)")
                    .buttonStyle(HUDButtonStyle(kind: .secondary)).fixedSize()
                    .disabled(!model.voiceHostUp)
            }
        }
    }

    private var caption: String {
        if let note = model.wakeNote { return note }
        if let problem = model.wakeProblem { return problem }
        guard let chosen = model.wakePhrase else { return "The wake word's phrases show here once voice is on." }
        let say = "Say “\(chosen.phrase)” to talk to the agent hands-free; the microphone stays open while it is on."
        return chosen.note.isEmpty ? say : "\(say) \(chosen.note)"
    }
}

/// The speech model dictation needs (installed, downloading, or Download) and whether
/// finished dictations are kept, shared with SpeakFree when it is installed.
struct SpeechModelPanel: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var settings: VoiceSettingsModel

    var body: some View {
        OnboardingPanel {
            VStack(alignment: .leading, spacing: 10) {
                speechModelRow
                Picker("History", selection: Binding(get: { model.history?.mode ?? "off" },
                                                     set: { model.setHistoryMode($0) })) {
                    ForEach(VoiceSettingsModel.historyModes, id: \.0) { Text($0.1).tag($0.0) }
                }
                .pickerStyle(.segmented)
                .font(.system(size: 12))
                .disabled(!model.voiceHostUp)
                if model.history?.speakFreeInstalled == true {
                    Toggle("Share history with SpeakFree", isOn: Binding(
                        get: { model.history?.shareWithSpeakFree ?? false }, set: { model.setShareHistory($0) }))
                        .toggleStyle(.switch).font(.system(size: 12)).disabled(!model.voiceHostUp)
                }
                Text(historyNote).font(.system(size: 11)).foregroundStyle(OnboardingStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var speechModelRow: some View {
        HStack(spacing: 8) {
            Text("Speech model").font(.system(size: 13, weight: .semibold)).fixedSize()
            if let parakeet = model.parakeet {
                if parakeet.installed {
                    StatusPill(text: "Installed", ok: true)
                } else if parakeet.downloading {
                    Text("Downloading…").font(.system(size: 11))
                    ProgressView(value: parakeet.progress).frame(width: 150)
                    Text("\(Int(parakeet.progress * 100))%").font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(OnboardingStyle.secondary)
                } else {
                    Spacer()
                    Button(parakeet.bytes.map { "Download (\(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)))" }
                           ?? "Download") { model.downloadParakeet() }
                        .buttonStyle(HUDButtonStyle(kind: .primary)).fixedSize()
                }
            } else {
                Text(model.parakeetNote ?? "The speech model's state shows here once voice is on.")
                    .font(.system(size: 11)).foregroundStyle(OnboardingStyle.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var historyNote: String {
        if model.parakeet?.installed == false, model.parakeet?.downloading == false {
            return "Dictation turns speech into text on this Mac with Parakeet; download it once (SpeakFree shares it)."
        }
        guard let history = model.history else { return "Keep a history of what you dictate, or not." }
        if history.mode == "off" { return "Dictations are not kept." }
        let folder = (history.folder as NSString).abbreviatingWithTildeInPath
        return history.shareWithSpeakFree ? "Kept with SpeakFree's history in \(folder)." : "Kept in \(folder)."
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
