import AppKit
import Foundation

/// A dropped file on its way into the queue (packing on the Mac, then uploading).
struct Upload: Identifiable {
    let id = UUID()
    let file: URL
    var phase: Phase = .packing
    var transfer = Transfer()

    enum Phase: Equatable { case packing, waitingForSetup, uploading, failed(String) }
}

/// Render options chosen in the sheet after a drop.
struct JobSetup: Identifiable {
    let id: UUID          // the Upload's id
    let packed: URL
    let info: BlendInfo
    var name: String
    var isAnimation: Bool
    var frame: Int
    var start: Int
    var end: Int
    var pct: Int
    var samples: Int
    /// Fast preview (animations): every `fastStep`-th frame, persistent data; the video keeps its length.
    var fast = false
    /// Share the frames between all PCs that can take part.
    var split = true
    /// Otherwise the whole job goes to this PC (PCEntry id).
    var pc = "main"
    /// Render every Nth frame, when something other than `fast` chose it (the Claude connector).
    var step: Int?

    static let fastStep = 4, fastPct = 35, fastSamples = 16
}

enum PCStatus: Equatable {
    case notConfigured, connecting, online(host: String, gpu: String, worker: Bool), offline(String)
}

@MainActor
final class AppState: ObservableObject {
    @Published var cfg = Config.load()
    @Published var status: PCStatus = .connecting
    @Published var jobs: [PCJob] = []
    @Published var uploads: [Upload] = []
    @Published var setups: [JobSetup] = []
    /// Jobs being downloaded, by id; `total` is nil while the size is being asked for.
    @Published var downloads: [String: Transfer] = [:]
    @Published var downloaded: [String: String] = UserDefaults.standard.dictionary(forKey: "downloaded") as? [String: String] ?? [:]
    @Published var alert: String?
    @Published var showGuide = false
    /// A newer release than this app, once a check has found one.
    @Published var update: Updater.Release?
    @Published var installingUpdate = false
    /// Job whose Blender log sheet is open (from a row or a "Show Log" notification button).
    @Published var logRequest: PCJob?
    /// What each PC reported when last checked, by PCEntry id; nil means it can't be reached.
    @Published var pcVersions: [String: PCVersion] = [:]
    /// Live detail for the Render PCs window, by PCEntry id; only kept fresh while that window is open.
    @Published var pcLive: [String: PCLive] = [:]
    private var lastPCLook = Date.distantPast

    private var connected = false
    /// Last list from each PC, by PCEntry id; an unreachable PC keeps what it last reported.
    private var jobsByPC: [String: [PCJob]] = [:]
    private var pcJobs: [PCJob] { cfg.allPCs.flatMap { jobsByPC[$0.id] ?? [] } }
    private var otherPollTask: Task<Void, Never>?
    private lazy var splits = SplitManager { [weak self] in self?.refreshJobs() }
    private var pollTask: Task<Void, Never>?
    private var pcsChecked = false
    /// Held while the Mac must not idle to sleep; ending it hands sleep back to macOS.
    private var awakeActivity: NSObjectProtocol?

    var pc: RenderPC { RenderPC(cfg: cfg) }
    var rendering: [PCJob] { jobs.filter { $0.state == "rendering" } }
    var upNext: [PCJob] { jobs.filter { $0.state == "queued" } }
    /// Changes whenever rows move between sections, so the list can animate it.
    var layoutKey: [String] { uploads.map(\.id.uuidString) + jobs.map { $0.id + ($0.state ?? "") } }

    /// Window subtitle: what the queue is doing right now.
    var summary: String {
        var parts: [String] = []
        if !uploads.isEmpty { parts.append("\(uploads.count) sending") }
        if !downloads.isEmpty { parts.append("\(downloads.count) downloading") }
        if let job = rendering.first {
            let left = job.secondsLeft().flatMap(PCJob.timeLeft).map { " · " + $0 } ?? ""
            parts.append("\(rendering.count) rendering" + left)
        }
        if !upNext.isEmpty { parts.append("\(upNext.count) waiting") }
        let ready = finished.filter { $0.state == "done" && downloaded[$0.id] == nil }.count
        if ready > 0 { parts.append("\(ready) ready to download") }
        return parts.isEmpty ? (cfg.isConfigured ? "Queue is empty" : "Not connected") : parts.joined(separator: " · ")
    }
    var finished: [PCJob] { jobs.filter { !$0.isActive }.sorted { ($0.ended ?? $0.submitted ?? 0) > ($1.ended ?? $1.submitted ?? 0) } }

    init() {
        Notifier.shared.setUp()
        Notifier.shared.onAction = { [weak self] id, action in self?.handleNotification(job: id, action: action) }
        startPolling()
        splits.restore(cfg: cfg)
        refreshJobs()
        Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkPCs()
                try? await Task.sleep(for: .seconds(20))
            }
        }
        Task { [weak self] in
            while !Task.isCancelled {
                self?.splits.nudgePCs()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        Task { [weak self] in
            self?.clearOldInbox()
            while !Task.isCancelled {
                self?.checkInbox()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        Task { [weak self] in
            while !Task.isCancelled {
                self?.checkForUpdates(manual: false)
                try? await Task.sleep(for: .seconds(6 * 3600))
            }
        }
    }

    /// Automatic checks stay quiet on failure (no network); the menu item reports everything.
    func checkForUpdates(manual: Bool) {
        Task {
            do {
                let latest = try await Updater.latest()
                if Updater.isNewer(latest.version, than: Updater.currentVersion) {
                    update = latest
                } else if manual {
                    alert = "BlenderRender \(Updater.currentVersion) is the latest version."
                }
            } catch {
                if manual { alert = "Couldn't check for updates: \(error.localizedDescription)" }
            }
        }
    }

    func installUpdate() {
        guard let update, !installingUpdate else { return }
        guard uploads.isEmpty, downloads.isEmpty else {
            alert = "Wait for the files that are sending or downloading to finish, then update."
            return
        }
        installingUpdate = true
        Task {
            do { try await Updater.install(update) } catch {
                installingUpdate = false
                alert = "Update failed: \(error.localizedDescription)"
            }
        }
    }

    private func handleNotification(job id: String, action: String) {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        switch action {
        case Notifier.downloadAction: download(job)
        case Notifier.showLogAction: logRequest = job
        default: break  // clicking the banner just brings the window forward
        }
    }

    func saveConfig(_ new: Config) {
        cfg = new
        cfg.save()
        connected = false
        jobsByPC = [:]
        refreshJobs()
        startPolling()
        Task { await checkPCs() }
    }

    /// Check every PC, installing or updating the queue scripts as `connect` does.
    private func checkPCs() async {
        let cfg = self.cfg
        await withTaskGroup(of: (String, PCVersion?).self) { group in
            for pc in cfg.allPCs {
                group.addTask { (pc.id, try? await RenderPC(cfg: cfg.config(for: pc)).connect()) }
            }
            var found: [String: PCVersion] = [:]
            for await (id, version) in group { found[id] = version }
            pcVersions = found
            pcsChecked = true
        }
    }

    /// Keeps `pcLive` fresh until the calling task is cancelled.
    func watchPCs() async {
        while !Task.isCancelled {
            await refreshPCLive()
            try? await Task.sleep(for: .seconds(3))
        }
    }

    private func refreshPCLive() async {
        // The window and any open job rows each watch; one look covers them all.
        guard Date().timeIntervalSince(lastPCLook) > 2 else { return }
        lastPCLook = Date()
        let cfg = self.cfg, known = pcVersions
        await withTaskGroup(of: (String, PCVersion?, PCLive).self) { group in
            for pc in cfg.allPCs {
                group.addTask {
                    let rpc = RenderPC(cfg: cfg.config(for: pc))
                    do {
                        var version = known[pc.id]
                        if version == nil { version = try await rpc.connect() }
                        let list = try await rpc.list()
                        version?.off = list.off
                        return (pc.id, version, PCLive(jobs: list.jobs, stats: try? await rpc.stats(), seen: Date(), off: list.off == true))
                    } catch {
                        return (pc.id, nil, PCLive(error: error.localizedDescription))
                    }
                }
            }
            for await (id, version, live) in group {
                var live = live
                if live.seen == nil {  // keep the last good detail, so a blip doesn't blank the card
                    live.seen = pcLive[id]?.seen
                    live.stats = pcLive[id]?.stats
                }
                pcVersions[id] = version
                pcLive[id] = live
            }
        }
    }

    /// Batches of running split jobs this PC has finished.
    func splitBatchesDone(on id: String) -> Int {
        splits.runs.filter { $0.state.state == "rendering" }
            .reduce(0) { $0 + $1.state.batches.filter { $0.pc == id && $0.status == "done" }.count }
    }

    /// Seconds per frame this PC is managing on a running split job.
    func splitSpeed(on id: String) -> Double? {
        splits.runs.last { $0.state.state == "rendering" }?.state.speeds?[id]
    }

    /// PCs that can share an animation made in `blender`: switched on, online and on the same version.
    func splitPCs(blender: String) -> [PCEntry] {
        let wanted = Self.majorMinor(blender)
        return cfg.allPCs.filter { pc in
            guard pc.enabled, let v = pcVersions[pc.id], v.off != true else { return false }
            return Self.majorMinor(v.blender_version ?? "") == wanted
        }
    }

    private static func majorMinor(_ version: String) -> String {
        version.split(separator: ".").prefix(2).joined(separator: ".")
    }

    /// PCs a whole job can go to: the main one, and any other that's answering.
    func singlePCs() -> [PCEntry] {
        cfg.allPCs.filter { $0.id == "main" || pcVersions[$0.id] != nil }
    }

    /// The PC's own name, or its Windows computer name when none was given.
    func pcName(_ pc: PCEntry) -> String {
        pc.name.isEmpty ? pcVersions[pc.id]?.host ?? pc.displayName : pc.displayName
    }

    /// Switched off for rendering on the PC itself, as last reported.
    func isOff(_ id: String) -> Bool { pcVersions[id]?.off == true }

    /// Which PC a job is on, for the row; nil while there's only one PC.
    func pcName(of job: PCJob) -> String? {
        guard cfg.allPCs.count > 1, let id = job.pc, let pc = cfg.allPCs.first(where: { $0.id == id }) else { return nil }
        return pcName(pc)
    }

    /// The PC holding this job.
    private func rpc(for job: PCJob) -> RenderPC {
        guard let id = job.pc, id != "main", let pc = cfg.allPCs.first(where: { $0.id == id }) else { return pc }
        return RenderPC(cfg: cfg.config(for: pc))
    }

    /// PCs left out of a split because their Blender differs, for the message in the add sheet.
    func mismatchedPCs(blender: String) -> [String] {
        let wanted = Self.majorMinor(blender)
        return cfg.allPCs.filter { pc in
            guard pc.enabled, let v = pcVersions[pc.id] else { return false }
            return Self.majorMinor(v.blender_version ?? "") != wanted
        }.map(\.displayName)
    }

    private func refreshJobs() {
        let new = pcJobs + splits.jobs
        notifyChanges(old: jobs, new: new)
        jobs = new
        updateKeepAwake()
    }

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let wait = await self.poll()
                try? await Task.sleep(for: .seconds(wait))
            }
        }
        otherPollTask?.cancel()
        otherPollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOtherPCs()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    /// Jobs sent whole to a PC other than the main one. Separate from `poll`, so a PC that's
    /// switched off doesn't slow the main queue down.
    private func pollOtherPCs() async {
        let cfg = self.cfg
        let others = cfg.allPCs.filter { $0.id != "main" }
        let results = await withTaskGroup(of: (String, PCList?).self) { group in
            for pc in others {
                group.addTask { (pc.id, try? await RenderPC(cfg: cfg.config(for: pc)).list()) }
            }
            return await group.reduce(into: [(String, PCList?)]()) { $0.append($1) }
        }
        guard cfg.allPCs == self.cfg.allPCs else { return }  // settings changed meanwhile
        for (id, list) in results {
            guard let list else { continue }
            pcVersions[id]?.off = list.off
            let jobs = list.jobs
            jobsByPC[id] = jobs.filter { $0.parent == nil }.map { var j = $0; j.pc = id; return j }
        }
        for id in jobsByPC.keys where !others.contains(where: { $0.id == id }) && id != "main" { jobsByPC[id] = nil }
        refreshJobs()
    }

    /// One refresh; returns seconds until the next one.
    private func poll() async -> Double {
        defer { updateKeepAwake() }
        guard cfg.isConfigured else { status = .notConfigured; return 2 }
        let pc = self.pc
        do {
            if !connected {
                if case .online = status {} else { status = .connecting }
                let v = try await pc.connect()
                connected = true
                status = .online(host: v.host ?? cfg.displayHost, gpu: v.gpu ?? "", worker: v.worker)
            }
            let list = try await pc.list()
            // Downloads made outside the app (the Claude connector) are recorded in the same defaults key.
            for (id, path) in UserDefaults.standard.dictionary(forKey: "downloaded") as? [String: String] ?? [:]
            where downloaded[id] == nil {
                downloaded[id] = path
            }
            pcVersions["main"]?.off = list.off
            jobsByPC["main"] = list.jobs.filter { $0.parent == nil }.map { var j = $0; j.pc = "main"; return j }  // batches show as their split job
            refreshJobs()
            if case .online(let host, let gpu, _) = status {
                status = .online(host: host, gpu: list.gpu?.isEmpty == false ? list.gpu! : gpu, worker: list.worker)
            }
            return 2
        } catch {
            connected = false
            status = .offline(error.localizedDescription)
            return 5
        }
    }

    /// A PC that's offline can't report its jobs finishing, so it doesn't hold the Mac awake.
    private func updateKeepAwake() {
        let busy = !uploads.isEmpty || !downloads.isEmpty || splits.isActive || (connected && pcJobs.contains(where: \.isActive))
        if cfg.keepAwake && busy {
            guard awakeActivity == nil else { return }
            awakeActivity = ProcessInfo.processInfo.beginActivity(options: .idleSystemSleepDisabled,
                                                                  reason: "BlenderRender is rendering")
        } else if let activity = awakeActivity {
            ProcessInfo.processInfo.endActivity(activity)
            awakeActivity = nil
        }
    }

    func reconnect() {
        connected = false
        startPolling()
    }

    func refreshSoon() { Task { _ = await poll(); await pollOtherPCs() } }

    private func notifyChanges(old: [PCJob], new: [PCJob]) {
        guard !old.isEmpty else { return }
        let before = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0.state ?? "") })
        for job in new where before[job.id] != nil && before[job.id] != job.state {
            switch job.state {
            case "done" where job.split == true:
                Notifier.shared.renderDone(job, gpu: "\(jobPCCount(job)) PCs", preview: nil)
                if let run = splits.run(job.id), let path = run.state.output {
                    downloaded[job.id] = path
                    UserDefaults.standard.set(downloaded, forKey: "downloaded")
                }
            case "done":
                if cfg.autoDownload && (job.files ?? 0) > 0 && downloaded[job.id] == nil { download(job, reveal: false) }
                let pc = rpc(for: job), gpu = job.pc == "main" || job.pc == nil ? currentGPU : pcVersions[job.pc!]?.gpu ?? ""
                Task {
                    let preview = await pc.previewThumbnail(job.id)
                    Notifier.shared.renderDone(job, gpu: gpu, preview: preview)
                }
            case "failed":
                Notifier.shared.renderFailed(job)
            default: break
            }
        }
    }

    private func jobPCCount(_ job: PCJob) -> Int { splits.run(job.id)?.state.pcs.count ?? 1 }

    private var currentGPU: String {
        if case .online(_, let gpu, _) = status { return gpu }
        return ""
    }

    // MARK: adding files

    func add(_ urls: [URL]) {
        for url in urls where url.pathExtension.lowercased() == "blend" {
            let up = Upload(file: url)
            uploads.append(up)
            let cfg = self.cfg
            Task {
                do {
                    let (packed, info) = try await Packer.packAndInspect(url, cfg: cfg)
                    update(up.id) { $0.phase = .waitingForSetup }
                    let anim = info.frame_end > info.frame_start && info.video
                    setups.append(JobSetup(id: up.id, packed: packed, info: info,
                                           name: url.deletingPathExtension().lastPathComponent,
                                           isAnimation: anim, frame: info.frame_current,
                                           start: info.frame_start, end: info.frame_end,
                                           pct: info.pct, samples: info.samples))
                } catch {
                    update(up.id) { $0.phase = .failed(error.localizedDescription) }
                }
            }
        }
    }

    func send(_ s: JobSetup) {
        setups.removeAll { $0.id == s.id }
        let pcs = splitPCs(blender: s.info.blender)
        if s.isAnimation && s.split && pcs.count >= 2 {
            uploads.removeAll { $0.id == s.id }
            do { try splits.start(s, pcs: pcs, cfg: cfg) } catch { alert = error.localizedDescription }
            return
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: s.packed.path)[.size] as? NSNumber)?.int64Value
        update(s.id) { $0.phase = .uploading; $0.transfer = Transfer(total: size) }
        var opts: [String: Any] = ["name": s.name, "mode": s.isAnimation ? "animation" : "still",
                                   "pct": s.pct, "samples": s.samples, "source": s.packed.lastPathComponent]
        if !cfg.keepAwake { opts["keep_awake"] = false }
        if s.isAnimation {
            opts["start"] = s.start; opts["end"] = s.end
            if s.fast { opts["step"] = JobSetup.fastStep; opts["fast"] = true }
        } else { opts["frame"] = s.frame }
        let target = singlePCs().first { $0.id == s.pc } ?? cfg.allPCs.first { $0.id == "main" }
        let pc = target.map { RenderPC(cfg: cfg.config(for: $0)) } ?? self.pc, id = s.id
        Task {
            do {
                _ = try await pc.submit(blend: s.packed, options: opts, progress: ByteMeter { n in
                    Task { @MainActor in self.update(id) { $0.transfer.update(n) } }
                }.callAsFunction)
                try? FileManager.default.removeItem(at: s.packed.deletingLastPathComponent())
                uploads.removeAll { $0.id == id }
                refreshSoon()
            } catch {
                update(id) { $0.phase = .failed(error.localizedDescription) }
            }
        }
    }

    func discard(_ s: JobSetup) {
        setups.removeAll { $0.id == s.id }
        uploads.removeAll { $0.id == s.id }
        try? FileManager.default.removeItem(at: s.packed.deletingLastPathComponent())
    }

    // MARK: requests from the Claude connector

    private struct InboxRequest: Decodable {
        let action: String
        var job: String?
        var name: String?
        var start: Int?
        var end: Int?
        var step: Int?
        var pct: Int?
        var samples: Int?
        var fast: Bool?
        var info: BlendInfo?
    }

    private var inbox: URL { Config.fileURL.deletingLastPathComponent().appendingPathComponent("inbox") }

    /// Each request is a folder from blenderrender_mcp.py. Renaming request.json claims it, so the
    /// connector can tell an app that's working on it from one that isn't there.
    private func checkInbox() {
        guard pcsChecked else { return }  // a split needs to know which PCs are online
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: inbox.path)) ?? [] {
            let dir = inbox.appendingPathComponent(name)
            let taken = dir.appendingPathComponent("taken.json")
            guard (try? fm.moveItem(at: dir.appendingPathComponent("request.json"), to: taken)) != nil else { continue }
            let request = (try? Data(contentsOf: taken)).flatMap { try? JSONDecoder().decode(InboxRequest.self, from: $0) }
            let reply = request.map { handle($0, in: dir) } ?? ["error": "BlenderRender couldn't read the request."]
            if let data = try? JSONSerialization.data(withJSONObject: reply) {
                try? data.write(to: dir.appendingPathComponent("reply.json"), options: .atomic)
            }
        }
    }

    private func handle(_ r: InboxRequest, in dir: URL) -> [String: Any] {
        switch r.action {
        case "split":
            guard let info = r.info, let start = r.start, let end = r.end else { return ["split": false] }
            let pcs = splitPCs(blender: info.blender)
            guard pcs.count >= 2 else { return ["split": false] }
            let s = JobSetup(id: UUID(), packed: dir.appendingPathComponent("input.blend"), info: info,
                             name: r.name ?? "Render", isAnimation: true, frame: info.frame_current, start: start, end: end,
                             pct: r.pct ?? info.pct, samples: r.samples ?? info.samples, fast: r.fast ?? false, step: r.step)
            do {
                return ["split": true, "job_id": try splits.start(s, pcs: pcs, cfg: cfg), "pcs": pcs.map(\.displayName)]
            } catch {
                return ["split": false, "error": error.localizedDescription]
            }
        case "cancel", "remove":
            guard let job = jobs.first(where: { $0.id == r.job }) else { return ["error": "No job \(r.job ?? "")."] }
            if r.action == "cancel" { cancel(job) } else { remove(job) }
            return ["ok": true]
        default:
            return ["error": "Unknown request \(r.action)."]
        }
    }

    /// Left behind by a connector that was stopped halfway; a live one finishes within minutes.
    private func clearOldInbox() {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: inbox.path)) ?? [] {
            let dir = inbox.appendingPathComponent(name)
            if let date = (try? fm.attributesOfItem(atPath: dir.path))?[.modificationDate] as? Date,
               date.timeIntervalSinceNow < -3600 {
                try? fm.removeItem(at: dir)
            }
        }
    }

    func dismissUpload(_ id: UUID) { uploads.removeAll { $0.id == id } }

    private func update(_ id: UUID, _ change: (inout Upload) -> Void) {
        if let i = uploads.firstIndex(where: { $0.id == id }) { change(&uploads[i]) }
    }

    // MARK: job actions

    func cancel(_ job: PCJob) {
        if let run = splits.run(job.id) { return run.cancel() }
        let pc = rpc(for: job)
        Task {
            do { try await pc.cancel(job.id) } catch { alert = error.localizedDescription }
            refreshSoon()
        }
    }

    func remove(_ job: PCJob) {
        if let run = splits.run(job.id) { return splits.remove(run) }
        let pc = rpc(for: job)
        Task {
            do { try await pc.delete(job.id) } catch { alert = error.localizedDescription }
            refreshSoon()
        }
    }

    /// `reveal`: select the folder in Finder when done (not for automatic downloads, which shouldn't pop up windows).
    func download(_ job: PCJob, reveal: Bool = true) {
        guard downloads[job.id] == nil else { return }
        downloads[job.id] = Transfer()
        let safe = job.displayName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let stamp = job.id.split(separator: "-").prefix(2).joined(separator: "-")
        let folder = URL(fileURLWithPath: cfg.downloadDir).appendingPathComponent("\(safe) \(stamp)")
        let pc = rpc(for: job)
        Task {
            defer { downloads[job.id] = nil }
            do {
                downloads[job.id]?.total = await pc.downloadSize(job.id)
                let id = job.id
                _ = try await pc.download(id, into: folder, progress: ByteMeter { n in
                    Task { @MainActor in self.downloads[id]?.update(n) }
                }.callAsFunction)
                downloaded[job.id] = folder.path
                UserDefaults.standard.set(downloaded, forKey: "downloaded")
                if reveal { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
            } catch {
                alert = "Download failed: \(error.localizedDescription)"
            }
        }
    }

    func reveal(_ job: PCJob) {
        guard let path = downloaded[job.id] else { return }
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        } else {
            downloaded[job.id] = nil
            UserDefaults.standard.set(downloaded, forKey: "downloaded")
        }
    }

    func log(_ job: PCJob) async -> String {
        if let run = splits.run(job.id) { return run.logText }
        do { return try await rpc(for: job).log(job.id) } catch { return error.localizedDescription }
    }
}
