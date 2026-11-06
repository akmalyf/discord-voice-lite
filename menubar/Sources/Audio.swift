import AVFoundation
import Darwin

/// Log sederhana ke ~/Library/Logs/DiscordVoiceLite/app.log (NSLog tidak selalu terlihat).
func appLog(_ msg: String) {
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiscordVoiceLite")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("app.log")
    let line = "\(Date()) \(msg)\n"
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Daftar device audio (CoreAudio)

struct AudioDevice {
    let id: AudioDeviceID
    let uid: String  // stabil walau device dicabut-colok; dipakai untuk menyimpan pilihan
    let name: String

    static func all(input: Bool) -> [AudioDevice] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        let scope = input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput
        return ids.compactMap { id in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            var n: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &n) == noErr, n > 0,
                  let uid = string(id, kAudioDevicePropertyDeviceUID), let name = string(id, kAudioObjectPropertyName),
                  !uid.hasPrefix("CADefaultDeviceAggregate") else { return nil }  // aggregate internal milik voice processing
            return AudioDevice(id: id, uid: uid, name: name)
        }
    }

    static func find(uid: String?, input: Bool) -> AudioDevice? {
        guard let uid else { return nil }
        return all(input: input).first { $0.uid == uid }
    }

    private static func string(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}

// MARK: - Ring buffer PCM Int16 (interleaved stereo)

private final class PCMRing {
    private var buf: [Int16]
    private var r = 0, w = 0
    private(set) var count = 0

    init(capacity: Int) { buf = [Int16](repeating: 0, count: capacity) }

    /// `raw` berisi Int16 little-endian; bisa tidak aligned karena berasal dari frame socket.
    func write(_ raw: UnsafeRawBufferPointer) {
        let n = raw.count / 2
        for i in 0..<n {
            if count == buf.count { r = (r + 1) % buf.count; count -= 1 }
            buf[w] = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))
            w = (w + 1) % buf.count
            count += 1
        }
    }

    func drop(_ n: Int) {
        let n = min(n, count)
        r = (r + n) % buf.count
        count -= n
    }

    func pop() -> Int16 {
        let s = buf[r]
        r = (r + 1) % buf.count
        count -= 1
        return s
    }
}

// MARK: - Audio engine (mic + speaker, dengan voice processing macOS)

/// Mic dan speaker lewat AVAudioEngine. Saat mic aktif, Voice Processing I/O dinyalakan
/// (echo cancellation, noise suppression, AGC — sama seperti FaceTime). Mixing per user
/// dilakukan di render thread native supaya tidak ada underrun akibat GIL Python.
final class AudioIO {
    var onMic: ((Data) -> Void)?
    var onError: ((String) -> Void)?

    private final class Stream {
        let ring = PCMRing(capacity: 48_000)  // 0.5 dtk stereo
        var playing = false
        var lastWrite = CFAbsoluteTimeGetCurrent()
        /// Prebuffer adaptif: naik tiap kali buffer habis di tengah bicara (jitter), turun pelan saat stabil.
        var target = AudioIO.minPrebuffer
        var starved = false
        var lastAdjust = CFAbsoluteTimeGetCurrent()
    }

    private static let minPrebuffer = 2_880 * 2  // 60 ms stereo
    private static let maxPrebuffer = 9_600 * 2  // 200 ms
    private static let prebufferStep = 1_920 * 2  // 40 ms
    private static let maxBuffered = 19_200 * 2  // 400 ms; lebih dari ini → potong supaya latency tidak menumpuk
    private static let ramp = 48  // 1 ms fade in/out supaya tidak ada bunyi klik saat buffer habis

    private var underruns = 0

    private let lock = NSLock()
    private var streams: [UInt32: Stream] = [:]
    private var engine: AVAudioEngine?
    private var tapInstalled = false
    private var configObserver: NSObjectProtocol?
    private(set) var mic = false
    private(set) var speaker = false
    /// UID device pilihan user; nil = ikut default sistem.
    private(set) var inputUID: String?
    private(set) var outputUID: String?

    private let outFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    private let micFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 1, interleaved: true)!

    private var pushed = 0

    func push(ssrc: UInt32, pcm: UnsafeRawBufferPointer) {
        lock.lock()
        defer { lock.unlock() }
        pushed += 1
        if pushed % 500 == 1 {
            let targets = streams.values.map { $0.target / 96 }  // ms
            appLog("playback packets=\(pushed) speaker=\(speaker) bytes=\(pcm.count) underruns=\(underruns) prebuffer_ms=\(targets)")
        }
        guard speaker else { return }
        let now = CFAbsoluteTimeGetCurrent()
        let s: Stream
        if let existing = streams[ssrc] { s = existing } else { s = Stream(); streams[ssrc] = s }
        // Buffer sempat habis lalu paket datang lagi dalam waktu singkat → itu jitter jaringan,
        // bukan akhir kalimat. Perbesar prebuffer.
        if s.starved {
            s.starved = false
            if now - s.lastWrite < 0.25 {
                underruns += 1
                s.target = min(s.target + Self.prebufferStep, Self.maxPrebuffer)
                s.lastAdjust = now
            }
        }
        s.ring.write(pcm)
        if s.ring.count > Self.maxBuffered { s.ring.drop(s.ring.count - s.target - Self.prebufferStep) }
        s.lastWrite = now
    }

    private func mix(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, _ frames: Int) {
        for i in 0..<frames { left[i] = 0; right[i] = 0 }
        lock.lock()
        let now = CFAbsoluteTimeGetCurrent()
        var stale: [UInt32] = []
        for (ssrc, s) in streams {
            if now - s.lastWrite > 10 { stale.append(ssrc); continue }
            var fadeIn = false
            if !s.playing {
                guard s.ring.count >= s.target else { continue }
                s.playing = true
                fadeIn = true
            }
            let n = min(s.ring.count / 2, frames)
            let underrun = n < frames
            for i in 0..<n {
                var gain: Float = 1
                if fadeIn, i < Self.ramp { gain = Float(i) / Float(Self.ramp) }
                if underrun, n - i <= Self.ramp { gain = min(gain, Float(n - i) / Float(Self.ramp)) }
                left[i] += Float(s.ring.pop()) / 32_768 * gain
                right[i] += Float(s.ring.pop()) / 32_768 * gain
            }
            if underrun {
                s.playing = false  // prebuffer ulang
                s.starved = true
            } else if s.target > Self.minPrebuffer, now - s.lastAdjust > 10 {
                s.target -= Self.prebufferStep / 4  // stabil 10 dtk → kurangi 10 ms
                s.lastAdjust = now
            }
        }
        for ssrc in stale { streams.removeValue(forKey: ssrc) }
        lock.unlock()
        for i in 0..<frames {
            left[i] = max(-1, min(1, left[i]))
            right[i] = max(-1, min(1, right[i]))
        }
    }

    func configure(mic: Bool, speaker: Bool, force: Bool = false) {
        guard force || mic != self.mic || speaker != self.speaker else { return }
        teardown()
        lock.lock()
        self.mic = mic
        self.speaker = speaker
        lock.unlock()
        guard mic || speaker else { return }
        startEngine(mic: mic)
    }

    func setDevices(input: String?, output: String?) {
        guard input != inputUID || output != outputUID else { return }
        inputUID = input
        outputUID = output
        if engine != nil { configure(mic: mic, speaker: speaker, force: true) }
    }

    /// Voice Processing I/O memakai satu audio unit untuk input & output: element 1 = device input,
    /// element 0 = device output. Tanpa voice processing, output node juga memakai element 0.
    private func selectDevice(_ unit: AudioUnit?, uid: String?, input: Bool) {
        guard let unit, let device = AudioDevice.find(uid: uid, input: input) else { return }
        var id = device.id
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, input ? 1 : 0,
                                          &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        appLog("pilih device \(input ? "input" : "output") \(device.name) status=\(status)")
    }

    private func startEngine(mic: Bool) {
        let e = AVAudioEngine()
        // Mixer harus dibuat sebelum inputNode/voice processing; kalau terbalik, output gagal
        // di-initialize (-10875, kAUInitialize pada outputNode).
        _ = e.mainMixerNode
        if mic {
            // Jangan sentuh inputNode kalau mic tidak dipakai — mengaksesnya saja sudah membuka mic.
            let input = e.inputNode
            do { try input.setVoiceProcessingEnabled(true) } catch { appLog("voice processing gagal: \(error)") }
            if #available(macOS 14.0, *) {
                input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
            }
            selectDevice(input.audioUnit, uid: inputUID, input: true)
        }
        selectDevice(e.outputNode.audioUnit, uid: outputUID, input: false)
        if mic {
            let input = e.inputNode
            let fmt = input.outputFormat(forBus: 0)
            let pipeline = MicPipeline(from: fmt, to: micFormat) { [weak self] in self?.onMic?($0) }
            input.installTap(onBus: 0, bufferSize: 960, format: fmt) { buffer, _ in pipeline.process(buffer) }
            tapInstalled = true
        }

        let source = AVAudioSourceNode(format: outFormat) { [weak self] _, _, frameCount, abl in
            let list = UnsafeMutableAudioBufferListPointer(abl)
            guard let self, list.count >= 2,
                  let l = list[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = list[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            self.mix(l, r, Int(frameCount))
            return noErr
        }
        e.attach(source)
        e.connect(source, to: e.mainMixerNode, format: outFormat)

        // Ganti device (headphone dicolok, AirPods, dsb.) → bangun ulang engine.
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: e, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.configure(mic: self.mic, speaker: self.speaker, force: true)
        }

        do {
            try e.start()
            engine = e
            appLog("audio engine start mic=\(mic) speaker=\(speaker) output=\(e.outputNode.outputFormat(forBus: 0))")
        } catch {
            appLog("audio engine gagal start (mic=\(mic)): \(error)")
            engine = e
            teardown()
            if mic {
                // Minimal tetap bisa mendengar walau mic / voice processing bermasalah.
                onError?("Mic gagal dibuka, hanya speaker yang aktif")
                startEngine(mic: false)
            } else {
                onError?("Audio output gagal dibuka")
            }
        }
    }

    private func teardown() {
        if let o = configObserver { NotificationCenter.default.removeObserver(o) }
        configObserver = nil
        if let e = engine {
            if tapInstalled { e.inputNode.removeTap(onBus: 0) }
            e.stop()
        }
        tapInstalled = false
        engine = nil
        lock.lock()
        streams.removeAll()
        lock.unlock()
    }
}

/// Konversi buffer mic (format device / voice processing) → Int16 mono 48 kHz, potong per 20 ms.
private final class MicPipeline {
    private let converter: AVAudioConverter?
    private let monoFormat: AVAudioFormat
    private let outFormat: AVAudioFormat
    private let emit: (Data) -> Void
    private var pending: [Int16] = []
    private var frames = 0
    private var peak: Float = 0

    /// Voice processing di macOS memberi input multi-channel (mis. 7 ch) dengan hasil olahan hanya
    /// di channel 0. Downmix semua channel akan melemahkan suara ~1/7, jadi ambil channel 0 saja.
    init(from: AVAudioFormat, to: AVAudioFormat, emit: @escaping (Data) -> Void) {
        monoFormat = AVAudioFormat(standardFormatWithSampleRate: from.sampleRate, channels: 1)!
        converter = AVAudioConverter(from: monoFormat, to: to)
        outFormat = to
        self.emit = emit
        appLog("mic format=\(from) auth=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)")
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let src = buffer.floatChannelData?[0],
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength),
              let dst = mono.floatChannelData?[0] else { return }
        mono.frameLength = buffer.frameLength
        dst.update(from: src, count: Int(buffer.frameLength))
        for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(src[i])) }

        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * outFormat.sampleRate / monoFormat.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return mono
        }
        guard error == nil, let samples = out.int16ChannelData?[0] else { return }
        pending.append(contentsOf: UnsafeBufferPointer(start: samples, count: Int(out.frameLength)))
        while pending.count >= 960 {
            let frame = Array(pending[0..<960])
            pending.removeFirst(960)
            emit(frame.withUnsafeBytes { Data($0) })
            frames += 1
            if frames % 250 == 1 {  // ~5 dtk
                appLog("mic frames=\(frames) peak=\(peak)")
                peak = 0
            }
        }
    }
}

// MARK: - Unix socket ke daemon

/// Frame: [u8 type][u32 BE len][payload]. Type 1 (daemon → app) = u32 BE ssrc + PCM stereo;
/// type 2 (app → daemon) = PCM mono 960 sampel.
final class AudioSocket {
    var onPlayback: ((UInt32, UnsafeRawBufferPointer) -> Void)?
    private var fd: Int32 = -1
    private let writeLock = NSLock()
    private var generation = 0

    func connect(path: String) {
        disconnect()
        generation += 1
        let gen = generation
        Thread.detachNewThread { [weak self] in
            for _ in 0..<100 {  // daemon butuh waktu untuk bind (~10 dtk maks)
                guard let self, self.generation == gen else { return }
                let s = Self.open(path)
                if s >= 0 {
                    self.writeLock.lock()
                    self.fd = s
                    self.writeLock.unlock()
                    self.readLoop(s)
                    return
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
    }

    func disconnect() {
        writeLock.lock()
        if fd >= 0 { Darwin.shutdown(fd, SHUT_RDWR); Darwin.close(fd) }
        fd = -1
        writeLock.unlock()
    }

    func sendMic(_ pcm: Data) {
        var frame = Data([2])
        var len = UInt32(pcm.count).bigEndian
        withUnsafeBytes(of: &len) { frame.append(contentsOf: $0) }
        frame.append(pcm)
        writeLock.lock()
        defer { writeLock.unlock() }
        guard fd >= 0 else { return }
        frame.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + off, raw.count - off)
                if n <= 0 { return }
                off += n
            }
        }
    }

    private func readLoop(_ s: Int32) {
        var header = [UInt8](repeating: 0, count: 5)
        var payload = [UInt8](repeating: 0, count: 65_536)
        while readFully(s, &header, 5) {
            let len = Int(UInt32(header[1]) << 24 | UInt32(header[2]) << 16 | UInt32(header[3]) << 8 | UInt32(header[4]))
            if len > payload.count { payload = [UInt8](repeating: 0, count: len) }
            guard readFully(s, &payload, len) else { break }
            if header[0] == 1, len >= 4 {
                let ssrc = UInt32(payload[0]) << 24 | UInt32(payload[1]) << 16 | UInt32(payload[2]) << 8 | UInt32(payload[3])
                payload.withUnsafeBytes { raw in
                    onPlayback?(ssrc, UnsafeRawBufferPointer(rebasing: raw[4..<len]))
                }
            }
        }
        writeLock.lock()
        if fd == s { Darwin.close(s); fd = -1 }
        writeLock.unlock()
    }

    private func readFully(_ s: Int32, _ buf: inout [UInt8], _ n: Int) -> Bool {
        var off = 0
        while off < n {
            let r = buf.withUnsafeMutableBytes { Darwin.read(s, $0.baseAddress! + off, n - off) }
            if r <= 0 { return false }
            off += r
        }
        return true
    }

    private static func open(_ path: String) -> Int32 {
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return -1 }
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { p in
            for (i, b) in bytes.enumerated() where i < p.count - 1 { p[i] = b }
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if ok != 0 { Darwin.close(s); return -1 }
        return s
    }
}
