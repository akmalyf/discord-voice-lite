import AppKit
import Carbon.HIToolbox
import Security

// MARK: - Global hotkeys

enum HotKeys {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var refs: [EventHotKeyRef] = []
    private static var installed = false

    @discardableResult
    static func register(id: UInt32, keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) -> Bool {
        if !installed {
            installed = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var hk = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
                HotKeys.handlers[hk.id]?()
                return noErr
            }, 1, &spec, nil, nil)
        }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: OSType(0x444C_484B), id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs.append(ref)
        handlers[id] = handler
        return true
    }
}

// MARK: - Keychain

enum TokenStore {
    private static let service = "dev.akmal.DiscordVoiceLite"
    private static let legacyService = "dev.akmal.DiscordLight"  // sebelum rebrand ke Discord Voice Lite
    private static let account = "discord-token"

    static func load() -> String? {
        if let token = read(service) { return token }
        // Pindahkan token dari nama lama sekali saja.
        guard let token = read(legacyService) else { return nil }
        save(token)
        remove(legacyService)
        appLog("token keychain dimigrasi dari \(legacyService)")
        return token
    }

    static func save(_ token: String) {
        delete()
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account, kSecValueData as String: Data(token.utf8)]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func delete() {
        remove(service)
        remove(legacyService)
    }

    private static func read(_ service: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func remove(_ service: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}

/// Salin setting dari bundle ID lama (dev.akmal.DiscordLight) sekali saat pertama jalan setelah rebrand.
func migrateLegacyDefaults() {
    let defaults = UserDefaults.standard
    let legacy = "dev.akmal.DiscordLight"
    guard !defaults.bool(forKey: "migratedLegacyDefaults") else { return }
    defaults.set(true, forKey: "migratedLegacyDefaults")
    guard legacy != Bundle.main.bundleIdentifier, let old = defaults.persistentDomain(forName: legacy) else { return }
    let keys = ["sensitivity", "muted", "deafened", "autoJoin", "lastChannelId", "lastChannelName", "inputDevice", "outputDevice"]
    for key in keys where defaults.object(forKey: key) == nil {
        if let value = old[key] { defaults.set(value, forKey: key) }
    }
    appLog("setting dimigrasi dari \(legacy): \(keys.filter { old[$0] != nil })")
}

// MARK: - Daemon bridge (stdin/stdout JSON lines)

final class Daemon {
    var onEvent: (([String: Any]) -> Void)?
    let audioSocket = AudioSocket()
    private var process: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private var quitting = false

    // Build rilis: Python runtime + daemon dibundel di Resources. Build dev: pakai venv di repo (DLDaemonDir).
    private static let bundled = Bundle.main.resourcePath.map { $0 + "/daemon/discordlight.py" }
        .flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
    private let python: String = bundled != nil
        ? Bundle.main.resourcePath! + "/python/bin/python3"
        : (Bundle.main.object(forInfoDictionaryKey: "DLDaemonDir") as? String ?? "") + "/.venv/bin/python"
    private let script: String = bundled
        ?? (Bundle.main.object(forInfoDictionaryKey: "DLDaemonDir") as? String ?? "") + "/discordlight.py"
    private let socketPath = NSTemporaryDirectory() + "dl-\(getpid()).sock"

    func start() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = ["-s", script, socketPath]
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = Daemon.logHandle()
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            DispatchQueue.main.async { self?.consume(data) }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, !self.quitting else { return }
                self.onEvent?(["ev": "status", "state": "daemon_died"])
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.start() }
            }
        }
        do {
            try p.run()
            process = p
            stdin = inPipe.fileHandleForWriting
            audioSocket.connect(path: socketPath)
        } catch {
            onEvent?(["ev": "error", "message": "Daemon gagal start: \(error.localizedDescription)"])
        }
    }

    func stop() {
        quitting = true
        try? stdin?.close()  // daemon leave voice & keluar saat stdin ditutup
        if let p = process {
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if p.isRunning { p.terminate() } }
        }
    }

    func send(_ msg: [String: Any]) {
        guard let stdin, var data = try? JSONSerialization.data(withJSONObject: msg) else { return }
        data.append(0x0A)
        try? stdin.write(contentsOf: data)
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { onEvent?(obj) }
        }
    }

    private static func logHandle() -> FileHandle? {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiscordVoiceLite")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("daemon.log")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let h = try? FileHandle(forWritingTo: url)
        h?.seekToEndOfFile()
        return h
    }
}

// MARK: - Ikon menu bar

/// Logo (brand/mark-mono.svg) sebagai template image supaya ikut warna menu bar terang/gelap.
enum MenuBarIcon {
    private static let size = NSSize(width: 18, height: 16)
    // Geometri viewBox logo: 216 260 592 516. Panjang bar dihitung dari bawah garis menu bar.
    private static let bars: [(x: CGFloat, len: CGFloat)] = [(272, 124), (376, 264), (480, 408), (584, 264), (688, 124)]
    private static let minLen: CGFloat = 64  // bar paling pendek = titik bulat

    /// `levels` 0...1 per bar (1 = panjang sesuai logo, 0 = titik). `slashed` untuk mute/deafen.
    static func image(levels: [CGFloat] = [1, 1, 1, 1, 1], slashed: Bool = false) -> NSImage {
        let image = NSImage(size: size, flipped: true) { _ in
            let k = size.width / 592
            let dy = (size.height - 516 * k) / 2
            func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> NSBezierPath {
                NSBezierPath(roundedRect: NSRect(x: (x - 216) * k, y: (y - 260) * k + dy, width: w * k, height: h * k), xRadius: r * k, yRadius: r * k)
            }
            NSColor.black.setFill()
            rect(232, 276, 560, 48, 24).fill()
            for (i, bar) in bars.enumerated() {
                let level = max(0, min(1, levels[i]))
                rect(bar.x, 352, 64, minLen + (bar.len - minLen) * level, 32).fill()
            }
            if slashed {
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: 1.5, y: 1))
                slash.line(to: NSPoint(x: size.width - 1.5, y: size.height - 1))
                slash.lineCapStyle = .round
                // Potong logo di sekitar garis miring supaya garisnya tetap terbaca di ukuran kecil.
                NSGraphicsContext.current?.compositingOperation = .clear
                slash.lineWidth = 3.6
                slash.stroke()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                NSColor.black.setStroke()
                slash.lineWidth = 1.6
                slash.stroke()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Discord Voice Lite"
        return image
    }

    /// Level bar animasi saat ada suara: tiap bar berdenyut dengan tempo berbeda, bentuk V tetap terjaga.
    static func levels(at t: TimeInterval) -> [CGFloat] {
        let speeds: [Double] = [9.1, 11.7, 8.3, 12.9, 10.4]
        let phases: [Double] = [0.0, 1.9, 0.7, 2.6, 1.3]
        return (0..<5).map { i in CGFloat(0.3 + 0.7 * abs(sin(t * speeds[i] + phases[i]))) }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let daemon = Daemon()
    private let audio = AudioIO()
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var menuOpen = false

    // State dari daemon
    private var status = "starting"
    private var userName = ""
    private var guilds: [[String: Any]] = []
    private var voice: [String: Any] = [:]
    private var lastError: String?

    private let defaults = UserDefaults.standard
    private var sensitivity: Int {
        get { defaults.object(forKey: "sensitivity") as? Int ?? 200 }
        set { defaults.set(newValue, forKey: "sensitivity") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        migrateLegacyDefaults()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        render()

        daemon.onEvent = { [weak self] in self?.handle($0) }
        daemon.audioSocket.onPlayback = { [audio] ssrc, pcm in audio.push(ssrc: ssrc, pcm: pcm) }
        audio.onMic = { [weak daemon] pcm in daemon?.audioSocket.sendMic(pcm) }
        audio.onError = { [weak self] msg in self?.lastError = msg; self?.render() }
        audio.setDevices(input: defaults.string(forKey: "inputDevice"), output: defaults.string(forKey: "outputDevice"))
        daemon.start()

        // Global hotkey ⌃⌥M / ⌃⌥D (Carbon, tidak butuh izin Accessibility).
        let mods = UInt32(controlKey | optionKey)
        let ok = HotKeys.register(id: 1, keyCode: UInt32(kVK_ANSI_M), modifiers: mods) { [weak self] in self?.toggleMute() }
            && HotKeys.register(id: 2, keyCode: UInt32(kVK_ANSI_D), modifiers: mods) { [weak self] in self?.toggleDeafen() }
        if !ok { lastError = "Hotkey ⌃⌥M/⌃⌥D dipakai app lain" }
    }

    func applicationWillTerminate(_ notification: Notification) {
        daemon.stop()
        Thread.sleep(forTimeInterval: 0.5)  // beri waktu daemon keluar dari voice dengan rapi
    }

    // MARK: Events

    private func handle(_ ev: [String: Any]) {
        switch ev["ev"] as? String {
        case "status":
            status = ev["state"] as? String ?? status
            switch status {
            case "need_token":
                if let token = TokenStore.load() { daemon.send(["cmd": "login", "token": token]) } else { promptToken() }
            case "ready":
                userName = ev["user"] as? String ?? ""
                lastError = nil
                daemon.send(["cmd": "sensitivity", "rms": sensitivity])
                daemon.send(["cmd": "mute", "on": defaults.bool(forKey: "muted")])
                daemon.send(["cmd": "deaf", "on": defaults.bool(forKey: "deafened")])
                if defaults.bool(forKey: "autoJoin"), let id = defaults.string(forKey: "lastChannelId") {
                    daemon.send(["cmd": "join", "channel_id": id])
                }
            case "bad_token":
                TokenStore.delete()
                lastError = "Token tidak valid"
                promptToken()
            case "daemon_died":
                audio.configure(mic: false, speaker: false)
            default: break
            }
        case "audio":
            appLog("event audio \(ev)")
            audio.configure(mic: ev["mic"] as? Bool ?? false, speaker: ev["speaker"] as? Bool ?? false)
        case "channels":
            guilds = ev["guilds"] as? [[String: Any]] ?? []
        case "voice":
            voice = ev
            if let ch = ev["channel"] as? [String: Any], let id = ch["id"] as? String {
                defaults.set(id, forKey: "lastChannelId")
                defaults.set("\(ch["name"] as? String ?? "") — \(ch["guild"] as? String ?? "")", forKey: "lastChannelName")
            }
        case "error":
            lastError = ev["message"] as? String
        default: break
        }
        render()
    }

    // MARK: Rendering

    private var connected: Bool { voice["connected"] as? Bool ?? false }
    private var muted: Bool { voice["muted"] as? Bool ?? defaults.bool(forKey: "muted") }
    private var deafened: Bool { voice["deafened"] as? Bool ?? defaults.bool(forKey: "deafened") }

    private enum IconState: Equatable { case disconnected, idle, muted, deafened }
    private var iconState: IconState?
    private var animation: Timer?

    private func render() {
        let state: IconState = !connected ? .disconnected : deafened ? .deafened : muted ? .muted : .idle
        if state != iconState {
            iconState = state
            statusItem.button?.appearsDisabled = state == .disconnected
            drawIcon(levels: nil)
        }
        // Animasikan bar selama ada yang bicara (termasuk diri sendiri); saat deafen tidak ada suara.
        let animate = connected && !deafened && isAnyoneSpeaking
        if animate, animation == nil {
            let start = Date()
            let timer = Timer(timeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
                self?.drawIcon(levels: MenuBarIcon.levels(at: Date().timeIntervalSince(start)))
            }
            RunLoop.main.add(timer, forMode: .common)  // tetap jalan saat menu terbuka
            animation = timer
        } else if !animate, let timer = animation {
            timer.invalidate()
            animation = nil
            drawIcon(levels: nil)
        }
        if menuOpen { rebuildMenu() }
    }

    private func drawIcon(levels: [CGFloat]?) {
        let state = iconState ?? .disconnected
        let flat: [CGFloat] = [0, 0, 0, 0, 0]
        statusItem.button?.image = MenuBarIcon.image(
            levels: levels ?? (state == .deafened ? flat : [1, 1, 1, 1, 1]),
            slashed: state == .muted || state == .deafened
        )
    }

    private var isAnyoneSpeaking: Bool {
        (voice["members"] as? [[String: Any]])?.contains { $0["speaking"] as? Bool ?? false } ?? false
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuildMenu() }
    func menuWillOpen(_ menu: NSMenu) { menuOpen = true }
    func menuDidClose(_ menu: NSMenu) { menuOpen = false }

    private func rebuildMenu() {
        menu.removeAllItems()

        let header: String
        switch status {
        case "ready": header = userName
        case "connecting", "starting": header = "Menghubungkan…"
        case "need_token", "bad_token": header = "Belum login"
        case "daemon_died": header = "Daemon restart…"
        default: header = status
        }
        menu.addItem(disabled(header))
        if let err = lastError { menu.addItem(disabled("⚠️ " + err)) }
        menu.addItem(.separator())

        if connected, let ch = voice["channel"] as? [String: Any] {
            menu.addItem(disabled("🔊 \(ch["name"] as? String ?? "") — \(ch["guild"] as? String ?? "")"))
            for m in voice["members"] as? [[String: Any]] ?? [] {
                let icon = (m["deafened"] as? Bool ?? false) ? "🔇" : (m["muted"] as? Bool ?? false) ? "🚫" : (m["speaking"] as? Bool ?? false) ? "🟢" : "⚪️"
                let name = (m["name"] as? String ?? "") + ((m["me"] as? Bool ?? false) ? " (kamu)" : "")
                let item = disabled("    \(icon) \(name)")
                menu.addItem(item)
            }
            menu.addItem(.separator())
        } else if voice["connecting"] as? Bool ?? false {
            menu.addItem(disabled("Menyambung ke voice…"))
            menu.addItem(.separator())
        }

        let ready = status == "ready"
        menu.addItem(action("Mute", #selector(toggleMute), key: "m", on: muted, enabled: ready))
        menu.addItem(action("Deafen", #selector(toggleDeafen), key: "d", on: deafened, enabled: ready))
        menu.addItem(action("Disconnect", #selector(leave), enabled: connected))
        menu.addItem(.separator())

        let joinItem = NSMenuItem(title: "Join Voice Channel", action: nil, keyEquivalent: "")
        joinItem.isEnabled = ready && !guilds.isEmpty
        joinItem.submenu = channelsMenu()
        menu.addItem(joinItem)
        if let name = defaults.string(forKey: "lastChannelName"), !connected {
            menu.addItem(action("Rejoin \(name)", #selector(rejoin), enabled: ready))
        }
        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        let sm = NSMenu()
        sm.autoenablesItems = false
        sm.addItem(action("Auto-join channel terakhir saat start", #selector(toggleAutoJoin), on: defaults.bool(forKey: "autoJoin")))
        sm.addItem(.separator())
        sm.addItem(deviceItem("Input (Mic)", input: true))
        sm.addItem(deviceItem("Output (Speaker)", input: false))
        sm.addItem(.separator())
        sm.addItem(disabled("Sensitivitas mic"))
        for (title, rms) in [("Tinggi (suara pelan terdeteksi)", 100), ("Sedang", 200), ("Rendah (hanya suara keras)", 400)] {
            let item = action("    " + title, #selector(setSensitivity(_:)), on: sensitivity == rms)
            item.tag = rms
            sm.addItem(item)
        }
        sm.addItem(.separator())
        sm.addItem(action("Ganti Token…", #selector(changeToken)))
        sm.addItem(action("Buka Log", #selector(openLog)))
        settings.submenu = sm
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Discord Voice Lite", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    private func channelsMenu() -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        let currentId = (voice["channel"] as? [String: Any])?["id"] as? String
        for g in guilds {
            let gItem = NSMenuItem(title: g["name"] as? String ?? "", action: nil, keyEquivalent: "")
            let gm = NSMenu()
            gm.autoenablesItems = false
            for ch in g["channels"] as? [[String: Any]] ?? [] {
                let members = ch["members"] as? [String] ?? []
                let title = (ch["name"] as? String ?? "") + (members.isEmpty ? "" : "  (\(members.count))")
                let item = action(title, #selector(join(_:)), on: ch["id"] as? String == currentId)
                item.representedObject = ch["id"]
                if !members.isEmpty { item.toolTip = members.joined(separator: ", ") }
                gm.addItem(item)
                for name in members.prefix(8) { gm.addItem(disabled("      " + name)) }
            }
            gItem.submenu = gm
            m.addItem(gItem)
        }
        return m
    }

    private func deviceItem(_ title: String, input: Bool) -> NSMenuItem {
        let selected = input ? audio.inputUID : audio.outputUID
        let devices = AudioDevice.all(input: input)
        let missing = selected != nil && !devices.contains { $0.uid == selected }
        let m = NSMenu()
        m.autoenablesItems = false
        // Device pilihan sedang tidak terpasang → ikut default sistem sampai dicolok lagi.
        let def = action("Default Sistem" + (missing ? " (device pilihan tidak terhubung)" : ""), #selector(selectDevice(_:)),
                         on: selected == nil || missing)
        def.tag = input ? 1 : 0
        m.addItem(def)
        m.addItem(.separator())
        for d in devices {
            let item = action(d.name, #selector(selectDevice(_:)), on: d.uid == selected)
            item.tag = input ? 1 : 0
            item.representedObject = d.uid
            m.addItem(item)
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = m
        return item
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ sel: Selector, key: String = "", on: Bool = false, enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        if !key.isEmpty { item.keyEquivalentModifierMask = [.control, .option] }  // sama dengan global hotkey
        item.target = self
        item.state = on ? .on : .off
        item.isEnabled = enabled
        return item
    }

    // MARK: Actions

    @objc private func toggleMute() {
        let on = !muted
        defaults.set(on, forKey: "muted")
        if !on { defaults.set(false, forKey: "deafened") }
        daemon.send(["cmd": "mute", "on": on])
    }

    @objc private func toggleDeafen() {
        let on = !deafened
        defaults.set(on, forKey: "deafened")
        daemon.send(["cmd": "deaf", "on": on])
    }

    @objc private func leave() { daemon.send(["cmd": "leave"]) }

    @objc private func join(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        daemon.send(["cmd": "join", "channel_id": id])
    }

    @objc private func rejoin() {
        guard let id = defaults.string(forKey: "lastChannelId") else { return }
        daemon.send(["cmd": "join", "channel_id": id])
    }

    @objc private func toggleAutoJoin() { defaults.set(!defaults.bool(forKey: "autoJoin"), forKey: "autoJoin") }

    @objc private func setSensitivity(_ sender: NSMenuItem) {
        sensitivity = sender.tag
        daemon.send(["cmd": "sensitivity", "rms": sender.tag])
    }

    @objc private func selectDevice(_ sender: NSMenuItem) {
        let uid = sender.representedObject as? String
        let input = sender.tag == 1
        defaults.set(uid, forKey: input ? "inputDevice" : "outputDevice")
        audio.setDevices(input: input ? uid : audio.inputUID, output: input ? audio.outputUID : uid)
    }

    @objc private func changeToken() { promptToken() }

    @objc private func openLog() {
        NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiscordVoiceLite/daemon.log"))
    }

    private func promptToken() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Discord token"
        alert.informativeText = "Token disimpan di Keychain. Setelah ganti token, app akan restart daemon."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Simpan")
        alert.addButton(withTitle: "Batal")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let token = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        guard !token.isEmpty else { return }
        TokenStore.save(token)
        if status == "need_token" || status == "bad_token" {
            status = "connecting"
            daemon.send(["cmd": "login", "token": token])
        } else {
            // Client discord.py tidak bisa login ulang di proses yang sama → restart daemon.
            daemon.restart()
        }
        render()
    }
}

extension Daemon {
    func restart() {
        guard let p = process else { start(); return }
        // terminationHandler akan menjalankan start() lagi karena quitting == false.
        try? stdin?.close()
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if p.isRunning { p.terminate() } }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
