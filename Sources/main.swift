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
    case "AV": return (NSColor(white: 0.6, alpha: 1), NSColor(white: 0.75, alpha: 1))
    default: return (NSColor(srgbRed: 0.62, green: 0.42, blue: 0.92, alpha: 1), NSColor(srgbRed: 0.35, green: 0.74, blue: 0.96, alpha: 1))
    }
}

/// Fem små kapsler. Tegnes bare én gang per kombinasjon og caches av kalleren.
func meterImage(state: String, level: Int, variant: Int, dim: Bool) -> NSImage {
    let shapes: [[CGFloat]] = [[0.55, 0.85, 1.0, 0.7, 0.45], [0.7, 1.0, 0.6, 0.9, 0.5], [0.45, 0.7, 0.95, 1.0, 0.65]]
    let (c0, c1) = iconColors(state)
    let a = c0.usingColorSpace(.sRGB)!, b = c1.usingColorSpace(.sRGB)!
    let muted = state == "STILLE" || state == "LÅST"
    let l = CGFloat(level) / 8
    let image = NSImage(size: NSSize(width: 30, height: 18), flipped: false) { _ in
        let w: CGFloat = 3.6, gap: CGFloat = 2.4
        for i in 0..<5 {
            let k = CGFloat(i) / 4
            let h = state == "AV" ? 3 : 3 + (muted ? 0.3 : 1) * l * shapes[variant % 3][i] * 12
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateMenu()
        start()
        let timer = Timer(timeInterval: 1.0 / 12, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 0.04
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
        watchDevices()
        checkForUpdates()
        let upd = Timer(timeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.checkForUpdates() }
        RunLoop.main.add(upd, forMode: .common)
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

    private func checkForUpdates(manual: Bool = false) {
        guard !updateRepo.isEmpty, let url = URL(string: "https://api.github.com/repos/\(updateRepo)/releases/latest") else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String, let page = json["html_url"] as? String else { return }
            let latest = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            DispatchQueue.main.async {
                let newer = latest.compare(self.version, options: .numeric) == .orderedDescending
                if newer, self.updateAvailable?.version != latest {
                    self.updateAvailable = (latest, page)
                    self.updateMenu()
                    let c = UNUserNotificationCenter.current()
                    c.requestAuthorization(options: [.alert]) { ok, _ in
                        guard ok else { return }
                        let n = UNMutableNotificationContent()
                        n.title = "Mute Bridge \(latest) er klar"
                        n.body = "Klikk på ikonet i menylinjen for å laste ned."
                        c.add(UNNotificationRequest(identifier: "update", content: n, trigger: nil))
                    }
                }
            }
        }.resume()
    }

    private func updateIcon() {
        let state = routing == nil ? "AV" : latched ? "LÅST" : fnDown ? "STILLE" : "LIVE"
        let lv = state == "AV" ? 0 : Int((level * 8).rounded())
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
        menu.addItem(withTitle: message, action: nil, keyEquivalent: "")
        menu.addItem(.separator())
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
        if let u = updateAvailable { items.append(("⬆︎  Ny versjon \(u.version) – last ned", #selector(openUpdate))) }
        if latched { items.append(("🔓  Lås opp mikrofon", #selector(unlatchFromMenu))) }
        items.append(("↻  Start på nytt", #selector(start)))
        if !updateRepo.isEmpty { items.append(("Sjekk etter oppdateringer", #selector(checkNow))) }
        items.append(("Avslutt", #selector(quit)))
        for (title, action) in items {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
        }
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
        do {
            let route = Routing()
            try route.start()
            routing = route
            fnDown = CGEventSource.flagsState(.hidSystemState).contains(.maskSecondaryFn)
            route.mute(fnDown)
            message = "Sender mikrofonen til BlackHole 2ch"
        } catch {
            stop()
            message = error.localizedDescription
        }
        updateMenu()
    }

    private var lastTip = Date.distantPast

    /// Sjekker (bare når du begynner å diktere) om Discord er i en samtale uten å bruke BlackHole 2ch.
    private func checkDiscordMic() {
        guard Date().timeIntervalSince(lastTip) > 1800 else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard #available(macOS 14.2, *), Bridge.discordUsesWrongMic() else { return }
            DispatchQueue.main.async {
                guard let self, Date().timeIntervalSince(self.lastTip) > 1800 else { return }
                self.lastTip = Date()
                let c = UNUserNotificationCenter.current()
                c.requestAuthorization(options: [.alert]) { ok, _ in
                    guard ok else { return }
                    let n = UNMutableNotificationContent()
                    n.title = "Discord hører deg mens du dikterer"
                    n.body = "Velg «BlackHole 2ch» som mikrofon i Discord: Innstillinger, Voice & Video, Input Device."
                    c.add(UNNotificationRequest(identifier: "discord-mic", content: n, trigger: nil))
                }
            }
        }
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
            routing?.mute(true)
            beginMute()
            pressedAt = now
            if !latched { checkDiscordMic() }
            if latched {
                unlatch(reopen: false)      // en ny fn-trykk avslutter diktering
                justUnlatched = true
            } else if let tap = lastQuickTap, now.timeIntervalSince(tap) < doubleTapWindow {
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
