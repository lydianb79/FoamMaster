import SwiftUI
import MetalKit
import AppKit

/// One flight-simulator session: its own window, controller, renderer, sound and transmitter connection. Fly opens a
/// new one for the design on screen (closing any earlier one); closing it (Exit, Esc, ⌘W, the close button) ends it
/// and releases everything – nothing of one session can leak into the next.
@MainActor
final class SimSession: NSObject, NSWindowDelegate {
    private(set) static var current: SimSession?
    let window: NSWindow
    let controller: SimController
    private var enteredFullScreen = false

    /// Opens the simulator for the project's design (a fresh session every time).
    static func open(_ project: Project) {
        var delay = 0.0
        if let old = current {
            delay = old.window.styleMask.contains(.fullScreen) ? 0.9 : 0   // let it leave its full-screen space first
            old.close()
        }
        let s = SimSession(project)
        current = s
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { s.show() }
    }

    init(_ project: Project) {
        controller = SimController()
        controller.load(project)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Flight Simulator"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        window.contentMinSize = NSSize(width: 900, height: 600)
        window.contentView = NSHostingView(rootView: SimulatorView(ctl: controller).environmentObject(project))
        super.init()
        window.delegate = self
        controller.exitAction = { [weak self] in self?.close() }
    }

    /// Shows the window, in full screen.
    func show() {
        guard Self.current === self else { return }
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        for delay in [0.05, 0.5, 1.2] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.goFullScreen() } }
    }
    private func goFullScreen() {
        guard Self.current === self, window.isVisible, !enteredFullScreen else { return }
        if window.styleMask.contains(.fullScreen) { enteredFullScreen = true; return }
        window.toggleFullScreen(nil)
    }
    func close() { window.close() }

    func windowWillEnterFullScreen(_ notification: Notification) { enteredFullScreen = true }
    func windowDidBecomeKey(_ notification: Notification) { goFullScreen() }
    func windowWillClose(_ notification: Notification) {
        controller.shutdown()
        if Self.current === self { Self.current = nil }
        // Tear down the view (Metal view, renderer, HUD) once the window is gone.
        DispatchQueue.main.async { [window] in window.contentView = nil }
    }
}

/// Flight simulator state shared by the view, the HUD and the controls sheet.
@MainActor
final class SimController: ObservableObject {
    struct HUD { var phase = FlightState.Phase.held; var speed = 0.0; var height = 0.0; var throttle = 0.0; var stick = StickInput(); var message = ""; var time = 0.0; var trim = 0.0 }
    @Published var hud = HUD()
    @Published var title = ""
    @Published var showControls = false
    @Published var autoZoom: Bool
    @Published var volume = Double(SimAudio.volume)
    @Published var muted = SimAudio.muted
    let input = SimInputState()
    let audio = SimAudio()
    private(set) var sim: FlightSim?
    weak var renderer: SimRenderer?
    private(set) var loadedRevision = -1

    private(set) weak var project: Project?

    init() { autoZoom = SimControls.load().autoZoom }

    func load(_ project: Project) {
        self.project = project
        guard let d = project.design, let a = project.analysis else { return }
        let s = FlightSim(model: FlightModel(d, a))
        sim = s
        loadedRevision = project.revision
        title = "\(d.config.name) · \(d.config.kind.title)"
        input.useTrim(for: "\(d.config.kind.rawValue)/\(d.config.name)")
        renderer?.setAircraft(d, a)
        renderer?.sim = s
        renderer?.simulating = true
        input.events = { [weak self] a in self?.event(a) }
    }
    func attach(_ r: SimRenderer, _ project: Project) {
        renderer = r
        r.input = input
        r.autoZoom = autoZoom
        r.audio = audio            // starts with the first frame that draws a model, stops when frames stop
        r.onTick = { [weak self] sim, stick in
            Task { @MainActor in
                self?.hud = HUD(phase: sim.state.phase, speed: sim.airspeed, height: sim.height, throttle: stick.throttle, stick: stick,
                                message: sim.state.message, time: sim.state.time, trim: self?.input.trim ?? 0)
            }
        }
        load(project)
    }
    func event(_ a: SimAction) {
        switch a {
        case .launch: sim?.launch()
        case .reset: sim?.reset()
        case .zoom: setAutoZoom(!autoZoom)
        default: break
        }
    }
    /// Closes the simulator (set by its session).
    var exitAction: (() -> Void)?
    /// The session ends: silence, stop flying, let go of the transmitter.
    func shutdown() {
        audio.stop()
        renderer?.simulating = false
        renderer?.sim = nil
        renderer?.audio = nil
        input.releaseAll()
        sim = nil
    }
    func adjustTrim(_ d: Double) { input.adjustTrim(d); hud.trim = input.trim }
    func resetTrim() { input.setTrim(0); hud.trim = 0 }
    func setVolume(_ v: Double) { volume = v; SimAudio.volume = Float(v); if v > 0, muted { setMuted(false) } }
    func setMuted(_ m: Bool) { muted = m; SimAudio.muted = m }
    func setAutoZoom(_ on: Bool) {
        autoZoom = on; renderer?.autoZoom = on
        input.controls.autoZoom = on; input.controls.save()
    }
}

/// MTKView that takes the keyboard (the sim's keys) while the simulator window is in front; Esc leaves.
final class SimMTKView: MTKView {
    var onKey: ((UInt16, Bool, Bool) -> Void)?
    /// Whether Esc leaves the simulator (only while no simulator action is bound to Esc).
    var escExits: () -> Bool = { true }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53, escExits() { window?.performClose(nil); return }          // Esc
        onKey?(e.keyCode, true, e.isARepeat)
    }
    override func keyUp(with e: NSEvent) { onKey?(e.keyCode, false, false) }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); window?.makeFirstResponder(self) }
}

struct SimMetalView: NSViewRepresentable {
    @ObservedObject var controller: SimController
    var project: Project
    func makeNSView(context: Context) -> SimMTKView {
        let v = SimMTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        if let r = SimRenderer(view: v) {
            v.delegate = r
            context.coordinator.renderer = r
            controller.attach(r, project)
        }
        let input = controller.input
        v.onKey = { code, down, rep in if down { input.keyDown(code, repeat: rep) } else { input.keyUp(code) } }
        v.escExits = { input.controls.escExits }

        return v
    }
    func updateNSView(_ v: SimMTKView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var renderer: SimRenderer? }
}

struct SimulatorView: View {
    @EnvironmentObject var project: Project
    @ObservedObject var ctl: SimController

    var body: some View {
        ZStack(alignment: .topLeading) {
            if project.design != nil {
                SimMetalView(controller: ctl, project: project)
            } else {
                Text("Open or create a design first, then press Fly.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            hud
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(Color.black)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $ctl.showControls) { SimControlsSheet(input: ctl.input) { ctl.showControls = false } }
        .onChange(of: project.revision) { _, _ in
            // A changed design is picked up whenever the plane is not in the air.
            if ctl.hud.phase != .flying { ctl.load(project) }
        }
    }

    private var hud: some View {
        let h = ctl.hud
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "airplane.departure").foregroundStyle(Theme.accent)
                Text(ctl.title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { ctl.setMuted(!ctl.muted) } label: {
                    Image(systemName: ctl.muted ? "speaker.slash.fill" : ctl.volume < 0.4 ? "speaker.wave.1.fill" : "speaker.wave.3.fill").frame(width: 18)
                }
                .buttonStyle(.plain).help(ctl.muted ? "Sound off – click to turn on" : "Sound on – click to mute")
                Slider(value: Binding(get: { ctl.muted ? 0 : ctl.volume }, set: { ctl.setVolume($0) }), in: 0...1).frame(width: 90).controlSize(.small)
                    .help("Volume: motor, airflow, wind, birds")
                Toggle("Auto zoom", isOn: Binding(get: { ctl.autoZoom }, set: { ctl.setAutoZoom($0) })).toggleStyle(.switch).controlSize(.small)
                Button { ctl.load(project) } label: { Label("Reload design", systemImage: "arrow.clockwise") }
                Button { ctl.showControls = true } label: { Label("Controls…", systemImage: "gamecontroller") }
                Button { ctl.exitAction?() } label: { Label("Exit", systemImage: "xmark.circle.fill") }
                    .help(ctl.input.controls.escExits ? "Leave the simulator (Esc)" : "Leave the simulator")
            }
            .padding(10).background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(format: "Speed %.1f m/s (%.0f km/h)", h.speed, h.speed * 3.6))
                    Text(String(format: "Height %.1f m", max(h.height, 0)))
                    HStack(spacing: 6) {
                        Text("Throttle")
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.15)).frame(width: 110, height: 7)
                            Capsule().fill(Theme.orange).frame(width: 110 * h.throttle, height: 7)
                        }
                        Text(String(format: "%.0f %%", h.throttle * 100))
                    }
                    HStack(spacing: 6) {
                        Text("Pitch trim")
                        Button { ctl.adjustTrim(-SimInputState.trimStep) } label: { Image(systemName: "minus") }.help("Nose down (\(keyName(ctl.input.controls.key(.trimDown))))")
                        ZStack {
                            Capsule().fill(.white.opacity(0.15)).frame(width: 70, height: 7)
                            Rectangle().fill(.white.opacity(0.5)).frame(width: 1, height: 9)
                            Circle().fill(Theme.accent).frame(width: 8, height: 8).offset(x: 35 * h.trim / SimInputState.trimLimit)
                        }
                        .frame(width: 70)
                        Button { ctl.adjustTrim(SimInputState.trimStep) } label: { Image(systemName: "plus") }.help("Nose up (\(keyName(ctl.input.controls.key(.trimUp))))")
                        Text(String(format: "%+.0f %%", h.trim * 100)).frame(width: 38, alignment: .leading)
                        Button("0") { ctl.resetTrim() }.help("Trim back to neutral")
                    }
                    .buttonStyle(.borderless).controlSize(.small)
                }
                .font(.system(size: 12, weight: .medium, design: .rounded)).monospacedDigit()
                StickBox(x: h.stick.yaw, y: 2 * h.throttle - 1, label: "Throttle · Rudder")
                StickBox(x: h.stick.roll, y: -h.stick.pitch, label: "Elevator · Aileron")
            }
            .padding(10).background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
            Text(statusText(h)).font(.system(size: 14, weight: .bold)).padding(8)
                .background((h.phase == .crashed ? Color.red : Theme.accent).opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            Spacer()
            Text(keysHint).font(.system(size: 11)).foregroundStyle(.secondary).padding(8).background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(14)
        .foregroundStyle(.white)
    }

    private func statusText(_ h: SimController.HUD) -> String {
        switch h.phase {
        case .held:
            let hasTx = ctl.input.joystick.snapshot(preferring: ctl.input.controls.deviceName) != nil
            let sw = !hasTx ? "" : ctl.input.controls.launchSwitch != nil ? " or flip the launch switch"
                : " (a transmitter switch can launch too: Controls… ▸ Launch & reset)"
            return "In your hand – set the throttle, then press \(keyName(ctl.input.controls.key(.launch)))\(sw) to let it go"
        case .flying: return String(format: "Flying · %.0f s", h.time)
        case .landed:
            let sw = ctl.input.controls.resetSwitch != nil && ctl.input.joystick.snapshot(preferring: ctl.input.controls.deviceName) != nil ? " or flip the reset switch" : ""
            return h.message + " · press \(keyName(ctl.input.controls.key(.reset)))\(sw) to take it back in your hand"
        case .crashed: return h.message + " · back in your hand in a moment"
        }
    }
    private var keysHint: String {
        let c = ctl.input.controls
        let k = { (a: SimAction) in keyName(c.key(a)) }
        return "\(k(.launch)) launch · \(k(.reset)) reset · \(k(.throttleUp))/\(k(.throttleDown)) throttle · \(k(.pitchUp))/\(k(.pitchDown)) elevator · \(k(.rollLeft))/\(k(.rollRight)) aileron · \(k(.yawLeft))/\(k(.yawRight)) rudder · \(k(.trimUp))/\(k(.trimDown)) pitch trim · \(k(.zoom)) zoom\(c.escExits ? " · Esc exit" : "") – or fly with your transmitter (USB, joystick mode)"
    }
}

/// A stick gimbal: dot at (x, y), −1…1.
struct StickBox: View {
    var x: Double, y: Double, label: String
    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.3))
                Path { p in p.move(to: CGPoint(x: 30, y: 2)); p.addLine(to: CGPoint(x: 30, y: 58)); p.move(to: CGPoint(x: 2, y: 30)); p.addLine(to: CGPoint(x: 58, y: 30)) }
                    .stroke(.white.opacity(0.15))
                Circle().fill(Theme.accent).frame(width: 9, height: 9).offset(x: 26 * min(max(x, -1), 1), y: -26 * min(max(y, -1), 1))
            }
            .frame(width: 60, height: 60)
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }
}

/// Keyboard bindings, transmitter mapping and calibration, rates and expo.
struct SimControlsSheet: View {
    let input: SimInputState
    var done: () -> Void
    @State private var controls: SimControls
    @State private var capture: SimAction?
    @State private var device: JoystickManager.Device?
    @State private var calibrating = false
    @State private var calMin: [Int: Double] = [:]
    @State private var calMax: [Int: Double] = [:]
    @State private var detecting: SimChannel?
    @State private var detectStart: [Double] = []
    @State private var monitor: Any?
    @State private var detectingSwitch: WritableKeyPath<SimControls, SimControls.SwitchMapping?>?
    @State private var switchStartAxes: [Double] = []
    @State private var switchStartButtons: [Bool] = []
    private let timer = Timer.publish(every: 1.0 / 20, on: .main, in: .common).autoconnect()

    init(input: SimInputState, done: @escaping () -> Void) {
        self.input = input; self.done = done
        _controls = State(initialValue: input.controls)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Simulator controls").font(.system(size: 17, weight: .bold))
            TabView {
                keyboardTab.tabItem { Text("Keyboard") }
                transmitterTab.tabItem { Text("Transmitter") }
                launchTab.tabItem { Text("Launch & reset") }
                ratesTab.tabItem { Text("Rates & expo") }
            }
            .frame(height: 430)
            HStack {
                Button("Reset to defaults") { let t = controls.trims; controls = SimControls(); controls.trims = t; apply() }
                Spacer()
                Button("Done") { apply(); done() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620)
        .onReceive(timer) { _ in tick() }
        .onAppear {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
                guard let a = capture else { return e }
                controls.keys[a.rawValue] = e.keyCode
                capture = nil; apply()
                return nil
            }
        }
        .onDisappear { if let m = monitor { NSEvent.removeMonitor(m) } }
    }

    private func apply() { input.controls = controls; controls.save() }

    private var keyboardTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("Click a key, then press the new key. Sticks on the keyboard ease in while held and centre when released; the throttle steps up / down while its key is held.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(SimAction.allCases) { a in
                    HStack {
                        Text(a.title).frame(width: 200, alignment: .leading)
                        Button(capture == a ? "Press a key…" : keyName(controls.key(a))) { capture = a }.frame(width: 140)
                    }
                }
            }
            .padding(8)
        }
    }

    private var transmitterTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Fly with the transmitter when one is connected", isOn: Binding(get: { controls.useTransmitter }, set: { controls.useTransmitter = $0; apply() }))
                if let dev = device {
                    Text("Connected: \(dev.name)").font(.system(size: 12, weight: .semibold))
                    // Raw axes.
                    ForEach(Array(dev.axes.enumerated()), id: \.offset) { i, ax in
                        HStack {
                            Text("\(i + 1) · \(JoystickManager.usageName(ax.usage))").frame(width: 80, alignment: .leading).font(.system(size: 11))
                            ProgressView(value: (ax.value - ax.min) / max(ax.max - ax.min, 1)).frame(width: 220)
                            if let cal = controls.calibration[i] {
                                Text(String(format: "cal %.0f / %.0f / %.0f", cal.min, cal.center, cal.max)).font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Divider()
                    ForEach(SimChannel.allCases) { ch in
                        HStack {
                            Text(ch.title).frame(width: 120, alignment: .leading)
                            Picker("", selection: Binding(get: { controls.mapping[ch.rawValue]?.axis ?? -1 }, set: { v in
                                controls.mapping[ch.rawValue] = SimControls.Mapping(axis: v, inverted: controls.mapping[ch.rawValue]?.inverted ?? false); apply()
                            })) {
                                Text("–").tag(-1)
                                ForEach(Array(dev.axes.enumerated()), id: \.offset) { i, ax in Text("\(i + 1) · \(JoystickManager.usageName(ax.usage))").tag(i) }
                            }
                            .labelsHidden().frame(width: 110)
                            Toggle("Invert", isOn: Binding(get: { controls.mapping[ch.rawValue]?.inverted ?? false }, set: { v in
                                controls.mapping[ch.rawValue] = SimControls.Mapping(axis: controls.mapping[ch.rawValue]?.axis ?? -1, inverted: v); apply()
                            }))
                            Button(detecting == ch ? "Move it…" : "Detect") { detecting = ch; detectStart = dev.axes.map(\.value) }
                            if let v = input.transmitter(ch, dev) {
                                ProgressView(value: ch == .throttle ? v : (v + 1) / 2).frame(width: 90)
                            }
                        }
                    }
                    Divider()
                    Text("Launch and reset switches: see the Launch & reset tab.").font(.system(size: 11)).foregroundStyle(.secondary)
                    Divider()
                    if calibrating {
                        Text("Move all sticks to every corner and the throttle from low to high. Then centre the sticks, throttle low, and press Finish.")
                            .font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                        Button("Finish calibration") { finishCalibration(dev) }
                    } else {
                        Button("Calibrate…") { calMin = [:]; calMax = [:]; calibrating = true }
                    }
                } else {
                    Text("No transmitter found. Connect your radio by USB and choose \u{201C}USB Joystick (HID)\u{201D} on it (EdgeTX / OpenTX: USB mode Joystick). Other USB joysticks and gamepads work too.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(8)
        }
    }

    /// Launch and reset: the keys, and a switch / button on the transmitter for each (also without a radio connected,
    /// so it is clear where to set them up).
    private var launchTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("The model starts in your hand. Launch throws it, reset takes it back in your hand – from the keyboard, or with a switch or button on your transmitter.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Keyboard").font(.system(size: 12, weight: .semibold))
                ForEach([SimAction.launch, .reset]) { a in
                    HStack {
                        Text(a == .launch ? "Launch key" : "Reset key").frame(width: 120, alignment: .leading)
                        Button(capture == a ? "Press a key…" : keyName(controls.key(a))) { capture = a }.frame(width: 140)
                    }
                }
                Divider()
                Text("Transmitter").font(.system(size: 12, weight: .semibold))
                if let dev = device {
                    Text("Connected: \(dev.name) – \(dev.axes.count) axes, \(dev.buttons.count) buttons").font(.system(size: 11)).foregroundStyle(.secondary)
                    switchRow(dev, "Launch switch", \.launchSwitch, activeLabel: "LAUNCH",
                              help: "Press Detect, then flip the switch you want to the launch position – that flip throws the model (like the launch key). Works with a switch the radio sends as a button or as a channel (axis); Invert swaps the positions.")
                    switchRow(dev, "Reset switch", \.resetSwitch, activeLabel: "RESET",
                              help: "Press Detect, then flip or press the switch / button you want: the model is back in your hand, any time – in the air or after a landing.")
                } else {
                    Text("No transmitter connected. Connect your radio by USB and choose \u{201C}USB Joystick (HID)\u{201D} on it (EdgeTX / OpenTX: USB mode Joystick); the launch and reset switches can then be set here with Detect. In the radio, give the switches a channel (mixer) or a button in the USB joystick setup so they reach the computer.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if controls.launchSwitch != nil || controls.resetSwitch != nil {
                        Text("Saved: " + [controls.launchSwitch.map { "launch on \(switchLabel($0))" }, controls.resetSwitch.map { "reset on \(switchLabel($0))" }].compactMap { $0 }.joined(separator: ", "))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(8)
        }
    }

    /// A transmitter switch (launch or reset): any button or axis, found with Detect (flip it to the active position).
    @ViewBuilder private func switchRow(_ dev: JoystickManager.Device, _ title: String, _ key: WritableKeyPath<SimControls, SimControls.SwitchMapping?>,
                                        activeLabel: String, help: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).frame(width: 120, alignment: .leading)
                Picker("", selection: Binding(get: { switchTag(controls[keyPath: key]) }, set: { tag in
                    controls[keyPath: key] = switchMapping(tag, inverted: controls[keyPath: key]?.inverted ?? false); apply()
                })) {
                    Text("None").tag("none")
                    ForEach(Array(dev.buttons.indices), id: \.self) { i in Text("Button \(i + 1)").tag("b\(i)") }
                    ForEach(Array(dev.axes.enumerated()), id: \.offset) { i, ax in Text("Axis \(i + 1) · \(JoystickManager.usageName(ax.usage))").tag("a\(i)") }
                }
                .labelsHidden().frame(width: 150)
                Toggle("Invert", isOn: Binding(get: { controls[keyPath: key]?.inverted ?? false }, set: { v in
                    controls[keyPath: key]?.inverted = v; apply()
                }))
                .disabled(controls[keyPath: key] == nil)
                Button(detectingSwitch == key ? "Flip it…" : "Detect") {
                    detectingSwitch = key; switchStartAxes = dev.axes.map(\.value); switchStartButtons = dev.buttons
                }
                if let active = input.switchActive(controls[keyPath: key], dev) {
                    Text(active ? activeLabel : "ready").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(active ? Theme.orange : .secondary)
                }
            }
            Text(help).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func switchLabel(_ m: SimControls.SwitchMapping) -> String {
        (m.kind == .button ? "button \(m.index + 1)" : "axis \(m.index + 1)") + (m.inverted ? " (inverted)" : "")
    }
    private func switchTag(_ m: SimControls.SwitchMapping?) -> String {
        guard let m else { return "none" }
        return (m.kind == .button ? "b" : "a") + "\(m.index)"
    }
    private func switchMapping(_ tag: String, inverted: Bool) -> SimControls.SwitchMapping? {
        guard tag != "none", let i = Int(tag.dropFirst()) else { return nil }
        return SimControls.SwitchMapping(kind: tag.hasPrefix("b") ? .button : .axis, index: i, inverted: inverted)
    }

    private var ratesTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach([SimChannel.roll, .pitch, .yaw]) { ch in
                VStack(alignment: .leading, spacing: 4) {
                    Text(ch.title).font(.system(size: 12, weight: .semibold))
                    HStack {
                        Text("Rate").frame(width: 40, alignment: .leading)
                        Slider(value: Binding(get: { controls.rates[ch.rawValue] ?? 1 }, set: { controls.rates[ch.rawValue] = $0; apply() }), in: 0.3...1)
                        Text(String(format: "%.0f %%", (controls.rates[ch.rawValue] ?? 1) * 100)).frame(width: 44)
                    }
                    HStack {
                        Text("Expo").frame(width: 40, alignment: .leading)
                        Slider(value: Binding(get: { controls.expo[ch.rawValue] ?? 0 }, set: { controls.expo[ch.rawValue] = $0; apply() }), in: 0...0.7)
                        Text(String(format: "%.0f %%", (controls.expo[ch.rawValue] ?? 0) * 100)).frame(width: 44)
                    }
                }
            }
            Toggle("Auto zoom (keeps a small model visible far out)", isOn: Binding(get: { controls.autoZoom }, set: { controls.autoZoom = $0; apply() }))
        }
        .padding(8)
    }

    private func tick() {
        device = input.joystick.snapshot(preferring: controls.deviceName)
        guard let dev = device else { return }
        if controls.deviceName != dev.name { controls.deviceName = dev.name; apply() }
        if calibrating {
            for (i, ax) in dev.axes.enumerated() {
                calMin[i] = min(calMin[i] ?? ax.value, ax.value); calMax[i] = max(calMax[i] ?? ax.value, ax.value)
            }
        }
        detectSwitch(dev)
        // Detect: the axis that moved most since the button was pressed.
        if let ch = detecting, detectStart.count == dev.axes.count {
            let moves = dev.axes.enumerated().map { i, ax in abs(ax.value - detectStart[i]) / max(ax.max - ax.min, 1) }
            if let best = moves.indices.max(by: { moves[$0] < moves[$1] }), moves[best] > 0.3 {
                controls.mapping[ch.rawValue] = SimControls.Mapping(axis: best, inverted: controls.mapping[ch.rawValue]?.inverted ?? false)
                detecting = nil; apply()
            }
        }
    }

    /// Switch detect: a button that changed, else the axis that moved most (≥ 40 %) – not one a stick drives.
    private func detectSwitch(_ dev: JoystickManager.Device) {
        guard let key = detectingSwitch, switchStartAxes.count == dev.axes.count, switchStartButtons.count == dev.buttons.count else { return }
        if let i = dev.buttons.indices.first(where: { dev.buttons[$0] != switchStartButtons[$0] }) {
            controls[keyPath: key] = SimControls.SwitchMapping(kind: .button, index: i, inverted: !dev.buttons[i])
            detectingSwitch = nil; apply(); return
        }
        let sticks = Set(controls.mapping.values.map(\.axis))
        let moves = dev.axes.enumerated().map { i, ax in sticks.contains(i) ? 0 : (ax.value - switchStartAxes[i]) / max(ax.max - ax.min, 1) }
        if let best = moves.indices.max(by: { abs(moves[$0]) < abs(moves[$1]) }), abs(moves[best]) > 0.4 {
            controls[keyPath: key] = SimControls.SwitchMapping(kind: .axis, index: best, inverted: moves[best] < 0)
            detectingSwitch = nil; apply()
        }
    }

    private func finishCalibration(_ dev: JoystickManager.Device) {
        for (i, ax) in dev.axes.enumerated() {
            guard let lo = calMin[i], let hi = calMax[i], hi - lo > (ax.max - ax.min) * 0.2 else { continue }
            controls.calibration[i] = SimControls.Calibration(min: lo, center: ax.value, max: hi)
        }
        calibrating = false; apply()
    }
}
