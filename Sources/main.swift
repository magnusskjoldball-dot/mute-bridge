import AppKit
import AVFoundation
import AudioToolbox
import CoreAudio
import OSLog
import UserNotifications
import Accelerate

private let logger = Logger(subsystem: "local.codex.granolamutebridge.audio", category: "routing")

enum RoutingError: LocalizedError {
    case missingVirtual, missingBuiltIn, device(OSStatus)
    var errorDescription: String? {
        switch self {
        case .missingVirtual: return "BlackHole 2ch ble ikke funnet."
        case .missingBuiltIn: return "Fant ingen mikrofon."
        case .device(let status): return "Kunne ikke velge lydenheten (\(status))."
        }
    }
}

func audioProperty<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, into value: inout T) -> Bool {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<T>.size)
    return withUnsafeMutablePointer(to: &value) {
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0) == noErr
    }
}

func audioDevices() -> [AudioDeviceID] {
    let system = AudioObjectID(kAudioObjectSystemObject)
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
    var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    let status = devices.withUnsafeMutableBytes {
        AudioObjectGetPropertyData(system, &address, 0, nil, &size, $0.baseAddress!)
    }
    return status == noErr ? devices : []
}

func blackHole() -> AudioDeviceID? {
    audioDevices().first { device in
        var uid: Unmanaged<CFString>?
        guard audioProperty(device, kAudioDevicePropertyDeviceUID, into: &uid) else { return false }
        return (uid?.takeRetainedValue() as String?) == "BlackHole2ch_UID"
    }
}

func builtInMicrophone() -> AudioDeviceID? {
    audioDevices().first { device in
        var transport: UInt32 = 0
        guard audioProperty(device, kAudioDevicePropertyTransportType, into: &transport),
              transport == kAudioDeviceTransportTypeBuiltIn else { return false }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: kAudioDevicePropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }
}

struct InputDevice { let id: AudioDeviceID; let uid: String; let name: String }

func deviceString(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String {
    var s: Unmanaged<CFString>?
    return audioProperty(device, selector, into: &s) ? (s?.takeRetainedValue() as String? ?? "") : ""
}

func hasInput(_ device: AudioDeviceID) -> Bool {
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
}

/// Alle ekte mikrofoner (uten BlackHole og skjulte systemenheter).
func inputDevices() -> [InputDevice] {
    audioDevices().compactMap { d in
        guard hasInput(d) else { return nil }
        let uid = deviceString(d, kAudioDevicePropertyDeviceUID)
        guard !uid.hasPrefix("BlackHole"), !uid.contains("CADefaultDeviceAggregate") else { return nil }
        return InputDevice(id: d, uid: uid, name: deviceString(d, kAudioObjectPropertyName))
    }
}

func systemDefaultInput() -> AudioDeviceID? {
    var id = AudioDeviceID(0)
    return audioProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, into: &id) && id != 0 ? id : nil
}

/// Valgt mikrofon: det brukeren har valgt i menyen, ellers systemets standard (aldri BlackHole), ellers den innebygde.
func chosenInput() -> InputDevice? {
    let devices = inputDevices()
    let saved = UserDefaults.standard.string(forKey: "micUID") ?? "auto"
    if saved != "auto", let d = devices.first(where: { $0.uid == saved }) { return d }
    if let def = systemDefaultInput(), let d = devices.first(where: { $0.id == def }) { return d }
    if let b = builtInMicrophone(), let d = devices.first(where: { $0.id == b }) { return d }
    return devices.first
}

/// BlackHole må gå i samme samplingsrate som mikrofonen.
func matchRate(_ virtual: AudioDeviceID, to input: AudioDeviceID) {
    var want = Float64(0), have = Float64(0)
    guard audioProperty(input, kAudioDevicePropertyNominalSampleRate, into: &want),
          audioProperty(virtual, kAudioDevicePropertyNominalSampleRate, into: &have), want > 0, want != have else { return }
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    if AudioObjectSetPropertyData(virtual, &address, 0, nil, UInt32(MemoryLayout<Float64>.size), &want) == noErr { usleep(250_000) }
}

final class Routing {
    private var route: OpaquePointer?

    func start() throws {
        guard let virtual = blackHole() else { throw RoutingError.missingVirtual }
        guard let input = chosenInput()?.id else { throw RoutingError.missingBuiltIn }
        matchRate(virtual, to: input)
        var status: OSStatus = 0
        guard let route = routeStart(input, virtual, &status) else { throw RoutingError.device(status) }
        self.route = route
        logger.notice("Lydrute aktiv: mikrofon til BlackHole")
    }

    func mute(_ muted: Bool) { if let route { routeMute(route, muted) } }
    func level() -> Float { route.map { routeLevel($0) } ?? 0 }
    func recent(_ n: Int) -> [Float] {
        guard let route else { return [Float](repeating: 0, count: n) }
        var out = [Float](repeating: 0, count: n)
        routeRecent(route, &out, UInt32(n))
        return out
    }
    var rate: Double { route.map { routeRate($0) } ?? 48000 }
    deinit { if let route { routeDestroy(route) } }
}

func waveColors(_ state: String) -> (NSColor, NSColor) {
    switch state {
    case "STILLE": return (NSColor(srgbRed: 0.93, green: 0.27, blue: 0.36, alpha: 1), NSColor(srgbRed: 1, green: 0.58, blue: 0.68, alpha: 1))
    case "LÅST": return (NSColor(srgbRed: 1, green: 0.58, blue: 0.18, alpha: 1), NSColor(srgbRed: 1, green: 0.85, blue: 0.38, alpha: 1))
    case "AV": return (NSColor(white: 0.62, alpha: 1), NSColor(white: 0.78, alpha: 1))
    default: return (NSColor(srgbRed: 0.62, green: 0.42, blue: 0.92, alpha: 1), NSColor(srgbRed: 0.35, green: 0.74, blue: 0.96, alpha: 1))
    }
}

func drawWave(_ values: [CGFloat], in rect: NSRect, state: String, alpha: CGFloat, phase: Double, cycles: Double, width: CGFloat, glow: Bool, steps: Int = 120) {
    guard let ctx = NSGraphicsContext.current?.cgContext, values.count > 2 else { return }
    let (base, accent) = waveColors(state)
    let muted = state == "STILLE" || state == "LÅST"
    let n = values.count
    func env(_ t: Double) -> CGFloat {
        let p = abs(2 * t - 1) * Double(n - 1), i = min(n - 2, Int(p)), f = CGFloat(p - Double(i))
        let v = values[i] * (1 - f) + values[i + 1] * f
        let idle = 0.03 + 0.02 * CGFloat(sin(phase * 2 + t * 6))
        let level = muted ? v * 0.4 : max(v, idle)
        return level * CGFloat(pow(sin(Double.pi * min(1, max(0, t))), 0.5))
    }
    let mid = rect.midY, amp = rect.height / 2 - width
    let path = CGMutablePath()
    var colors = [CGColor](), locs = [CGFloat]()
    let b = base.usingColorSpace(.sRGB)!, c = accent.usingColorSpace(.sRGB)!
    for s in 0...steps {
        let t = Double(s) / Double(steps), e = env(t)
        let y = mid + CGFloat(sin(t * cycles * 2 * Double.pi - phase * 5)) * e * amp
        let p = CGPoint(x: rect.minX + rect.width * CGFloat(t), y: y)
        if s == 0 { path.move(to: p) } else { path.addLine(to: p) }
        let k = min(1, e * 2.2)
        colors.append(CGColor(srgbRed: b.redComponent + (c.redComponent - b.redComponent) * k,
                              green: b.greenComponent + (c.greenComponent - b.greenComponent) * k,
                              blue: b.blueComponent + (c.blueComponent - b.blueComponent) * k, alpha: 1))
        locs.append(CGFloat(t))
    }
    guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locs) else { return }
    let layers: [(CGFloat, CGFloat)] = glow ? [(width * 5, 0.10), (width * 2.6, 0.22), (width, 1)] : [(width, 1)]
    for (w, a) in layers {
        ctx.saveGState()
        ctx.addPath(path.copy(strokingWithWidth: w, lineCap: .round, lineJoin: .round, miterLimit: 2))
        ctx.clip()
        ctx.setAlpha(a * alpha)
        ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: 0), end: CGPoint(x: rect.maxX, y: 0), options: [])
        ctx.restoreGState()
    }
}

func iconColors(_ state: String) -> (NSColor, NSColor) {
    switch state {
    case "STILLE": return (NSColor(srgbRed: 0.93, green: 0.27, blue: 0.36, alpha: 1), NSColor(srgbRed: 1, green: 0.58, blue: 0.68, alpha: 1))
    case "LÅST": return (NSColor(srgbRed: 1, green: 0.58, blue: 0.18, alpha: 1), NSColor(srgbRed: 1, green: 0.85, blue: 0.38, alpha: 1))
    case "PASS": return (NSColor(white: 0.55, alpha: 1), NSColor(white: 0.72, alpha: 1))
    default: return (NSColor(srgbRed: 0.62, green: 0.42, blue: 0.92, alpha: 1), NSColor(srgbRed: 0.35, green: 0.74, blue: 0.96, alpha: 1))
    }
}

/// Fem små kapsler. Tegnes bare én gang per kombinasjon og caches av kalleren.
func meterImage(state: String, level: Int, variant: Int, dim: Bool) -> NSImage {
    if state == "AV" {
        // Dempingen er av: tom ring som følger menylinjens farge
        let ring = NSImage(size: NSSize(width: 14, height: 18), flipped: false) { _ in
            NSColor.black.withAlphaComponent(0.6).setStroke()
            let p = NSBezierPath(ovalIn: NSRect(x: 3.5, y: 5.5, width: 7, height: 7)); p.lineWidth = 1.3; p.stroke()
            return true
        }
        ring.isTemplate = true
        return ring
    }
    if state == "VENT" {
        // Dempingen er på og venter: liten fargeprikk
        return NSImage(size: NSSize(width: 14, height: 18), flipped: false) { _ in
            NSColor(srgbRed: 0.5, green: 0.52, blue: 0.95, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 3.5, y: 5.5, width: 7, height: 7)).fill()
            return true
        }
    }
    let shapes: [[CGFloat]] = [[0.55, 0.85, 1.0, 0.7, 0.45], [0.7, 1.0, 0.6, 0.9, 0.5], [0.45, 0.7, 0.95, 1.0, 0.65]]
    let (c0, c1) = iconColors(state)
    let a = c0.usingColorSpace(.sRGB)!, b = c1.usingColorSpace(.sRGB)!
    let muted = state == "STILLE" || state == "LÅST"
    let l = CGFloat(level) / 8
    let image = NSImage(size: NSSize(width: 30, height: 18), flipped: false) { _ in
        let w: CGFloat = 3.6, gap: CGFloat = 2.4
        for i in 0..<5 {
            let k = CGFloat(i) / 4
            let h = 3 + (muted ? 0.3 : 1) * l * shapes[variant % 3][i] * 12
            let color = NSColor(srgbRed: a.redComponent + (b.redComponent - a.redComponent) * k,
                                green: a.greenComponent + (b.greenComponent - a.greenComponent) * k,
                                blue: a.blueComponent + (b.blueComponent - a.blueComponent) * k, alpha: dim ? 0.5 : 1)
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: 1.5 + CGFloat(i) * (w + gap), y: (18 - h) / 2, width: w, height: h), xRadius: w / 2, yRadius: w / 2).fill()
        }
        return true
    }
    image.isTemplate = false
    return image
}

final class HeaderView: NSView {
    var title = "…", sub = "", stats = "", color = NSColor.systemGray
    var bars: [CGFloat] = []
    var pulse = false
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width
        let a: CGFloat = pulse ? 0.7 + 0.3 * sin(Date().timeIntervalSinceReferenceDate * 6) : 1
        // statuslinje
        color.withAlphaComponent(a).setFill()
        NSBezierPath(ovalIn: NSRect(x: 16, y: 20, width: 12, height: 12)).fill()
        color.withAlphaComponent(0.25 * a).setFill()
        NSBezierPath(ovalIn: NSRect(x: 12, y: 16, width: 20, height: 20)).fill()
        (title as NSString).draw(at: NSPoint(x: 40, y: 10), withAttributes: [
            .font: NSFont.systemFont(ofSize: 22, weight: .heavy), .foregroundColor: NSColor.labelColor, .kern: 1.5])
        (sub as NSString).draw(in: NSRect(x: 16, y: 44, width: w - 32, height: 16), withAttributes: [
            .font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: NSColor.secondaryLabelColor])
        // stemmebølge
        let box = NSRect(x: 16, y: 68, width: w - 32, height: 62)
        NSColor.labelColor.withAlphaComponent(0.05).setFill()
        NSBezierPath(roundedRect: box, xRadius: 12, yRadius: 12).fill()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: box, xRadius: 12, yRadius: 12).addClip()
        drawWave(bars, in: box.insetBy(dx: 14, dy: 8), state: title, alpha: a, phase: Date().timeIntervalSinceReferenceDate, cycles: 7, width: 3, glow: true)
        NSGraphicsContext.restoreGraphicsState()
        (stats as NSString).draw(in: NSRect(x: 16, y: 140, width: w - 32, height: 16), withAttributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.tertiaryLabelColor])
    }
}

final class Spectrum {
    let n = 2048, log2n: vDSP_Length = 11, count = 32
    private let setup: FFTSetup
    private var window = [Float](repeating: 0, count: 2048)
    private(set) var bands = [CGFloat](repeating: 0, count: 32)

    init() {
        setup = vDSP_create_fftsetup(11, FFTRadix(kFFTRadix2))!
        vDSP_hann_window(&window, 2048, Int32(vDSP_HANN_NORM))
    }
    deinit { vDSP_destroy_fftsetup(setup) }

    func update(_ samples: [Float], rate: Double) {
        var x = [Float](repeating: 0, count: n)
        vDSP_vmul(samples, 1, window, 1, &x, 1, vDSP_Length(n))
        var real = [Float](repeating: 0, count: n / 2), imag = [Float](repeating: 0, count: n / 2)
        var mags = [Float](repeating: 0, count: n / 2)
        real.withUnsafeMutableBufferPointer { r in imag.withUnsafeMutableBufferPointer { i in
            var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
            x.withUnsafeBufferPointer { p in
                p.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2)) }
            }
            vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
            vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(n / 2))
        } }
        let lo = 70.0, hi = min(7000.0, rate / 2 - 1)
        for b in 0..<count {
            let f0 = lo * pow(hi / lo, Double(b) / Double(count)), f1 = lo * pow(hi / lo, Double(b + 1) / Double(count))
            let i0 = max(1, Int(f0 * Double(n) / rate)), i1 = max(i0, min(n / 2 - 2, Int(f1 * Double(n) / rate)))
            var peak: Float = 0
            for i in i0...i1 { peak = max(peak, sqrt(mags[i])) }
            let pos = (f0 + f1) / 2 * Double(n) / rate, k = min(n / 2 - 2, max(1, Int(pos))), fr = Float(pos - Double(k))
            peak = max(peak, sqrt(mags[k]) * (1 - fr) + sqrt(mags[k + 1]) * fr)
            let amp = peak / Float(n)                              // ca. sinusamplitude (0,76 × A)
            let db = amp > 1e-7 ? 20 * log10(amp) : -140
            let tilt = Float(b) * 0.5                              // løft diskanten litt
            let target = CGFloat(max(0, min(1, (db + tilt + 66) / 38)))
            bands[b] = target > bands[b] ? bands[b] * 0.35 + target * 0.65 : bands[b] * 0.82 + target * 0.18
        }
    }
    func reset() { bands = [CGFloat](repeating: 0, count: count) }
}

final class BlueSwitch: NSControl {
    var isOn = false { didSet { needsDisplay = true } }
    override var isFlipped: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        let track = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        (isOn ? NSColor(srgbRed: 0.22, green: 0.51, blue: 0.97, alpha: 1) : NSColor(white: 0.5, alpha: 0.45)).setFill()
        track.fill()
        let d = r.height - 4
        let x = isOn ? r.maxX - d - 2 : r.minX + 2
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: x, y: r.minY + 2, width: d, height: d)).fill()
    }
    override func mouseDown(with event: NSEvent) {
        isOn.toggle()
        if let a = action { NSApp.sendAction(a, to: target, from: self) }
    }
}

final class SwitchView: NSView {
    let toggle = BlueSwitch()
    init(title: String, subtitle: String, on: Bool, target: AnyObject, action: Selector) {
        super.init(frame: NSRect(x: 0, y: 0, width: 340, height: 52))
        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 13, weight: .semibold)
        t.frame = NSRect(x: 16, y: 29, width: 255, height: 17)
        let sub = NSTextField(labelWithString: subtitle)
        sub.font = .systemFont(ofSize: 11)
        sub.textColor = .secondaryLabelColor
        sub.lineBreakMode = .byTruncatingTail
        sub.frame = NSRect(x: 16, y: 9, width: 255, height: 15)
        toggle.isOn = on
        toggle.target = target
        toggle.action = action
        toggle.frame = NSRect(x: 280, y: 14, width: 46, height: 26)
        addSubview(t); addSubview(sub); addSubview(toggle)
    }
    required init?(coder: NSCoder) { fatalError() }
}

final class Bridge: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var menuOpen = false
    private var frame = 0
    func menuWillOpen(_ menu: NSMenu) { menuOpen = true }
    func menuDidClose(_ menu: NSMenu) { menuOpen = false }
    private var status: NSStatusItem!
    private var routing: Routing?
    private var eventTap: CFMachPort?
    private var source: CFRunLoopSource?
    private var releaseTimer: DispatchWorkItem?
    private var fnDown = false
    private var latched = false
    private var pressedAt = Date.distantPast
    private var lastQuickTap: Date?
    private var justUnlatched = false
    private var latchTimeout: DispatchWorkItem?
    private var bars = [CGFloat](repeating: 0, count: 32)
    private let spectrum = Spectrum()
    private var smooth: CGFloat = 0
    private var meterTimer: Timer?
    private var iconCache: [String: NSImage] = [:]
    private var lastIconKey = ""
    private var level = 0.0
    private var frameCount = 0
    private var headerView: HeaderView?
    private var muteBegan: Date?
    private var updateAvailable: (version: String, url: String)?
    private var updateAsset: String?
    private var updating = false
    private var autoUpdate: Bool { UserDefaults.standard.object(forKey: "autoUpdate") as? Bool ?? true }
    private let updateRepo = "magnusskjoldball-dot/mute-bridge"
    private let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    private var today: (count: Int, seconds: Double) {
        get {
            let d = UserDefaults.standard, key = Self.dayKey()
            guard d.string(forKey: "day") == key else { return (0, 0) }
            return (d.integer(forKey: "count"), d.double(forKey: "seconds"))
        }
        set {
            let d = UserDefaults.standard
            d.set(Self.dayKey(), forKey: "day"); d.set(newValue.count, forKey: "count"); d.set(newValue.seconds, forKey: "seconds")
        }
    }
    private static func dayKey() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date())
    }
    private let tapMax = 0.30, doubleTapWindow = 0.40, releaseDelay = 0.11, latchLimit = 180.0
    private var message = "Starter …"
    private var mode: String { UserDefaults.standard.string(forKey: "mode") == "always" ? "always" : "auto" }   // auto | always
    private var muting: Bool { UserDefaults.standard.object(forKey: "muting") as? Bool ?? true }   // demp mikrofonen mens du dikterer
    private var unmutedDictations = 0
    private var lastCounted = Date.distantPast
    private var nagShown = false
    private var idleSince: Date?
    private var evalTimer: Timer?
    private var watchedBlackHole: AudioDeviceID?
    private static let smartAvailable: Bool = { if #available(macOS 14.2, *) { return true } else { return false } }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateMenu()
        start()
        let ev = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.evaluate(); self?.installUpdateIfIdle() }
        ev.tolerance = 1
        RunLoop.main.add(ev, forMode: .common)
        evalTimer = ev
        let defaults = UserDefaults.standard
        if defaults.string(forKey: "mode") == "off" { defaults.set("auto", forKey: "mode"); defaults.set(false, forKey: "muting") }
        if let last = defaults.string(forKey: "lastVersion"), last != version {
            notify(title: "Mute Bridge er oppdatert", body: "Du har nå versjon \(version).")
        }
        defaults.set(version, forKey: "lastVersion")
        watchDevices()
        checkForUpdates()
        let upd = Timer(timeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.checkForUpdates() }
        RunLoop.main.add(upd, forMode: .common)
    }

    private func startMeter() {
        guard meterTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 12, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 0.04
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    private func stopMeter() {
        meterTimer?.invalidate()
        meterTimer = nil
        level = 0
    }

    private func beginRoute() {
        guard routing == nil, eventTap != nil else { return }
        do {
            let route = Routing()
            try route.start()
            routing = route
            fnDown = CGEventSource.flagsState(.hidSystemState).contains(.maskSecondaryFn)
            route.mute(muting && (fnDown || latched))
            message = "Sender mikrofonen til BlackHole 2ch"
            idleSince = nil
            startMeter()
        } catch {
            routing = nil
            message = error.localizedDescription
        }
        updateMenu()
    }

    private func endRoute() {
        routing?.mute(true)
        routing = nil
        stopMeter()
        endMute()
        message = "Venter på Discord-samtale"
        unmutedDictations = 0; nagShown = false
        updateMenu()
    }

    private func applyMode() {
        switch mode {
        case "always":
            beginRoute()
        default:
            if !Bridge.smartAvailable || othersReadBlackHole() { beginRoute() } else if routing == nil { message = "Venter på Discord-samtale" }
        }
    }

    private func othersReadBlackHole() -> Bool {
        if #available(macOS 14.2, *) { return Bridge.someoneReadsBlackHole() }
        return true
    }

    /// Kjører hvert 3. sekund og når noen begynner å lese BlackHole: slår ruten på i en Discord-samtale og av når den er over.
    private func evaluate() {
        guard eventTap != nil else { return }
        if #available(macOS 14.2, *), Bridge.discordUsesWrongMic() {
            showTip(title: "Du er i en Discord-samtale",
                    body: "Velg «BlackHole 2ch» som mikrofon i Discord (Innstillinger, Voice & Video), så kan Mute Bridge dempe deg mens du dikterer.")
        }
        guard mode == "auto", Bridge.smartAvailable else { return }
        if othersReadBlackHole() {
            idleSince = nil
            if routing == nil { beginRoute() }
        } else if routing != nil {
            if let t = idleSince {
                if Date().timeIntervalSince(t) > 10 { idleSince = nil; endRoute() }
            } else {
                idleSince = Date()
            }
        }
    }

    private func watchBlackHole() {
        guard let bh = blackHole(), bh != watchedBlackHole else { return }
        watchedBlackHole = bh
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(bh, &address, DispatchQueue.main) { [weak self] _, _ in self?.evaluate() }
    }

    private func tick() {
        frameCount += 1
        let raw = Double(routing?.level() ?? 0)
        let db = raw > 0.00001 ? 20 * log10(raw) : -100
        let target = max(0, min(1, (db + 50) / 40))
        level = target > level ? target : level * 0.72 + target * 0.28
        updateIcon()
    }

    private func refreshHeader() {
        guard let hv = headerView else { return }
        let on = routing != nil
        let t = today
        let live = muteBegan.map { Date().timeIntervalSince($0) } ?? 0
        let secs = t.seconds + (fnDown || latched ? live : 0)
        let speaking = (bars.max() ?? 0) > 0.3
        if !on { hv.title = "AV"; hv.color = .systemGray; hv.sub = message }
        else if latched { hv.title = "LÅST"; hv.color = .systemOrange; hv.sub = "Diktering pågår · fn eller Esc åpner igjen" }
        else if fnDown { hv.title = "STILLE"; hv.color = .systemRed; hv.sub = speaking ? "Du snakker – Discord hører ingenting 🤫" : "Discord hører ingenting akkurat nå" }
        else { hv.title = "LIVE"; hv.color = .systemGreen; hv.sub = "Discord hører deg" }
        hv.color = waveColors(hv.title).0
        hv.bars = bars
        hv.pulse = latched
        hv.stats = t.count == 0 && secs < 1 ? "Ingen dikteringer i dag ennå" : "I dag: \(t.count + (fnDown || latched ? 1 : 0)) dikteringer · Discord har sluppet \(Bridge.format(secs))"
        hv.needsDisplay = true
    }

    static func format(_ s: Double) -> String {
        let n = Int(s)
        return n < 60 ? "\(n) sek" : "\(n / 60) min \(n % 60) s"
    }

    private func beginMute() { if muteBegan == nil { muteBegan = Date() } }
    private func endMute() {
        guard let began = muteBegan else { return }
        muteBegan = nil
        let d = Date().timeIntervalSince(began)
        if d >= 0.8 { var t = today; t.count += 1; t.seconds += d; today = t }
    }

    @objc private func pickMode(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.representedObject as? String ?? "auto", forKey: "mode")
        start()
    }

    @objc private func pickMic(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.representedObject as? String ?? "auto", forKey: "micUID")
        start()
    }

    private var restartWork: DispatchWorkItem?
    private func scheduleRestart() {
        restartWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.start() }
        restartWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: w)
    }

    private func watchDevices() {
        for selector in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDevices] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main) { [weak self] _, _ in
                self?.scheduleRestart()
            }
        }
    }

    @objc private func openUpdate() { if let u = updateAvailable, let url = URL(string: u.url) { NSWorkspace.shared.open(url) } }
    @objc private func checkNow() { checkForUpdates(manual: true) }

    /// Spør ikke GitHubs API (har strenge grenser), men følger lenken «siste release» og leser versjonen fra adressen den ender på.
    private func checkForUpdates(manual: Bool = false) {
        guard !updateRepo.isEmpty, let url = URL(string: "https://github.com/\(updateRepo)/releases/latest") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 20
        URLSession.shared.dataTask(with: request) { _, response, error in
            let final = (response as? HTTPURLResponse)?.url
            let tag = final?.lastPathComponent ?? ""
            logger.info("Oppdateringssjekk: \(tag, privacy: .public) \(error?.localizedDescription ?? "", privacy: .public)")
            guard let final, final.path.contains("/releases/tag/"), !tag.isEmpty else { return }
            let latest = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            let zip = "https://github.com/\(self.updateRepo)/releases/download/\(tag)/Mute-Bridge.zip"
            DispatchQueue.main.async {
                guard latest.compare(self.version, options: .numeric) == .orderedDescending else { return }
                let isNew = self.updateAvailable?.version != latest
                self.updateAvailable = (latest, final.absoluteString)
                self.updateAsset = zip
                self.updateMenu()
                if self.autoUpdate { self.installUpdateIfIdle() }
                else if isNew { self.notify(title: "Mute Bridge \(latest) er klar", body: "Klikk på ikonet i menylinjen og velg «Oppdater».") }
            }
        }.resume()
    }

    private func notify(title: String, body: String) {
        let c = UNUserNotificationCenter.current()
        c.requestAuthorization(options: [.alert]) { ok, _ in
            guard ok else { return }
            let n = UNMutableNotificationContent()
            n.title = title; n.body = body
            c.add(UNNotificationRequest(identifier: UUID().uuidString, content: n, trigger: nil))
        }
    }

    @discardableResult
    private static func run(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus } catch { return -1 }
    }

    @objc private func updateNow() {
        if updateAsset != nil { installUpdateIfIdle(force: true) } else { openUpdate() }
    }

    @objc private func toggleAutoUpdate() {
        UserDefaults.standard.set(!autoUpdate, forKey: "autoUpdate")
        updateMenu()
        if autoUpdate { installUpdateIfIdle() }
    }

    @objc private func toggleEnabled(_ sender: BlueSwitch) {
        UserDefaults.standard.set(sender.isOn, forKey: "muting")
        unmutedDictations = 0; nagShown = false
        if !muting {
            if latched { unlatch(reopen: false) }
            if !fnDown { routing?.mute(false) }
            endMute()
        } else if fnDown || latched {
            routing?.mute(true)
        }
        updateMenu()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.status.menu?.cancelTracking() }
    }

    /// Laster ned, verifiserer og bytter ut appen, men aldri midt i en samtale eller diktering.
    private func installUpdateIfIdle(force: Bool = false) {
        guard !updating, let asset = updateAsset, let u = updateAvailable, force || autoUpdate,
              let url = URL(string: asset) else { return }
        if !force, fnDown || latched || (Bridge.smartAvailable && othersReadBlackHole()) { return }
        let dest = Bundle.main.bundleURL.path
        guard FileManager.default.isWritableFile(atPath: Bundle.main.bundleURL.deletingLastPathComponent().path) else {
            updateAsset = nil
            notify(title: "Mute Bridge \(u.version) er klar", body: "Kunne ikke oppdatere automatisk. Kjør installasjonslinjen på nytt (se GitHub).")
            return
        }
        updating = true
        message = "Oppdaterer til \(u.version) …"
        updateMenu()
        URLSession.shared.downloadTask(with: url) { [weak self] tmp, _, err in
            guard let self else { return }
            var ok = false
            defer {
                if !ok { DispatchQueue.main.async { self.updating = false; self.updateAsset = nil; self.message = "Oppdatering feilet – prøver ikke igjen nå"; self.updateMenu() } }
            }
            guard let tmp, err == nil else { return }
            let fm = FileManager.default
            let work = fm.temporaryDirectory.appendingPathComponent("mutebridge-\(UUID().uuidString)")
            try? fm.createDirectory(at: work, withIntermediateDirectories: true)
            let zip = work.appendingPathComponent("update.zip")
            guard (try? fm.moveItem(at: tmp, to: zip)) != nil,
                  Bridge.run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path]) == 0,
                  let appURL = (try? fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil))?.first(where: { $0.pathExtension == "app" }),
                  let bundle = Bundle(url: appURL), bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
                  let v = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                  v.compare(self.version, options: .numeric) == .orderedDescending,
                  Bridge.run("/usr/bin/codesign", ["-v", "--strict", appURL.path]) == 0 else { return }
            ok = true
            let script = "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.3; done; /usr/bin/ditto '\(appURL.path)' '\(dest).new' && rm -rf '\(dest)' && mv '\(dest).new' '\(dest)'; /usr/bin/xattr -dr com.apple.quarantine '\(dest)'; /usr/bin/open '\(dest)'"
            DispatchQueue.main.async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/sh")
                p.arguments = ["-c", "nohup /bin/sh -c \"$0\" >/dev/null 2>&1 &", script]
                try? p.run()
                self.quit()
            }
        }.resume()
    }

    private func updateIcon() {
        let state = !muting ? (routing == nil ? "AV" : "PASS") : routing == nil ? "VENT" : latched ? "LÅST" : fnDown ? "STILLE" : "LIVE"
        let lv = (state == "AV" || state == "VENT") ? 0 : Int((level * 8).rounded())
        let variant = lv == 0 ? 0 : 1 + frameCount / 2 % 2
        let dim = state == "LÅST" && Int(Date().timeIntervalSinceReferenceDate * 2) % 2 == 0
        let key = "\(state)-\(lv)-\(variant)-\(dim)"
        guard key != lastIconKey else { return }
        lastIconKey = key
        if iconCache[key] == nil { iconCache[key] = meterImage(state: state, level: lv, variant: variant, dim: dim) }
        status.button?.image = iconCache[key]
        status.button?.imagePosition = .imageOnly
    }

    private func updateMenu() {
        logger.info("\(self.message, privacy: .public)")
        status.button?.title = ""
        updateIcon()
        status.button?.toolTip = message
        let menu = NSMenu()
        let switchItem = NSMenuItem()
        switchItem.view = SwitchView(title: "Demp meg når jeg dikterer", subtitle: muting ? (routing == nil ? "På · venter på Discord-samtale" : "På · Discord hører ikke dikteringen") : "Av · Discord hører deg også når du dikterer", on: muting, target: self, action: #selector(toggleEnabled(_:)))
        menu.addItem(switchItem)
        menu.addItem(.separator())
        let modeMenu = NSMenu()
        let modes = [("auto", "Automatisk – bare i Discord-samtale"), ("always", "Alltid")]
        for (id, title) in modes {
            let item = NSMenuItem(title: title, action: #selector(pickMode(_:)), keyEquivalent: "")
            item.representedObject = id; item.target = self; item.state = mode == id ? .on : .off
            modeMenu.addItem(item)
        }
        let modeItem = NSMenuItem(title: "Drift: \(modes.first { $0.0 == mode }?.1.components(separatedBy: " –").first ?? "")", action: nil, keyEquivalent: "")
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)
        let micMenu = NSMenu()
        let saved = UserDefaults.standard.string(forKey: "micUID") ?? "auto"
        let current = chosenInput()
        let auto = NSMenuItem(title: "Automatisk (systemets mikrofon)", action: #selector(pickMic(_:)), keyEquivalent: "")
        auto.representedObject = "auto"; auto.target = self; auto.state = saved == "auto" ? .on : .off
        micMenu.addItem(auto)
        micMenu.addItem(.separator())
        for d in inputDevices() {
            let item = NSMenuItem(title: d.name, action: #selector(pickMic(_:)), keyEquivalent: "")
            item.representedObject = d.uid; item.target = self; item.state = saved == d.uid ? .on : .off
            micMenu.addItem(item)
        }
        let micItem = NSMenuItem(title: "Mikrofon: \(current?.name ?? "ingen")", action: nil, keyEquivalent: "")
        micItem.submenu = micMenu
        menu.addItem(micItem)
        menu.addItem(.separator())
        var items: [(String, Selector)] = []
        if updating { items.append(("⬆︎  Oppdaterer …", #selector(checkNow))) }
        else if let u = updateAvailable { items.append(("⬆︎  Oppdater til \(u.version) nå", #selector(updateNow))) }
        if latched { items.append(("🔓  Lås opp mikrofon", #selector(unlatchFromMenu))) }
        items.append(("↻  Start på nytt", #selector(start)))
        if !updateRepo.isEmpty { items.append(("Sjekk etter oppdateringer", #selector(checkNow))) }
        items.append(("Avslutt", #selector(quit)))
        for (title, action) in items {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
        }
        let au = menu.addItem(withTitle: "Oppdater automatisk", action: #selector(toggleAutoUpdate), keyEquivalent: "")
        au.target = self; au.state = autoUpdate ? .on : .off
        let ver = menu.addItem(withTitle: "Mute Bridge v\(version)", action: nil, keyEquivalent: "")
        ver.isEnabled = false
        status.menu = menu
    }

    private func stop() {
        releaseTimer?.cancel()
        releaseTimer = nil
        latchTimeout?.cancel()
        latchTimeout = nil
        latched = false
        lastQuickTap = nil
        endMute()
        idleSince = nil
        stopMeter()
        routing?.mute(true)
        if let eventTap { CFMachPortInvalidate(eventTap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        eventTap = nil
        source = nil
        routing = nil
    }

    @objc private func start() {
        stop()
        guard blackHole() != nil else { message = "BlackHole 2ch mangler"; updateMenu(); return }
        guard CGPreflightListenEventAccess() else {
            _ = CGRequestListenEventAccess()
            message = "Aktiver Input Monitoring og start Bridge på nytt."
            updateMenu()
            return
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async { self.start() } }
            return
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            message = "Aktiver Mikrofon for Bridge i Systeminnstillinger."
            updateMenu()
            return
        }
        let callback: CGEventTapCallBack = { _, type, event, context in
            let bridge = Unmanaged<Bridge>.fromOpaque(context!).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                bridge.routing?.mute(true)
                DispatchQueue.main.async {
                    bridge.stop()
                    bridge.message = "Fn-overvåking stoppet. Start Bridge på nytt."
                    bridge.updateMenu()
                }
            } else if type == .flagsChanged {
                bridge.setFn(event.flags.contains(.maskSecondaryFn))
            } else if type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == 53 {
                DispatchQueue.main.async { bridge.unlatch() }
            }
            return Unmanaged.passUnretained(event)
        }
        let mask = (CGEventMask(1) << CGEventType.flagsChanged.rawValue) | (CGEventMask(1) << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .listenOnly,
                                         eventsOfInterest: mask, callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            message = "Kunne ikke overvåke Fn."
            updateMenu()
            return
        }
        eventTap = tap
        source = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        watchBlackHole()
        fnDown = CGEventSource.flagsState(.hidSystemState).contains(.maskSecondaryFn)
        applyMode()
        updateMenu()
    }

    private var lastTip = Date.distantPast

    private func showTip(title: String, body: String) {
        guard Date().timeIntervalSince(lastTip) > 1800 else { return }
        lastTip = Date()
        let c = UNUserNotificationCenter.current()
        c.requestAuthorization(options: [.alert]) { ok, _ in
            guard ok else { return }
            let n = UNMutableNotificationContent()
            n.title = title
            n.body = body
            c.add(UNNotificationRequest(identifier: "discord-mic", content: n, trigger: nil))
        }
    }

    /// Når du begynner å diktere: er Discord i en samtale uten BlackHole 2ch?
    private func checkDiscordMic() {
        guard Date().timeIntervalSince(lastTip) > 1800 else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard #available(macOS 14.2, *), Bridge.discordUsesWrongMic() else { return }
            DispatchQueue.main.async {
                self?.showTip(title: "Discord hører deg mens du dikterer",
                              body: "Velg «BlackHole 2ch» som mikrofon i Discord: Innstillinger, Voice & Video, Input Device.")
            }
        }
    }

    @available(macOS 14.2, *)
    static func someoneReadsBlackHole() -> Bool {
        func prop<T>(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector, _ v: inout T, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Bool {
            var a = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            var size = UInt32(MemoryLayout<T>.size)
            return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr
        }
        func list(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
            var a = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
            var out = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
            guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &out) == noErr else { return [] }
            return out
        }
        func uid(_ d: AudioObjectID) -> String {
            var u: Unmanaged<CFString>?
            return prop(d, kAudioDevicePropertyDeviceUID, &u) ? (u?.takeRetainedValue() as String? ?? "") : ""
        }
        let me = Bundle.main.bundleIdentifier ?? ""
        for p in list(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList) {
            var bid: Unmanaged<CFString>?
            if prop(p, kAudioProcessPropertyBundleID, &bid), (bid?.takeRetainedValue() as String?) == me { continue }
            var running: UInt32 = 0
            guard prop(p, kAudioProcessPropertyIsRunningInput, &running), running != 0 else { continue }
            if list(p, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput).map(uid).contains("BlackHole2ch_UID") { return true }
        }
        return false
    }

    @available(macOS 14.2, *)
    static func discordUsesWrongMic() -> Bool {
        func prop<T>(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector, _ v: inout T, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Bool {
            var a = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            var size = UInt32(MemoryLayout<T>.size)
            return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr
        }
        func list(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
            var a = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
            var out = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
            guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &out) == noErr else { return [] }
            return out
        }
        func uid(_ d: AudioObjectID) -> String {
            var u: Unmanaged<CFString>?
            return prop(d, kAudioDevicePropertyDeviceUID, &u) ? (u?.takeRetainedValue() as String? ?? "") : ""
        }
        var inCall = false
        for p in list(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList) {
            var bid: Unmanaged<CFString>?
            guard prop(p, kAudioProcessPropertyBundleID, &bid),
                  (bid?.takeRetainedValue() as String?)?.hasPrefix("com.hnc.Discord") == true else { continue }
            var running: UInt32 = 0
            guard prop(p, kAudioProcessPropertyIsRunningInput, &running), running != 0 else { continue }
            inCall = true
            if list(p, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput).map(uid).contains("BlackHole2ch_UID") { return false }
        }
        return inCall
    }

    private func setFn(_ pressed: Bool) {
        guard pressed != fnDown else { return }
        fnDown = pressed
        releaseTimer?.cancel()
        let now = Date()
        if pressed {
            if muting { routing?.mute(true); beginMute() } else { countUnmuted(now) }
            pressedAt = now
            if !latched { checkDiscordMic() }
            if latched {
                unlatch(reopen: false)      // en ny fn-trykk avslutter diktering
                justUnlatched = true
            } else if muting, let tap = lastQuickTap, now.timeIntervalSince(tap) < doubleTapWindow {
                latch()                      // dobbelttrykk: hold mutet
            }
            lastQuickTap = nil
        } else {
            let wasQuickTap = now.timeIntervalSince(pressedAt) < tapMax
            let ignoreTap = justUnlatched
            justUnlatched = false
            if latched { DispatchQueue.main.async { self.updateMenu() }; return }
            var delay = releaseDelay
            if wasQuickTap && !ignoreTap {
                lastQuickTap = now
                delay = doubleTapWindow      // vent på mulig andre trykk før lyden åpnes
            }
            scheduleOpen(after: delay)
        }
        DispatchQueue.main.async { self.updateMenu() }
    }

    /// Diktering uten at dempingen er på, mens noen faktisk lytter i en samtale: etter tre ganger kommer et lite pek.
    private func countUnmuted(_ now: Date) {
        guard routing != nil, !nagShown, now.timeIntervalSince(lastCounted) > 4 else { return }
        if Bridge.smartAvailable && !othersReadBlackHole() { return }
        lastCounted = now
        unmutedDictations += 1
        guard unmutedDictations >= 3 else { return }
        nagShown = true
        notify(title: "Pssst … Discord hører deg dikte 🙉", body: "Tredje gangen nå. For no mas, skru på Mute Bridge.")
    }

    private func scheduleOpen(after delay: Double) {
        releaseTimer?.cancel()
        let timer = DispatchWorkItem { [weak self] in
            guard let self, !self.fnDown, !self.latched else { return }
            self.routing?.mute(false)
            self.endMute()
            self.updateMenu()
        }
        releaseTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: timer)
    }

    private func latch() {
        latched = true
        routing?.mute(true)
        latchTimeout?.cancel()
        let t = DispatchWorkItem { [weak self] in self?.unlatch() }
        latchTimeout = t
        DispatchQueue.main.asyncAfter(deadline: .now() + latchLimit, execute: t)
    }

    private func unlatch(reopen: Bool = true) {
        guard latched else { return }
        latched = false
        latchTimeout?.cancel()
        latchTimeout = nil
        if reopen && !fnDown { scheduleOpen(after: releaseDelay) }
        DispatchQueue.main.async { self.updateMenu() }
    }

    @objc private func unlatchFromMenu() { unlatch() }

    @objc private func quit() { stop(); NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = Bridge()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
