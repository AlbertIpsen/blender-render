import Foundation

/// A render PC beyond the main one in Settings.
struct PCEntry: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var name = ""
    var host = ""
    var user = ""
    var queueDir = #"C:\GeysierRender\queue"#
    var enabled = true
    /// Non-empty: a folder on this Mac standing in for the PC (testing without a second PC).
    var testDir = ""

    var displayName: String { name.isEmpty ? (testDir.isEmpty ? host : "Test PC") : name }

    /// Reads the `BR1:` code setup_windows_pc.ps1 prints at the end.
    init?(pairingCode: String) {
        struct Code: Decodable { let host: String; let user: String; let name: String? }
        let text = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("BR1:"), let data = Data(base64Encoded: String(text.dropFirst(4))),
              let code = try? JSONDecoder().decode(Code.self, from: data), !code.host.isEmpty, !code.user.isEmpty else { return nil }
        host = code.host
        user = code.user
        name = code.name ?? ""
    }

    init(id: String, name: String, host: String, user: String, queueDir: String, enabled: Bool, testDir: String) {
        (self.id, self.name, self.host, self.user) = (id, name, host, user)
        (self.queueDir, self.enabled, self.testDir) = (queueDir, enabled, testDir)
    }
}

/// Connection settings, kept in ~/Library/Application Support/BlenderRender/config.json.
struct Config: Codable, Equatable {
    var host = ""
    var user = ""
    var queueDir = #"C:\GeysierRender\queue"#
    var downloadDir = NSHomeDirectory() + "/Downloads/BlenderRender"
    var macBlender = "/Applications/Blender.app/Contents/MacOS/Blender"
    /// Fetch each job's renders as soon as it finishes on the PC.
    var autoDownload = false
    /// Stop the Mac idling to sleep while the queue is busy, so downloads and notifications keep working.
    var keepAwake = true
    /// Non-empty: use this folder on the Mac as a stand-in render PC (testing without the PC).
    var testDir = ""
    /// More PCs to share animations with; the PC above still takes every other job.
    var extraPCs: [PCEntry] = []
    /// Whether the PC above helps with split animations.
    var mainPCInSplits = true

    /// The PC above and any extras, in the shape split jobs use.
    var allPCs: [PCEntry] {
        let mac = PCEntry(id: "mac", name: "This Mac", host: "", user: "", queueDir: "", enabled: true,
                          testDir: Self.thisMacDir)
        guard isConfigured else { return extraPCs + [mac] }
        return [PCEntry(id: "main", name: "", host: host, user: user, queueDir: queueDir,
                        enabled: mainPCInSplits, testDir: testDir)] + extraPCs + [mac]
    }

    /// This Mac's own render queue: the same rq.py as on a PC, run by the Mac's Blender.
    static var thisMacDir: String { fileURL.deletingLastPathComponent().appendingPathComponent("thismac").path }

    /// These settings pointed at one PC, for talking to it through RenderPC.
    func config(for pc: PCEntry) -> Config {
        var c = self
        (c.host, c.user, c.queueDir, c.testDir) = (pc.host, pc.user, pc.queueDir, pc.testDir)
        return c
    }

    var isConfigured: Bool { !testDir.isEmpty || (!host.isEmpty && !user.isEmpty) }
    var displayHost: String { testDir.isEmpty ? host : "this Mac (test mode)" }

    static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BlenderRender")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }

    static func load() -> Config {
        guard let data = try? Data(contentsOf: fileURL),
              let cfg = try? JSONDecoder().decode(Config.self, from: data) else { return Config() }
        return cfg
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(self).write(to: Config.fileURL)
    }

    init() {}
    init(from decoder: Decoder) throws {  // tolerate keys added in later versions
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? d.host
        user = try c.decodeIfPresent(String.self, forKey: .user) ?? d.user
        queueDir = try c.decodeIfPresent(String.self, forKey: .queueDir) ?? d.queueDir
        downloadDir = try c.decodeIfPresent(String.self, forKey: .downloadDir) ?? d.downloadDir
        macBlender = try c.decodeIfPresent(String.self, forKey: .macBlender) ?? d.macBlender
        testDir = try c.decodeIfPresent(String.self, forKey: .testDir) ?? d.testDir
        autoDownload = try c.decodeIfPresent(Bool.self, forKey: .autoDownload) ?? d.autoDownload
        extraPCs = try c.decodeIfPresent([PCEntry].self, forKey: .extraPCs) ?? d.extraPCs
        mainPCInSplits = try c.decodeIfPresent(Bool.self, forKey: .mainPCInSplits) ?? d.mainPCInSplits
        keepAwake = try c.decodeIfPresent(Bool.self, forKey: .keepAwake) ?? d.keepAwake
    }
}

/// A job as the PC's rq.py reports it (job.json merged with status.json).
struct PCJob: Decodable, Identifiable, Equatable {
    let id: String
    var name: String?
    var mode: String?
    var state: String?
    var progress: Double?
    var frame: Int?
    var start: Int?
    var end: Int?
    var sample: Int?
    var samples: Int?
    var remaining: String?
    var saved: Int?
    var files: Int?
    var pct: Int?
    var step: Int?
    var submitted: Double?
    var started: Double?
    var ended: Double?
    var error: String?
    var last_file: String?
    /// Seconds left as of `eta_at` (PC clock), from measured frame times; nil while still estimating.
    var eta: Double?
    var eta_at: Double?
    /// On a batch of a split job: the split job's id.
    var parent: String?
    /// True for a split job, which runs on this Mac's scheduler rather than on one PC.
    var split: Bool?
    /// What a split job's PCs are doing, shown in place of the frame and sample line.
    var note: String?
    /// Waiting on this Mac for its PCs and Start (HeldJob), set by this app.
    var held: Bool?
    /// Which PC the job is on (PCEntry id), filled in by this app; nil for a split job.
    var pc: String?

    /// Seconds left right now, counting down between updates from the PC.
    func secondsLeft(at now: Date = Date()) -> Double? {
        guard state == "rendering", let eta, let at = eta_at else { return nil }
        return max(0, eta - (now.timeIntervalSince1970 - at))
    }

    /// "2 h 10 min left" / "less than a minute left": one rounding for the row and the window subtitle.
    static func timeLeft(_ s: Double) -> String? {
        if s < 45 { return "less than a minute left" }
        let m = max(1, Int((s / 60).rounded()))
        return m < 60 ? "\(m) min left" : "\(m / 60) h \(m % 60) min left"
    }

    /// "About 2 h 10 min left · done around 18:40", or nil while there's no estimate yet.
    func timeLeftText(at now: Date = Date()) -> String? {
        guard let s = secondsLeft(at: now), let short = Self.timeLeft(s) else { return nil }
        let text = s < 45 ? short.prefix(1).uppercased() + short.dropFirst() : "About " + short
        guard s >= 600 else { return text }
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = Calendar.current.isDate(now.addingTimeInterval(s), inSameDayAs: now) ? .none : .short
        return text + " · done around " + f.string(from: now.addingTimeInterval(s))
    }

    var isActive: Bool { state == "queued" || state == "rendering" }

    /// "Frame 12 of 250 · Sample 40 of 128 · 4%": how far a rendering job has got.
    var progressText: String {
        var parts: [String] = []
        if mode == "animation", let f = frame, let s = start, let e = end {
            let n = max(1, step ?? 1)
            parts.append("Frame \((f - s) / n + 1) of \((e - s) / n + 1)")
        }
        if let s = sample, let n = samples { parts.append("Sample \(s) of \(n)") }
        parts.append("\(Int((progress ?? 0) * 100))%")
        return parts.joined(separator: " · ")
    }

    /// "Video", "1 image", "250 frames": an animation that comes back as one file is a video.
    var outputSummary: String {
        let n = files ?? 0
        if mode == "animation" { return n == 1 ? "Video" : "\(n) frames" }
        return n == 1 ? "1 image" : "\(n) files"
    }
    var displayName: String { name ?? id }
}

/// `off`: switched off for rendering on the PC itself (its tray app); jobs wait until it's back on.
struct PCList: Decodable { let jobs: [PCJob]; let worker: Bool; let gpu: String?; var off: Bool? }

/// `rq stats`: the GPU fields are missing on a PC without nvidia-smi. VRAM is in MiB.
struct PCStats: Decodable {
    let disk_free: Double?
    let gpu_name: String?
    let gpu_load: Double?
    let gpu_temp: Double?
    let vram_used: Double?
    let vram_total: Double?
}
struct PCVersion: Decodable { let version: Int; let worker: Bool; let gpu: String?; let host: String?; var blender_version: String?; var off: Bool? }

/// Talks to rq.py on the render PC over SSH (or to a local folder in test mode).
struct RenderPC {
    static let protocolVersion = 12
    let cfg: Config

    private var sshOptions: [String] {
        // BatchMode can't answer "trust this host?", so a new PC needs accept-new or it never connects.
        ["-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=6", "-o", "ServerAliveInterval=15",
         "-o", "ControlMaster=auto", "-o", "ControlPath=/tmp/blenderrender-ssh-%C", "-o", "ControlPersist=120",
         "\(cfg.user)@\(cfg.host)"]
    }

    private func rq(_ args: [String], stdinFile: URL? = nil, stdoutFile: URL? = nil,
                    progress: (@Sendable (Int64) -> Void)? = nil) async throws -> Data {
        if !cfg.testDir.isEmpty {
            return try await Shell.run("/usr/bin/python3", [cfg.testDir + "/rq.py"] + args,
                                       stdinFile: stdinFile, stdoutFile: stdoutFile, progress: progress)
        }
        let cmd = "\"\(cfg.queueDir)\\rq.cmd\" " + args.joined(separator: " ")
        return try await Shell.run("/usr/bin/ssh", sshOptions + [cmd],
                                   stdinFile: stdinFile, stdoutFile: stdoutFile, progress: progress)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch {
            throw ShellError(message: "Unexpected reply from the render PC: " + String(decoding: data.prefix(300), as: UTF8.self))
        }
    }

    func version() async throws -> PCVersion { try decode(PCVersion.self, try await rq(["version"])) }
    func list() async throws -> PCList { try decode(PCList.self, try await rq(["list"])) }
    func stats() async throws -> PCStats { try decode(PCStats.self, try await rq(["stats"])) }
    /// Counts as activity on the PC, so it doesn't sleep between batches of a split job.
    func nudgeAwake() async throws { _ = try await rq(["nudge"]) }

    /// Connect, installing or updating the queue scripts on the PC when they're missing or outdated.
    func connect() async throws -> PCVersion {
        if let v = try? await version(), v.version == Self.protocolVersion { return v }
        try await installScripts()
        _ = try? await rq(["install-tray"])  // the Windows tray app; rendering works without it
        do { return try await version() } catch {
            throw ShellError(message: "The queue doesn't run on the render PC. Run setup_windows_pc.ps1 on the PC first.\n\n\(error.localizedDescription)")
        }
    }

    /// Copy the app's bundled PC scripts (rq.py, render_job.py, remote_gpu.py, progress.py) to the PC.
    func installScripts() async throws {
        guard let src = Bundle.main.resourceURL?.appendingPathComponent("pc") else { return }
        if !cfg.testDir.isEmpty {
            let fm = FileManager.default
            try fm.createDirectory(atPath: cfg.testDir, withIntermediateDirectories: true)
            for f in try fm.contentsOfDirectory(atPath: src.path) where !f.hasSuffix(".exe.new") {
                let dst = cfg.testDir + "/" + f
                try? fm.removeItem(atPath: dst)
                try fm.copyItem(atPath: src.path + "/" + f, toPath: dst)
            }
            let settings = cfg.testDir + "/rq_config.json"  // This Mac: its own Blender, on its own GPU (Metal)
            if !fm.fileExists(atPath: settings) {
                let json = try JSONSerialization.data(withJSONObject: ["blender": cfg.macBlender, "gpu": true])
                try json.write(to: URL(fileURLWithPath: settings))
            }
            return
        }
        let tar = FileManager.default.temporaryDirectory.appendingPathComponent("geysier-pc-\(UUID().uuidString).tar")
        defer { try? FileManager.default.removeItem(at: tar) }
        _ = try await Shell.run("/usr/bin/tar", ["-cf", tar.path, "--no-mac-metadata", "--exclude", "__pycache__", "--exclude", ".DS_Store", "-C", src.path, "."])
        let dir = cfg.queueDir
        _ = try await Shell.run("/usr/bin/ssh", sshOptions + ["if not exist \"\(dir)\" mkdir \"\(dir)\""])
        _ = try await Shell.run("/usr/bin/ssh", sshOptions + ["tar -xf - -C \"\(dir.replacingOccurrences(of: "\\", with: "/"))\""],
                                stdinFile: tar)
    }

    /// Send a (packed) .blend into the queue; returns the new job id.
    /// `progress` gets the bytes sent so far.
    func submit(blend: URL, options: [String: Any], progress: @escaping @Sendable (Int64) -> Void) async throws -> String {
        let json = try JSONSerialization.data(withJSONObject: options)
        let b64 = json.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let data = try await rq(["receive", b64], stdinFile: blend, progress: progress)
        struct Reply: Decodable { let id: String }
        return try decode(Reply.self, data).id
    }

    func cacheHas(_ key: String) async throws -> Bool {
        struct Reply: Decodable { let has: Bool }
        return try decode(Reply.self, try await rq(["cache-has", key])).has
    }

    /// Send a split job's .blend once; all its batches on this PC render from it.
    func cachePut(_ key: String, blend: URL) async throws { _ = try await rq(["cache-put", key], stdinFile: blend) }
    func cacheDrop(_ key: String) async throws { _ = try await rq(["cache-drop", key]) }

    /// Queue a batch of a split job; returns its job id.
    func submitBatch(options: [String: Any]) async throws -> String {
        let json = try JSONSerialization.data(withJSONObject: options)
        let b64 = json.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        struct Reply: Decodable { let id: String }
        return try decode(Reply.self, try await rq(["batch", b64])).id
    }

    /// A small PNG of the job's first image for notification banners; nil if there's none.
    func previewThumbnail(_ id: String) async -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("blenderrender-previews")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let raw = dir.appendingPathComponent("\(id)-full"), thumb = dir.appendingPathComponent("\(id).png")
        defer { try? FileManager.default.removeItem(at: raw) }
        do {
            _ = try await rq(["preview", id], stdoutFile: raw)
            _ = try await Shell.run("/usr/bin/sips", ["-s", "format", "png", "-Z", "640", raw.path, "--out", thumb.path])
            return thumb
        } catch { return nil }
    }

    /// `by` says who asked (a word, no spaces); the PC writes it to its cancel.log.
    func cancel(_ id: String, by: String = "app") async throws { _ = try await rq(["cancel", id, "--by=" + by]) }
    func delete(_ id: String, by: String = "app-cleanup") async throws { _ = try await rq(["delete", id, "--by=" + by]) }
    /// Let a job that's held on the PC render.
    func release(_ id: String) async throws { _ = try await rq(["release", id]) }

    func log(_ id: String) async throws -> String {
        struct Reply: Decodable { let log: String }
        return try decode(Reply.self, try await rq(["log", id])).log
    }

    /// Size in bytes of the tar `send` streams for a job (an estimate; nil if the PC can't tell).
    func downloadSize(_ id: String) async -> Int64? {
        struct Reply: Decodable { let bytes: Int64 }
        guard let data = try? await rq(["size", id]) else { return nil }
        return try? JSONDecoder().decode(Reply.self, from: data).bytes
    }

    /// Download a job's renders into `folder` (created), log.txt included. `progress` gets the bytes received.
    func download(_ id: String, into folder: URL, progress: (@Sendable (Int64) -> Void)? = nil) async throws -> Int {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("geysier-\(id)-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let tar = tmp.appendingPathComponent("job.tar")
        _ = try await rq(["send", id], stdoutFile: tar, progress: progress)
        _ = try await Shell.run("/usr/bin/tar", ["-xf", tar.path, "-C", tmp.path])
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var count = 0
        let outDir = tmp.appendingPathComponent("out")
        let items = (try? fm.contentsOfDirectory(atPath: outDir.path)) ?? []
        for item in items + ["../log.txt"] {
            let src = outDir.appendingPathComponent(item).standardizedFileURL
            guard fm.fileExists(atPath: src.path) else { continue }
            var name = src.lastPathComponent
            if item != "../log.txt", (name as NSString).pathExtension.isEmpty, let ext = Self.sniffExtension(src) {
                name += "." + ext  // e.g. a video from a .blend with File Extensions turned off
            }
            let dst = folder.appendingPathComponent(name)
            try? fm.removeItem(at: dst)
            try fm.moveItem(at: src, to: dst)
            if item != "../log.txt" { count += 1 }
        }
        return count
    }
}

extension RenderPC {
    /// File type from the first bytes, for render outputs that came back without an extension.
    static func sniffExtension(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let b = [UInt8]((try? h.read(upToCount: 16)) ?? Data())
        guard b.count >= 12 else { return nil }
        let ascii = { (r: Range<Int>) in String(decoding: b[r], as: UTF8.self) }
        if ascii(4..<8) == "ftyp" { return ascii(8..<12) == "qt  " ? "mov" : "mp4" }
        if b[0...3] == [0x89, 0x50, 0x4E, 0x47] { return "png" }
        if b[0...2] == [0xFF, 0xD8, 0xFF] { return "jpg" }
        if b[0...3] == [0x76, 0x2F, 0x31, 0x01] { return "exr" }
        if b[0...3] == [0x1A, 0x45, 0xDF, 0xA3] { return "mkv" }
        if ascii(0..<4) == "RIFF" && ascii(8..<12) == "AVI " { return "avi" }
        if b[0...1] == [0x49, 0x49] || b[0...1] == [0x4D, 0x4D] { return "tif" }
        return nil
    }
}

/// What the Mac's own Blender found in a dropped file.
struct BlendInfo: Codable {
    let frame_start: Int
    let frame_end: Int
    let frame_current: Int
    let res_x: Int
    let res_y: Int
    let pct: Int
    let engine: String
    let samples: Int
    let camera: String?
    let video: Bool
    let missing: [String]
    let blender: String
}

enum Packer {
    /// Pack the file's textures into a temporary copy with the Mac's Blender and read its settings.
    static func packAndInspect(_ file: URL, cfg: Config) async throws -> (URL, BlendInfo) {
        guard let script = Bundle.main.resourceURL?.appendingPathComponent("pack_inspect.py") else {
            throw ShellError(message: "pack_inspect.py missing from the app bundle")
        }
        guard FileManager.default.isExecutableFile(atPath: cfg.macBlender) else {
            throw ShellError(message: "Blender not found at \(cfg.macBlender) (needed to pack the file's textures). Set it in Settings.")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("geysier-pack-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let packed = dir.appendingPathComponent(file.lastPathComponent)
        let data = try await Shell.run(cfg.macBlender, ["-b", file.path, "--factory-startup", "-P", script.path, "--", packed.path])
        let text = String(decoding: data, as: UTF8.self)
        guard let line = text.split(separator: "\n").last(where: { $0.hasPrefix("inspect: ") }),
              let info = try? JSONDecoder().decode(BlendInfo.self, from: Data(line.dropFirst(9).utf8)),
              FileManager.default.fileExists(atPath: packed.path) else {
            throw ShellError(message: "Blender couldn't read \(file.lastPathComponent).\n" + String(text.suffix(600)))
        }
        return (packed, info)
    }
}
