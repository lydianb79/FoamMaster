import Foundation
import AppKit
import IOKit.hid
import Carbon

/// Keyboard actions of the simulator.
enum SimAction: String, CaseIterable, Codable, Identifiable {
    case throttleUp, throttleDown, pitchUp, pitchDown, rollLeft, rollRight, yawLeft, yawRight, trimUp, trimDown, launch, reset, zoom
    var id: String { rawValue }
    var title: String {
        [.throttleUp: "Throttle up", .throttleDown: "Throttle down", .pitchUp: "Elevator up (pull)", .pitchDown: "Elevator down (push)",
         .rollLeft: "Aileron left", .rollRight: "Aileron right", .yawLeft: "Rudder left", .yawRight: "Rudder right",
         .trimUp: "Pitch trim nose up", .trimDown: "Pitch trim nose down",
         .launch: "Launch (let go)", .reset: "Reset", .zoom: "Auto zoom on / off"][self]!
    }
    var defaultKey: UInt16 {
        [.throttleUp: UInt16(kVK_ANSI_W), .throttleDown: UInt16(kVK_ANSI_S), .pitchUp: UInt16(kVK_DownArrow), .pitchDown: UInt16(kVK_UpArrow),
         .rollLeft: UInt16(kVK_LeftArrow), .rollRight: UInt16(kVK_RightArrow), .yawLeft: UInt16(kVK_ANSI_A), .yawRight: UInt16(kVK_ANSI_D),
         .trimUp: UInt16(kVK_ANSI_T), .trimDown: UInt16(kVK_ANSI_G),
         .launch: UInt16(kVK_Space), .reset: UInt16(kVK_ANSI_R), .zoom: UInt16(kVK_ANSI_Z)][self]!
    }
}

/// The four flight channels a transmitter axis can drive.
enum SimChannel: String, CaseIterable, Codable, Identifiable {
    case throttle, roll, pitch, yaw
    var id: String { rawValue }
    var title: String { [.throttle: "Throttle", .roll: "Aileron (roll)", .pitch: "Elevator (pitch)", .yaw: "Rudder (yaw)"][self]! }
}

/// Everything the pilot sets up – saved in the user defaults.
struct SimControls: Codable, Equatable {
    struct Mapping: Codable, Equatable { var axis: Int; var inverted: Bool }
    struct Calibration: Codable, Equatable { var min: Double; var center: Double; var max: Double }
    var keys: [String: UInt16] = Dictionary(uniqueKeysWithValues: SimAction.allCases.map { ($0.rawValue, $0.defaultKey) })
    /// Transmitter (USB joystick): axis per channel, calibration per axis (by index), the device it was set up for.
    var mapping: [String: Mapping] = ["throttle": Mapping(axis: 2, inverted: false), "roll": Mapping(axis: 0, inverted: false),
                                      "pitch": Mapping(axis: 1, inverted: false), "yaw": Mapping(axis: 3, inverted: false)]
    var calibration: [Int: Calibration] = [:]
    var deviceName = ""
    var useTransmitter = true
    /// Rates (0.3…1) and expo (0…0.7) per stick channel.
    var rates: [String: Double] = ["roll": 0.8, "pitch": 0.8, "yaw": 1.0]
    var expo: [String: Double] = ["roll": 0.3, "pitch": 0.3, "yaw": 0.2]
    var autoZoom = true
    /// Pitch trim per design (−0.3…0.3 of the elevator throw, + = nose up). Optional so older settings still load.
    var trims: [String: Double]?
    /// A transmitter switch that launches the model when flipped to its active position.
    struct SwitchMapping: Codable, Equatable {
        enum Kind: String, Codable { case axis, button }
        var kind: Kind; var index: Int; var inverted: Bool
    }
    var launchSwitch: SwitchMapping?
    /// A transmitter switch / button that puts the model back in the hand (like the reset key).
    var resetSwitch: SwitchMapping?
    /// Mix: the aileron stick also steers the rudder (NutBall – no ailerons). Optional: on unless switched off.
    var rollToRudder: Bool?
    var mixesRollToRudder: Bool { rollToRudder ?? true }

    func key(_ a: SimAction) -> UInt16 { keys[a.rawValue] ?? a.defaultKey }
    /// Esc leaves the simulator unless one of its actions is bound to Esc.
    var escExits: Bool { !SimAction.allCases.contains { key($0) == UInt16(kVK_Escape) } }
    static let storageKey = "simControls"
    static func load() -> SimControls {
        guard let d = UserDefaults.standard.data(forKey: storageKey), let c = try? JSONDecoder().decode(SimControls.self, from: d) else { return SimControls() }
        return c
    }
    func save() { if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: Self.storageKey) } }

    /// Rate and expo on a stick value −1…1.
    func shaped(_ ch: SimChannel, _ x: Double) -> Double {
        let r = rates[ch.rawValue] ?? 1, e = expo[ch.rawValue] ?? 0
        return r * (e * x * x * x + (1 - e) * x)
    }
}

/// Name for a key code (for the key binding list).
func keyName(_ code: UInt16) -> String {
    let names: [Int: String] = [kVK_Space: "Space", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
                                kVK_Return: "Return", kVK_Tab: "Tab", kVK_Escape: "Esc", kVK_Shift: "Shift", kVK_Control: "Ctrl", kVK_Option: "Option"]
    if let n = names[Int(code)] { return n }
    let src = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
    guard let layoutPtr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return "#\(code)" }
    let data = unsafeBitCast(layoutPtr, to: CFData.self) as Data
    var dead: UInt32 = 0
    var chars = [UniChar](repeating: 0, count: 4)
    var len = 0
    let status = data.withUnsafeBytes { buf -> OSStatus in
        UCKeyTranslate(buf.baseAddress!.assumingMemoryBound(to: UCKeyboardLayout.self), code, UInt16(kUCKeyActionDisplay), 0,
                       UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
    }
    return status == noErr && len > 0 ? String(utf16CodeUnits: chars, count: len).uppercased() : "#\(code)"
}

/// USB transmitters in joystick mode (EdgeTX / OpenTX / FrSky / RadioMaster …) and other HID joysticks / gamepads:
/// every analogue axis (X, Y, Z, Rx, Ry, Rz, sliders, dials) as a raw value with its logical range.
final class JoystickManager {
    struct Axis { var usage: Int; var min: Double; var max: Double; var value: Double }
    struct Device { var name: String; var axes: [Axis]; var buttons: [Bool] = [] }
    private var manager: IOHIDManager?
    private(set) var devices: [IOHIDDevice] = []
    private var elements: [IOHIDDevice: [IOHIDElement]] = [:]
    private let lock = NSLock()
    private var values: [IOHIDDevice: [Double]] = [:]
    private var buttonElements: [IOHIDDevice: [IOHIDElement]] = [:]
    private var buttonValues: [IOHIDDevice: [Bool]] = [:]
    var onChange: (() -> Void)?

    init() {
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [[String: Int]] = [kHIDUsage_GD_Joystick, kHIDUsage_GD_GamePad, kHIDUsage_GD_MultiAxisController].map {
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: $0]
        }
        IOHIDManagerSetDeviceMatchingMultiple(m, match as CFArray)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(m, { ctx, _, _, dev in
            Unmanaged<JoystickManager>.fromOpaque(ctx!).takeUnretainedValue().added(dev)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(m, { ctx, _, _, dev in
            Unmanaged<JoystickManager>.fromOpaque(ctx!).takeUnretainedValue().removed(dev)
        }, ctx)
        IOHIDManagerRegisterInputValueCallback(m, { ctx, _, _, value in
            Unmanaged<JoystickManager>.fromOpaque(ctx!).takeUnretainedValue().input(value)
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = m
    }
    deinit { if let m = manager { IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone)) } }

    static let axisUsages = [kHIDUsage_GD_X, kHIDUsage_GD_Y, kHIDUsage_GD_Z, kHIDUsage_GD_Rx, kHIDUsage_GD_Ry, kHIDUsage_GD_Rz,
                             kHIDUsage_GD_Slider, kHIDUsage_GD_Dial, kHIDUsage_GD_Wheel]
    static func usageName(_ u: Int) -> String {
        [kHIDUsage_GD_X: "X", kHIDUsage_GD_Y: "Y", kHIDUsage_GD_Z: "Z", kHIDUsage_GD_Rx: "Rx", kHIDUsage_GD_Ry: "Ry", kHIDUsage_GD_Rz: "Rz",
         kHIDUsage_GD_Slider: "Slider", kHIDUsage_GD_Dial: "Dial", kHIDUsage_GD_Wheel: "Wheel"][u] ?? "Axis \(u)"
    }

    private func added(_ dev: IOHIDDevice) {
        guard let els = IOHIDDeviceCopyMatchingElements(dev, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] else { return }
        let axes = els.filter { e in
            IOHIDElementGetUsagePage(e) == UInt32(kHIDPage_GenericDesktop) && Self.axisUsages.contains(Int(IOHIDElementGetUsage(e)))
                && IOHIDElementGetLogicalMax(e) > IOHIDElementGetLogicalMin(e)
        }.sorted { a, b in
            let ia = Self.axisUsages.firstIndex(of: Int(IOHIDElementGetUsage(a))) ?? 99, ib = Self.axisUsages.firstIndex(of: Int(IOHIDElementGetUsage(b))) ?? 99
            return ia == ib ? IOHIDElementGetCookie(a) < IOHIDElementGetCookie(b) : ia < ib
        }
        guard !axes.isEmpty else { return }
        // Buttons (transmitter switches are often sent as buttons), in usage order.
        var seen = Set<UInt32>()
        let buttons = els.filter { IOHIDElementGetUsagePage($0) == UInt32(kHIDPage_Button) && IOHIDElementGetUsage($0) > 0 }
            .sorted { IOHIDElementGetUsage($0) < IOHIDElementGetUsage($1) }
            .filter { seen.insert(IOHIDElementGetUsage($0)).inserted }
        lock.lock()
        devices.append(dev); elements[dev] = axes
        buttonElements[dev] = buttons; buttonValues[dev] = buttons.map { _ in false }
        values[dev] = axes.map { e in Double(IOHIDElementGetLogicalMin(e) + IOHIDElementGetLogicalMax(e)) / 2 }
        lock.unlock()
        DispatchQueue.main.async { self.onChange?() }
    }
    private func removed(_ dev: IOHIDDevice) {
        lock.lock(); devices.removeAll { $0 == dev }; elements[dev] = nil; values[dev] = nil; buttonElements[dev] = nil; buttonValues[dev] = nil; lock.unlock()
        DispatchQueue.main.async { self.onChange?() }
    }
    private func input(_ value: IOHIDValue) {
        let e = IOHIDValueGetElement(value)
        let dev = IOHIDElementGetDevice(e)
        lock.lock(); defer { lock.unlock() }
        if let els = elements[dev], let i = els.firstIndex(of: e) { values[dev]?[i] = Double(IOHIDValueGetIntegerValue(value)); return }
        if let bs = buttonElements[dev], let i = bs.firstIndex(where: { IOHIDElementGetUsage($0) == IOHIDElementGetUsage(e) && IOHIDElementGetUsagePage(e) == UInt32(kHIDPage_Button) }) {
            buttonValues[dev]?[i] = IOHIDValueGetIntegerValue(value) != 0
        }
    }

    static func name(_ dev: IOHIDDevice) -> String {
        (IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String) ?? "USB joystick"
    }
    /// The first device (or the one with this name): its name and axes with their raw values and logical ranges.
    func snapshot(preferring name: String) -> Device? {
        lock.lock(); defer { lock.unlock() }
        guard let dev = devices.first(where: { Self.name($0) == name }) ?? devices.first, let els = elements[dev], let vals = values[dev] else { return nil }
        return Device(name: Self.name(dev), axes: zip(els, vals).map { e, v in
            Axis(usage: Int(IOHIDElementGetUsage(e)), min: Double(IOHIDElementGetLogicalMin(e)), max: Double(IOHIDElementGetLogicalMax(e)), value: v)
        }, buttons: buttonValues[dev] ?? [])
    }
}

/// Combines keyboard and transmitter into stick inputs.
final class SimInputState {
    var controls = SimControls.load()
    let joystick = JoystickManager()
    private(set) var pressed = Set<UInt16>()
    /// Keyboard sticks ease towards the held direction and back to centre; the throttle steps while its key is held.
    private(set) var keyStick = StickInput()
    var events: ((SimAction) -> Void)?
    /// The loaded model has no ailerons but a rudder (NutBall): the roll-to-rudder mix can apply.
    var rudderOnly = false
    /// Pitch trim of the loaded design (+ = nose up), added to the elevator from keyboard or transmitter.
    private(set) var trim = 0.0
    private var trimKey = ""
    static let trimStep = 0.01, trimLimit = 0.3
    private var lastSwitch: Bool?
    private var lastReset: Bool?

    /// The trim saved for this design.
    func useTrim(for design: String) {
        trimKey = design
        trim = controls.trims?[design] ?? 0
    }
    func adjustTrim(_ delta: Double) { setTrim(trim + delta) }
    func setTrim(_ v: Double) {
        trim = (min(max(v, -Self.trimLimit), Self.trimLimit) / Self.trimStep).rounded() * Self.trimStep
        var t = controls.trims ?? [:]
        t[trimKey] = trim == 0 ? nil : trim
        controls.trims = t
        controls.save()
    }

    /// Whether a switch is in its active position (nil: not set up or not on this transmitter).
    func switchActive(_ sw: SimControls.SwitchMapping?, _ dev: JoystickManager.Device) -> Bool? {
        guard let sw else { return nil }
        switch sw.kind {
        case .button:
            guard sw.index < dev.buttons.count else { return nil }
            return dev.buttons[sw.index] != sw.inverted
        case .axis:
            guard sw.index < dev.axes.count else { return nil }
            let ax = dev.axes[sw.index]
            let n = (ax.value - ax.min) / max(ax.max - ax.min, 1)
            return sw.inverted ? n < 0.25 : n > 0.75
        }
    }
    func launchSwitchActive(_ dev: JoystickManager.Device) -> Bool? { switchActive(controls.launchSwitch, dev) }
    func resetSwitchActive(_ dev: JoystickManager.Device) -> Bool? { switchActive(controls.resetSwitch, dev) }

    /// Feeds the launch switch position; a flip into the active position launches.
    func switchState(_ active: Bool?) {
        if let active, let last = lastSwitch, active, !last { events?(.launch) }
        lastSwitch = active
    }
    /// Feeds the reset switch position; a flip (or press) into the active position puts the model back in the hand.
    func resetSwitchState(_ active: Bool?) {
        if let active, let last = lastReset, active, !last { events?(.reset) }
        lastReset = active
    }

    func keyDown(_ code: UInt16, repeat isRepeat: Bool) {
        pressed.insert(code)
        // Trim steps on every press and while the key is held.
        if code == controls.key(.trimUp) { adjustTrim(Self.trimStep); return }
        if code == controls.key(.trimDown) { adjustTrim(-Self.trimStep); return }
        guard !isRepeat else { return }
        for a in [SimAction.launch, .reset, .zoom] where controls.key(a) == code { events?(a) }
    }
    func keyUp(_ code: UInt16) { pressed.remove(code) }
    /// Forget held keys (the window lost them, e.g. on close).
    func releaseAll() { pressed.removeAll() }
    private func held(_ a: SimAction) -> Bool { pressed.contains(controls.key(a)) }

    /// Raw −1…1 (sticks) / 0…1 (throttle) value of a channel from the transmitter, calibrated; nil without one.
    func transmitter(_ ch: SimChannel, _ dev: JoystickManager.Device) -> Double? {
        guard let m = controls.mapping[ch.rawValue], m.axis >= 0, m.axis < dev.axes.count else { return nil }
        let ax = dev.axes[m.axis]
        let cal = controls.calibration[m.axis] ?? SimControls.Calibration(min: ax.min, center: (ax.min + ax.max) / 2, max: ax.max)
        var v: Double
        if ch == .throttle {
            v = (ax.value - cal.min) / max(cal.max - cal.min, 1)
            if m.inverted { v = 1 - v }
            return min(max(v, 0), 1)
        }
        v = ax.value >= cal.center ? (ax.value - cal.center) / max(cal.max - cal.center, 1) : (ax.value - cal.center) / max(cal.center - cal.min, 1)
        if m.inverted { v = -v }
        if abs(v) < 0.02 { v = 0 }
        return min(max(v, -1), 1)
    }

    /// Current stick input (shaped by rates and expo).
    func update(_ dt: Double) -> StickInput {
        func ease(_ cur: Double, _ neg: SimAction, _ pos: SimAction) -> Double {
            let target = (held(pos) ? 1.0 : 0) - (held(neg) ? 1.0 : 0)
            let rate = target == 0 ? 6.0 : 3.0
            return cur + max(min(target - cur, rate * dt), -rate * dt)
        }
        keyStick.roll = ease(keyStick.roll, .rollLeft, .rollRight)
        keyStick.pitch = ease(keyStick.pitch, .pitchDown, .pitchUp)
        keyStick.yaw = ease(keyStick.yaw, .yawLeft, .yawRight)
        keyStick.throttle = min(max(keyStick.throttle + ((held(.throttleUp) ? 1 : 0) - (held(.throttleDown) ? 1 : 0)) * 0.7 * dt, 0), 1)
        var out = keyStick
        if controls.useTransmitter, let dev = joystick.snapshot(preferring: controls.deviceName) {
            if let v = transmitter(.roll, dev), abs(keyStick.roll) < 0.01 { out.roll = v }
            if let v = transmitter(.pitch, dev), abs(keyStick.pitch) < 0.01 { out.pitch = v }
            if let v = transmitter(.yaw, dev), abs(keyStick.yaw) < 0.01 { out.yaw = v }
            if let v = transmitter(.throttle, dev) { out.throttle = v; keyStick.throttle = v }
            // Launch switch: flipping it into its active position throws the model (a switch already there when
            // the simulator starts has to be flipped again).
            switchState(launchSwitchActive(dev))
            resetSwitchState(resetSwitchActive(dev))
        } else {
            lastSwitch = nil; lastReset = nil
        }
        out.roll = controls.shaped(.roll, out.roll); out.pitch = controls.shaped(.pitch, out.pitch); out.yaw = controls.shaped(.yaw, out.yaw)
        out.pitch = min(max(out.pitch + trim, -1), 1)
        // Mix (Controls ▸ Mixes): on the NutBall the aileron stick also works the rudder.
        if rudderOnly, controls.mixesRollToRudder { out.yaw = min(max(out.yaw + out.roll, -1), 1) }
        return out
    }
}
