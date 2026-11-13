import Foundation
import AVFoundation
import os
import simd

/// Procedural sound for the flight simulator, synthesised sample by sample (no sound files):
/// the motor (commutation whine + propeller blade-pass buzz, pitch from the throttle, Doppler, distance and air
/// absorption), airflow over the model, wind in the grass with gusts, birdsong and crickets panned around the pilot,
/// and one-shot launch / landing / crash sounds.
final class SimAudio {
    /// What the synthesiser needs, written by the render loop, read once per audio buffer.
    struct Params {
        var throttle: Float = 0
        var motorOn = false
        var distance: Float = 2
        var radialSpeed: Float = 0      // m/s, + = moving away
        var airspeed: Float = 0
        var pan: Float = 0              // −1 left … +1 right of where the pilot looks
        var viewAzimuth: Float = 0      // radians, where the pilot looks (for world-fixed birds)
        var volume: Float = 0.8
    }
    enum Event { case launch, land, crash }

    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private let lock = OSAllocatedUnfairLock(initialState: (Params(), [Event]()))
    private var running = false
    private var lastPhase: FlightState.Phase = .held
    private var lastDistance: Float = 2

    static var volume: Float {
        get { UserDefaults.standard.object(forKey: "simVolume") as? Float ?? 0.8 }
        set { UserDefaults.standard.set(newValue, forKey: "simVolume") }
    }
    static var muted: Bool {
        get { UserDefaults.standard.bool(forKey: "simMuted") }
        set { UserDefaults.standard.set(newValue, forKey: "simMuted") }
    }

    func start() {
        guard !running else { return }
        let out = engine.outputNode.inputFormat(forBus: 0)
        let rate = out.sampleRate > 0 ? out.sampleRate : 44100
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else { return }
        let synth = Synth(rate: Float(rate))
        let lock = lock
        let node = AVAudioSourceNode(format: fmt) { _, _, frames, abl -> OSStatus in
            let (p, ev) = lock.withLock { s -> (Params, [Event]) in let e = s.1; s.1.removeAll(); return (s.0, e) }
            for e in ev { synth.trigger(e) }
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            guard buffers.count >= 2, let l = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            synth.render(p, l, r, Int(frames))
            return noErr
        }
        source = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: fmt)
        do { try engine.start(); running = true } catch { running = false }
    }

    func stop() {
        guard running else { return }
        engine.stop()
        if let source { engine.detach(source) }
        source = nil
        running = false
    }

    /// Called every frame from the render loop with the sim state and the pilot's eye.
    func update(sim: FlightSim, eye: SIMD3<Double>, dt: Double) {
        guard running else { return }
        let st = sim.state
        let rel = st.position - eye
        let dist = Float(max(simd_length(rel), 0.3))
        let radial = Float(simd_dot(st.velocity, rel / Double(dist)))
        let az = Float(atan2(rel.x, -rel.z))
        var p = Params()
        p.motorOn = st.phase == .held || st.phase == .flying
        p.throttle = p.motorOn ? Float(sim.surfaces.throttle) : 0
        p.distance = dist
        p.radialSpeed = radial
        p.airspeed = Float(sim.airspeed)
        p.pan = 0            // the pilot follows the model with the head: it stays in front
        p.viewAzimuth = az
        p.volume = Self.muted ? 0 : Self.volume
        var events: [Event] = []
        if st.phase != lastPhase {
            switch st.phase {
            case .flying where lastPhase == .held: events.append(.launch)
            case .landed: events.append(.land)
            case .crashed where st.message.hasPrefix("Crashed"): events.append(.crash)
            default: break
            }
            lastPhase = st.phase
        }
        lastDistance = dist
        lock.withLock { s in s.0 = p; s.1.append(contentsOf: events) }
    }
}

/// The synthesiser state; only touched from the audio thread.
final class Synth {
    let rate: Float
    init(rate: Float) { self.rate = rate }

    // Smoothed parameters.
    var thr: Float = 0, dist: Float = 2, radial: Float = 0, air: Float = 0, vol: Float = 0, motorGain: Float = 0, az: Float = 0
    // Oscillators and filters.
    var bladePhase: Float = 0, whinePhase: Float = 0, whine2Phase: Float = 0
    var motorLP: Float = 0, motorLP2: Float = 0
    var windL: Float = 0, windR: Float = 0, windL2: Float = 0, windR2: Float = 0, gust: Float = 0.5, gustTarget: Float = 0.5, gustTimer: Float = 0
    var airLP: Float = 0, airHP: Float = 0
    var seed: UInt32 = 0x1234_5678

    // Birds: a phrase of chirps every few seconds from a random direction.
    struct Bird { var phase: Float = 0; var t: Float = 0; var chirp = 0; var chirps = 0; var chirpLen: Float = 0.1; var gap: Float = 0.05
        var f0: Float = 3000; var f1: Float = 4000; var az: Float = 0; var gain: Float = 0; var trill: Float = 0 }
    var birds: [Bird] = []
    var nextBird: Float = 1.5
    // Crickets: pulse trains.
    var cricketPhase: Float = 0, cricketPulse: Float = 0, cricketChirp: Float = 0

    // One-shots.
    struct Shot { var kind: SimAudio.Event; var t: Float = 0; var lp: Float = 0; var phase: Float = 0 }
    var shots: [Shot] = []

    func trigger(_ e: SimAudio.Event) { shots.append(Shot(kind: e)) }

    @inline(__always) func white() -> Float {
        seed = seed &* 1_664_525 &+ 1_013_904_223
        return Float(Int32(bitPattern: seed)) / Float(Int32.max)
    }
    @inline(__always) func coef(_ hz: Float) -> Float { 1 - exp(-2 * .pi * min(hz, rate * 0.45) / rate) }

    func render(_ p: SimAudio.Params, _ L: UnsafeMutablePointer<Float>, _ R: UnsafeMutablePointer<Float>, _ n: Int) {
        let dt = 1 / rate
        let smooth: Float = 1 - exp(-dt * 12)
        let twoPi: Float = 2 * .pi
        for i in 0..<n {
            thr += (p.throttle - thr) * smooth * 0.6
            dist += (p.distance - dist) * smooth
            radial += (p.radialSpeed - radial) * smooth
            air += (p.airspeed - air) * smooth
            vol += (p.volume - vol) * smooth
            az += (p.viewAzimuth - az) * smooth
            motorGain += ((p.motorOn ? 1 : 0) - motorGain) * smooth

            // --- Motor: prop rps from the throttle, Doppler from the radial speed.
            let doppler = 343 / max(343 + radial, 200)
            let rps = (25 + 330 * pow(thr, 0.75)) * doppler
            bladePhase += 2 * rps * dt; if bladePhase >= 1 { bladePhase -= 1 }
            whinePhase += 7 * rps * dt; if whinePhase >= 1 { whinePhase -= 1 }
            whine2Phase += 14 * rps * dt; if whine2Phase >= 1 { whine2Phase -= 1 }
            // Blade pass: a buzzy pulse (skewed saw), the whine: two sine partials, chopped air noise.
            let saw = bladePhase * 2 - 1
            let buzz = saw * abs(saw)
            let whine = sin(whinePhase * twoPi) * 0.35 + sin(whine2Phase * twoPi) * 0.12
            let chop = white() * (0.5 + 0.5 * sin(bladePhase * twoPi)) * 0.35
            var motor = (buzz * 0.5 + whine + chop) * (0.08 + 0.92 * thr) * motorGain
            // Idle ticking when the motor is armed and barely turning.
            motor *= thr > 0.02 ? 1 : 0.15
            // Air absorption: the further, the duller (two one-pole low passes), and the inverse distance law.
            let cutoff = 9000 / (1 + dist / 25)
            let c = coef(cutoff)
            motorLP += (motor - motorLP) * c
            motorLP2 += (motorLP - motorLP2) * c
            let atten = 1.6 / max(dist, 1.2)
            let m = motorLP2 * atten * 1.4

            // --- Airflow over the model: band-limited noise rising with the airspeed squared.
            let wn = white()
            airLP += (wn - airLP) * coef(1800 + air * 120)
            airHP += (airLP - airHP) * coef(300)
            let flow = (airLP - airHP) * min(air * air / 120, 1.5) * atan2f(1, dist / 4) * 0.6

            // --- Wind in the grass and trees: brown-ish noise, slow gusts, decorrelated left/right.
            gustTimer -= dt
            if gustTimer <= 0 { gustTarget = 0.25 + 0.75 * abs(white()); gustTimer = 1.5 + 4 * abs(white()) }
            gust += (gustTarget - gust) * dt * 0.6
            let wc = coef(350 + gust * 500)
            windL += (white() - windL) * wc; windR += (white() - windR) * wc
            windL2 += (windL - windL2) * wc; windR2 += (windR - windR2) * wc
            let wg = 0.75 * gust
            var outL = windL2 * wg, outR = windR2 * wg

            // --- Birds.
            nextBird -= dt
            if nextBird <= 0, birds.count < 3 {
                var b = Bird()
                b.chirps = 2 + Int(abs(white()) * 7)
                b.chirpLen = 0.04 + abs(white()) * 0.12
                b.gap = 0.03 + abs(white()) * 0.12
                b.f0 = 2400 + abs(white()) * 2600
                b.f1 = b.f0 * (0.7 + abs(white()) * 0.8)
                b.trill = abs(white()) > 0.6 ? 25 + abs(white()) * 30 : 0
                b.az = white() * .pi
                b.gain = 0.03 + abs(white()) * 0.05
                birds.append(b)
                nextBird = 1.5 + abs(white()) * 5
            }
            var k = 0
            while k < birds.count {
                var b = birds[k]
                b.t += dt
                let cycle = b.chirpLen + b.gap
                let inChirp = b.t.truncatingRemainder(dividingBy: cycle)
                b.chirp = Int(b.t / cycle)
                if b.chirp >= b.chirps { birds.remove(at: k); continue }
                if inChirp < b.chirpLen {
                    let x = inChirp / b.chirpLen
                    var f = b.f0 + (b.f1 - b.f0) * x
                    if b.trill > 0 { f *= 1 + 0.08 * sin(b.t * b.trill * twoPi) }
                    b.phase += f * dt; if b.phase >= 1 { b.phase -= 1 }
                    let env = sin(x * .pi)
                    let v = sin(b.phase * twoPi) * env * env * b.gain
                    // World-fixed direction relative to where the pilot looks.
                    let rel = sin(b.az - az)
                    outL += v * (0.5 - 0.45 * rel) * 2; outR += v * (0.5 + 0.45 * rel) * 2
                }
                birds[k] = b
                k += 1
            }

            // --- Crickets: 4.6 kHz pulses in short chirps, quiet.
            cricketChirp += dt; if cricketChirp > 0.9 { cricketChirp = 0 }
            if cricketChirp < 0.18 {
                cricketPulse += dt * 32; if cricketPulse >= 1 { cricketPulse -= 1 }
                cricketPhase += 4600 * dt; if cricketPhase >= 1 { cricketPhase -= 1 }
                let pe = cricketPulse < 0.5 ? sin(cricketPulse * 2 * .pi) : 0
                let v = sin(cricketPhase * twoPi) * pe * 0.008
                outL += v * 1.2; outR += v * 0.6
            }

            // --- One-shots.
            var shotL: Float = 0
            var j = 0
            while j < shots.count {
                var s = shots[j]
                s.t += dt
                var v: Float = 0
                switch s.kind {
                case .launch:
                    // A throwing whoosh: noise through a falling low pass.
                    if s.t > 0.5 { shots.remove(at: j); continue }
                    s.lp += (white() - s.lp) * coef(3000 * (1 - s.t * 1.6) + 200)
                    v = s.lp * sin(min(s.t / 0.5, 1) * .pi) * 0.6
                case .land:
                    // Thump and a short scrape on the grass.
                    if s.t > 0.45 { shots.remove(at: j); continue }
                    s.phase += (90 - 60 * s.t) * dt
                    s.lp += (white() - s.lp) * coef(1200)
                    v = sin(s.phase * twoPi) * exp(-s.t * 18) * 0.5 + s.lp * exp(-s.t * 7) * 0.25
                    v *= min(1.6 / max(dist, 1.2), 1) * 2
                case .crash:
                    // Crunching foam: a bang and crackle grains.
                    if s.t > 0.8 { shots.remove(at: j); continue }
                    s.phase += 60 * dt
                    let crackle: Float = abs(white()) > 0.985 - 0.02 * exp(-s.t * 4) ? white() * 0.9 : 0
                    s.lp += (white() - s.lp) * coef(2500)
                    v = (sin(s.phase * twoPi) * exp(-s.t * 14) * 0.6 + s.lp * exp(-s.t * 5) * 0.5 + crackle * exp(-s.t * 3))
                    v *= min(1.6 / max(dist, 1.2), 1) * 2.5
                }
                shots[j] = s
                shotL += v
                j += 1
            }

            let mono = m + flow + shotL
            outL += mono; outR += mono
            // Soft clip and master volume.
            L[i] = tanh(outL * 1.2) * vol * 0.8
            R[i] = tanh(outR * 1.2) * vol * 0.8
        }
    }
}

extension SimAudio {
    /// Offline render for the self-test: hand → launch → fly-by at 70 % throttle → crash. Writes a WAV and returns
    /// the peak and RMS level (a NaN or a clipped mix shows up here).
    static func renderTest(to url: URL?) -> (peak: Float, rms: Float) {
        let rate: Float = 44100
        let synth = Synth(rate: rate)
        var l = [Float](repeating: 0, count: 512), r = l
        var all: [Float] = []
        var p = Params()
        p.volume = 0.8; p.motorOn = true
        var t: Float = 0
        var launched = false, crashed = false
        while t < 8 {
            p.throttle = t < 1 ? 0 : 0.7
            if t > 1.5, !launched { synth.trigger(.launch); launched = true }
            // Fly-by: from 60 m out, past the pilot at 5 m, away again at 12 m/s.
            let x = (t - 4.5) * 12
            p.distance = max((x * x + 25).squareRoot(), 1)
            p.radialSpeed = t < 1.5 ? 0 : 12 * x / p.distance
            p.airspeed = t < 1.5 ? 0 : 12
            if t > 7.2, !crashed { synth.trigger(.crash); crashed = true; p.motorOn = false }
            l.withUnsafeMutableBufferPointer { lb in r.withUnsafeMutableBufferPointer { rb in synth.render(p, lb.baseAddress!, rb.baseAddress!, 512) } }
            for i in 0..<512 { all.append(l[i]); all.append(r[i]) }
            t += 512 / rate
        }
        let peak = all.map { abs($0) }.max() ?? 0
        let rms = (all.reduce(0) { $0 + $1 * $1 } / Float(max(all.count, 1))).squareRoot()
        if let url {
            var d = Data()
            func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
            func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
            let bytes = UInt32(all.count * 2)
            d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); d.append(contentsOf: Array("WAVEfmt ".utf8))
            u32(16); u16(1); u16(2); u32(44100); u32(44100 * 4); u16(4); u16(16)
            d.append(contentsOf: Array("data".utf8)); u32(bytes)
            for v in all { u16(UInt16(bitPattern: Int16(max(min(v, 1), -1) * 32767))) }
            try? d.write(to: url)
        }
        return (peak, rms)
    }
}
