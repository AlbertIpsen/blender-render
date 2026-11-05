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
    /// PCEntry ids: one gets the whole job; two or more share an animation's frames.
    var pcs: [String] = []
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
    /// BlenderRender computers heard on the local network, this Mac aside, by name.
    @Published private(set) var nearby: [Nearby] = []
    private lazy var discovery = Discovery { [weak self] in self?.heard($0) }

    /// Jobs waiting on this Mac for Start; those being started are hidden while they upload.
    private var held: [HeldJob] = HeldJob.loadAll()
    private var starting: Set<String> = []
    /// Last list from each PC, by PCEntry id; an unreachable PC keeps what it last reported.
    private var jobsByPC: [String: [PCJob]] = [:]
    private var pcJobs: [PCJob] { cfg.allPCs.flatMap { jobsByPC[$0.id] ?? [] } }
    private var otherPollTask: Task<Void, Never>?
    private lazy var splits = SplitManager { [weak self] in self?.refreshJobs() }
    private var pollTask: Task<Void, Never>?
    private var pcsChecked = false
    /// Held while the Mac must not idle to sleep; ending it hands sleep back to macOS.
    private var awakeActivity: NSObjectProtocol?

    /// When each computer last answered, by PCEntry id; the toolbar status counts those heard from lately.
    private var pcSeen: [String: Date] = [:]
    var rendering: [PCJob] { jobs.filter { $0.state == "rendering" } }
    /// Added, waiting for PCs to be chosen and Start: held on this Mac, or held on a PC (sent there directly).
    var waitingToStart: [PCJob] { jobs.filter { $0.state == "held" } }
    var upNext: [PCJob] { jobs.filter { $0.state == "queued" } }
    /// Changes whenever rows move between sections, so the list can animate it.
    var layoutKey: [String] { uploads.map(\.id.uuidString) + jobs.map { $0.id + ($0.state ?? "") } }

    /// Window subtitle: what the queue is doing right now.
    var summary: String {
        var parts: [String] = pausedAll ? ["Paused"] : []
        if !uploads.isEmpty { parts.append("\(uploads.count) sending") }
        if !downloads.isEmpty { parts.append("\(downloads.count) downloading") }
        if let job = rendering.first {
            let left = job.secondsLeft().flatMap(PCJob.timeLeft).map { " · " + $0 } ?? ""
            parts.append("\(rendering.count) rendering" + left)
        }
        if !upNext.isEmpty { parts.append("\(upNext.count) waiting") }
        if !waitingToStart.isEmpty { parts.append("\(waitingToStart.count) to start") }
        let ready = finished.filter { $0.state == "done" && downloaded[$0.id] == nil }.count
        if ready > 0 { parts.append("\(ready) ready to download") }
        return parts.isEmpty ? (cfg.isConfigured ? "Queue is empty" : "Not connected") : parts.joined(separator: " · ")
    }
    var finished: [PCJob] { jobs.filter { !$0.isActive && $0.state != "held" }.sorted { ($0.ended ?? $0.submitted ?? 0) > ($1.ended ?? $1.submitted ?? 0) } }

    init() {
        setenv("BR_FROM", RenderPC.fromName, 1)  // passed on to every rq call, see RenderPC.fromName
        Notifier.shared.setUp()
        Notifier.shared.onAction = { [weak self] id, action in self?.handleNotification(job: id, action: action) }
        startPolling()
        discovery.start()
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
        jobsByPC = [:]
        refreshJobs()
        startPolling()
        Task { await checkPCs() }
    }

    /// Check every PC, installing or updating the queue scripts as `connect` does.
    private func checkPCs() async {
        let cfg = self.cfg
        if let mac = cfg.allPCs.first(where: { $0.id == "mac" }) {
            // This Mac's queue keeps rqnet.py running, so other computers can find it.
            let rpc = RenderPC(cfg: cfg.config(for: mac))
            let v = try? await rpc.connect()
            try? await rpc.share(cfg.shareThisMac)
            if v?.agent == true { try? await rpc.ensureWorker() } else { try? await rpc.restartWorker() }
        }
        await withTaskGroup(of: (String, PCVersion?).self) { group in
            for pc in cfg.allPCs {
                group.addTask {
                    let rpc = RenderPC(cfg: cfg.config(for: pc))
                    var v = try? await rpc.connect()
                    // The worker keeps rqnet.py running, so other computers can find the PC: start it if it's stopped.
                    if pc.id != "mac", let got = v, !got.worker || got.agent == false {
                        try? await rpc.ensureWorker()
                        v = (try? await rpc.version()) ?? v
                    }
                    return (pc.id, v)
                }
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
                        version?.off = Self.isOff(list, pc)
                        return (pc.id, version, PCLive(jobs: list.jobs, stats: try? await rpc.stats(), seen: Date(), off: list.off == true,
                                                      paused: list.paused == true))
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

    /// Online, switched on, and on the same Blender major.minor as the file.
    func canShare(_ pc: PCEntry, blender: String) -> Bool {
        guard let v = pcVersions[pc.id], v.off != true else { return false }
        return Self.majorMinor(v.blender_version ?? "") == Self.majorMinor(blender)
    }

    /// Switched on when a job is added: the PCs the last job got, or every PC but this Mac the first
    /// time. A still renders on one.
    func defaultPCs(blender: String, animation: Bool) -> [String] {
        let available = singlePCs().map(\.id)
        var picked = (UserDefaults.standard.stringArray(forKey: Self.lastPCsKey) ?? []).filter(available.contains)
        if picked.isEmpty { picked = available.filter { $0 != "mac" } }
        if picked.isEmpty { picked = available }
        return animation ? picked : [picked.first ?? "mac"]
    }

    private static let lastPCsKey = "lastPCs"

    /// What Start used, as the next job's starting point.
    private func remember(_ pcs: [String]) {
        if !pcs.isEmpty { UserDefaults.standard.set(pcs, forKey: Self.lastPCsKey) }
    }

    // MARK: PCs of a split job that hasn't started

    func canChangePCs(_ job: PCJob) -> Bool { splits.run(job.id)?.notStarted ?? false }
    func splitPCIDs(_ job: PCJob) -> [String] { splits.run(job.id)?.state.pcs.map(\.id) ?? [] }
    func splitBlender(_ job: PCJob) -> String { splits.run(job.id)?.state.blender ?? "" }

    func setSplitPC(_ job: PCJob, _ pc: PCEntry, on: Bool) {
        guard let run = splits.run(job.id) else { return }
        var ids = run.state.pcs.map(\.id).filter { $0 != pc.id }
        if on { ids.append(pc.id) }
        run.setPCs(cfg.allPCs.filter { ids.contains($0.id) })
        refreshJobs()
    }

    private static func majorMinor(_ version: String) -> String {
        version.split(separator: ".").prefix(2).joined(separator: ".")
    }

    /// PCs a whole job can go to: the main one, and any other that's answering.
    func singlePCs() -> [PCEntry] {
        cfg.allPCs.filter { pcVersions[$0.id] != nil }
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
    // MARK: Computers on the network

    /// Switched off on the PC, or (found on the network) not taking jobs from other computers.
    nonisolated private static func isOff(_ list: PCList, _ pc: PCEntry?) -> Bool {
        list.off == true || (pc?.isNetwork == true && list.share == false)
    }

    private var ownNodeID: String? {
        (try? String(contentsOfFile: Config.thisMacDir + "/node_id", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func heard(_ n: Nearby) {
        // This Mac itself, or another queue running on it (a test): This Mac is already on the list.
        guard n.id != ownNodeID, !Discovery.ownAddresses().contains(n.host) else { return }
        if let i = nearby.firstIndex(where: { $0.id == n.id }) { nearby[i] = n } else {
            nearby.append(n)
            nearby.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        // A PC set up by address (SSH): talk to it over the network instead, once it runs the scripts this
        // app would give it (until then SSH is how it gets them).
        if n.version >= RenderPC.protocolVersion,
           let i = cfg.extraPCs.firstIndex(where: { $0.nodeID == nil && $0.testDir.isEmpty && $0.host == n.host }) {
            var c = cfg
            (c.extraPCs[i].nodeID, c.extraPCs[i].port) = (n.id, n.port)
            if c.extraPCs[i].name.isEmpty { c.extraPCs[i].name = n.name }
            saveConfig(c)
            return
        }
        // Its address changed (DHCP): keep the pool entry pointing at it.
        if let i = cfg.extraPCs.firstIndex(where: { $0.nodeID == n.id }),
           cfg.extraPCs[i].host != n.host || cfg.extraPCs[i].port != n.port {
            var c = cfg
            (c.extraPCs[i].host, c.extraPCs[i].port) = (n.host, n.port)
            saveConfig(c)
        }
    }

    /// The pool entry for a computer on the network: added from it, or the same address set up by SSH.
    func poolEntry(_ n: Nearby) -> PCEntry? {
        cfg.allPCs.first { $0.nodeID == n.id || (!$0.isNetwork && !n.host.isEmpty && $0.host == n.host) }
    }

    var nearbyToAdd: [Nearby] { nearby.filter { poolEntry($0) == nil } }

    func addToPool(_ n: Nearby) {
        guard poolEntry(n) == nil else { return }
        var c = cfg
        c.extraPCs.append(PCEntry(n))
        saveConfig(c)
    }

    /// "Allow this computer to do render jobs" on This Mac.
    func setShareThisMac(_ on: Bool) {
        cfg.shareThisMac = on
        cfg.save()
        guard let mac = cfg.allPCs.first(where: { $0.id == "mac" }) else { return }
        let rpc = RenderPC(cfg: cfg.config(for: mac))
        Task {
            try? await rpc.share(on)
            try? await rpc.ensureWorker()
        }
    }

    /// A PC's worker stopped (it also keeps rqnet.py running): start it, at most every 2 minutes.
    private var workerNudged: [String: Date] = [:]
    private func keepWorker(_ id: String, _ list: PCList) {
        guard !list.worker, id != "mac", Date().timeIntervalSince(workerNudged[id] ?? .distantPast) > 120,
              let pc = cfg.allPCs.first(where: { $0.id == id }) else { return }
        workerNudged[id] = Date()
        let rpc = RenderPC(cfg: cfg.config(for: pc))
        Task.detached { try? await rpc.ensureWorker() }
    }

    // MARK: Pause All

    /// Every PC freezes its render where it is and starts nothing new, until Resume All. Kept across
    /// launches, and a PC that was offline or added since gets it on the next poll.
    @Published private(set) var pausedAll = UserDefaults.standard.bool(forKey: "pausedAll")
    private var pauseSyncing: Set<String> = []

    func setPausedAll(_ on: Bool) {
        pausedAll = on
        UserDefaults.standard.set(on, forKey: "pausedAll")
        for pc in cfg.allPCs { syncPause(pc.id, reported: !on) }
    }

    /// Tell a PC to pause or resume when what it reports differs from Pause All.
    private func syncPause(_ id: String, reported: Bool) {
        guard reported != pausedAll, !pauseSyncing.contains(id),
              let pc = cfg.allPCs.first(where: { $0.id == id }) else { return }
        pauseSyncing.insert(id)
        let rpc = RenderPC(cfg: cfg.config(for: pc)), on = pausedAll
        Task {
            if on { try? await rpc.pause() } else { try? await rpc.resume() }
            pauseSyncing.remove(id)
            pcLive[id]?.paused = on
        }
    }

    private func rpc(for job: PCJob) -> RenderPC {
        let pc = cfg.allPCs.first { $0.id == job.pc } ?? cfg.allPCs[cfg.allPCs.count - 1]  // This Mac
        return RenderPC(cfg: cfg.config(for: pc))
    }

    private func refreshJobs() {
        let new = held.filter { !starting.contains($0.id) }.map(\.job) + pcJobs + splits.jobs
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

    /// Every computer's jobs, all at once, so one that's off or slow doesn't hold the others up.
    private func pollOtherPCs() async {
        let cfg = self.cfg
        let others = cfg.allPCs
        let results = await withTaskGroup(of: (String, PCList?).self) { group in
            for pc in others {
                group.addTask { (pc.id, try? await RenderPC(cfg: cfg.config(for: pc)).list()) }
            }
            return await group.reduce(into: [(String, PCList?)]()) { $0.append($1) }
        }
        guard cfg.allPCs == self.cfg.allPCs else { return }  // settings changed meanwhile
        for (id, list) in results {
            guard let list else { continue }
            pcSeen[id] = Date()
            pcVersions[id]?.off = Self.isOff(list, cfg.allPCs.first { $0.id == id })
            keepWorker(id, list)
            syncPause(id, reported: list.paused == true)
            let jobs = list.jobs
            jobsByPC[id] = jobs.filter { $0.parent == nil }.map { var j = $0; j.pc = id; return j }
        }
        for id in jobsByPC.keys where !others.contains(where: { $0.id == id }) { jobsByPC[id] = nil }
        nearby.removeAll { Date().timeIntervalSince($0.seen) > 20 }  // gone quiet: switched off or left
        refreshJobs()
    }

    /// The toolbar status, from what the computers last answered; returns seconds until the next look.
    private func poll() async -> Double {
        defer { updateKeepAwake() }
        // Downloads made outside the app (the Claude connector) are recorded in the same defaults key.
        for (id, path) in UserDefaults.standard.dictionary(forKey: "downloaded") as? [String: String] ?? [:]
        where downloaded[id] == nil {
            downloaded[id] = path
        }
        let pool = cfg.extraPCs
        guard !pool.isEmpty else { status = .notConfigured; return 2 }
        let answering = pool.filter { Date().timeIntervalSince(pcSeen[$0.id] ?? .distantPast) < 15 }
        let gpus = answering.compactMap { pcVersions[$0.id]?.gpu }.filter { !$0.isEmpty }
        if answering.isEmpty {
            status = pcSeen.isEmpty ? .connecting : .offline("None of your render computers answer.")
        } else {
            status = .online(host: answering.count == pool.count ? "\(pool.count) render computer\(pool.count == 1 ? "" : "s") ready"
                                                                 : "\(answering.count) of \(pool.count) render computers ready",
                             gpu: gpus.count == 1 ? gpus[0] : "", worker: true)
        }
        return 2
    }

    /// A PC that's offline can't report its jobs finishing, so it doesn't hold the Mac awake.
    private func updateKeepAwake() {
        let busy = !uploads.isEmpty || !downloads.isEmpty || splits.isActive || pcJobs.contains(where: \.isActive)
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
        startPolling()
        Task { await checkPCs() }
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
                let pc = rpc(for: job), gpu = job.pc.flatMap { pcVersions[$0]?.gpu } ?? ""
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
                                           pct: info.pct, samples: info.samples,
                                           pcs: defaultPCs(blender: info.blender, animation: anim)))
                } catch {
                    update(up.id) { $0.phase = .failed(error.localizedDescription) }
                }
            }
        }
    }

    /// "Add to Queue": the job waits for Start, with the PCs from the sheet ticked.
    func hold(_ s: JobSetup, source: String = "app") {
        setups.removeAll { $0.id == s.id }
        uploads.removeAll { $0.id == s.id }
        do {
            held.append(try HeldJob.create(s, source: source))
            try? FileManager.default.removeItem(at: s.packed.deletingLastPathComponent())
        } catch {
            alert = "Couldn't add \(s.name): \(error.localizedDescription)"
        }
        refreshJobs()
    }

    // MARK: render again

    /// A cancelled or failed job whose .blend is still there: on its PC, or on this Mac for a split job.
    func canRenderAgain(_ job: PCJob) -> Bool {
        guard job.state == "cancelled" || job.state == "failed", job.parent == nil else { return false }
        return job.split == true ? splits.run(job.id)?.keptBlend != nil : job.pc != nil
    }

    /// Back to Waiting to Start with the same settings: its PCs are chosen again and Start pressed.
    func renderAgain(_ job: PCJob) {
        let run = splits.run(job.id), kept = run?.keptBlend, split = run?.state
        let up = Upload(file: URL(fileURLWithPath: job.displayName + ".blend"))
        uploads.append(up)
        refreshJobs()
        let cfg = self.cfg, rpc = rpc(for: job)
        Task {
            let fetched = FileManager.default.temporaryDirectory.appendingPathComponent("blenderrender-again-\(UUID().uuidString).blend")
            defer { try? FileManager.default.removeItem(at: fetched) }
            do {
                if kept == nil { try await rpc.fetchBlend(job.id, into: fetched) }
                let (packed, info) = try await Packer.packAndInspect(kept ?? fetched, cfg: cfg)
                let animation = split != nil || job.mode == "animation"
                var s = JobSetup(id: up.id, packed: packed, info: info, name: split?.name ?? job.name ?? job.displayName,
                                 isAnimation: animation, frame: job.frame ?? job.start ?? info.frame_current,
                                 start: split?.start ?? job.start ?? info.frame_start, end: split?.end ?? job.end ?? info.frame_end,
                                 pct: split?.pct ?? job.pct ?? info.pct, samples: split?.samples ?? job.samples ?? info.samples,
                                 fast: split?.fast ?? false, step: split?.step ?? job.step)
                s.pcs = defaultPCs(blender: info.blender, animation: animation)
                hold(s)
            } catch {
                update(up.id) { $0.phase = .failed("Couldn't get the file back: " + error.localizedDescription) }
            }
        }
    }

    // MARK: waiting to start

    private func heldJob(_ job: PCJob) -> HeldJob? {
        guard job.held == true else { return nil }
        return held.first { "held-" + $0.id == job.id }
    }

    /// The PCs ticked for a job that waits for Start.
    func heldPCIDs(_ job: PCJob) -> [String] { heldJob(job)?.pcs ?? [] }
    func heldBlender(_ job: PCJob) -> String { heldJob(job)?.info.blender ?? "" }

    func setHeldPC(_ job: PCJob, _ pc: PCEntry, on: Bool) {
        guard let i = held.firstIndex(where: { "held-" + $0.id == job.id }) else { return }
        if !held[i].isAnimation { held[i].pcs = [pc.id] } else {
            held[i].pcs.removeAll { $0 == pc.id }
            if on { held[i].pcs.append(pc.id) }
        }
        try? held[i].save()
        refreshJobs()
    }

    /// Start: a held job goes to its PCs; one held on a PC is let go there.
    func start(_ job: PCJob) {
        if let h = heldJob(job) { return launch(h) }
        guard job.state == "held" else { return }
        let pc = rpc(for: job)
        Task {
            do { try await pc.release(job.id) } catch { alert = error.localizedDescription }
            refreshSoon()
        }
    }

    private func launch(_ h: HeldJob) {
        var s = h.setup
        if s.pcs.isEmpty { s.pcs = defaultPCs(blender: h.info.blender, animation: h.isAnimation) }
        if h.isAnimation { remember(s.pcs) }
        let chosen = cfg.allPCs.filter { s.pcs.contains($0.id) }
        let sharing = chosen.filter { canShare($0, blender: s.info.blender) }
        if s.isAnimation && sharing.count >= 2 {
            do {
                let id = try splits.start(s, pcs: sharing, cfg: cfg, id: h.id)
                h.started(as: id, on: nil)
                held.removeAll { $0.id == h.id }
            } catch { alert = error.localizedDescription }
            refreshJobs()
            return
        }
        guard let target = sharing.first ?? chosen.first ?? cfg.allPCs.first else { return }
        starting.insert(h.id)
        var up = Upload(file: URL(fileURLWithPath: h.name + ".blend"))
        let size = (try? FileManager.default.attributesOfItem(atPath: h.blend.path)[.size] as? NSNumber)?.int64Value
        up.phase = .uploading
        up.transfer = Transfer(total: size)
        uploads.append(up)
        refreshJobs()
        var opts: [String: Any] = ["name": s.name, "mode": s.isAnimation ? "animation" : "still",
                                   "pct": s.pct, "samples": s.samples, "source": h.blend.lastPathComponent]
        if !cfg.keepAwake { opts["keep_awake"] = false }
        if s.isAnimation {
            opts["start"] = s.start; opts["end"] = s.end
            let step = s.step ?? (s.fast ? JobSetup.fastStep : 1)
            if step > 1 { opts["step"] = step }
            if s.fast { opts["fast"] = true }
        } else { opts["frame"] = s.frame }
        opts["start_now"] = true
        let pc = RenderPC(cfg: cfg.config(for: target)), id = up.id
        Task {
            do {
                let job = try await pc.submit(blend: h.blend, options: opts, progress: ByteMeter { n in
                    Task { @MainActor in self.update(id) { $0.transfer.update(n) } }
                }.callAsFunction)
                h.started(as: job, on: target.id)
                held.removeAll { $0.id == h.id }
                uploads.removeAll { $0.id == id }
                refreshSoon()
            } catch {
                update(id) { $0.phase = .failed(error.localizedDescription) }
            }
            starting.remove(h.id)
            refreshJobs()
        }
    }

    func discard(_ s: JobSetup) {
        setups.removeAll { $0.id == s.id }
        uploads.removeAll { $0.id == s.id }
        try? FileManager.default.removeItem(at: s.packed.deletingLastPathComponent())
    }

    private func discardHeld(_ h: HeldJob, source: String) {
        CancelLog.write("remove held-\(h.id) (\(h.name), waiting to start) by \(source)")
        h.discard()
        held.removeAll { $0.id == h.id }
        refreshJobs()
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
        var mode: String?
        var frame: Int?
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
        case "hold", "split":  // "split": connectors from before held jobs; it waits for Start all the same
            guard let info = r.info else { return ["held": false, "split": false] }
            let animation = r.action == "split" || r.mode == "animation"
            let s = JobSetup(id: UUID(), packed: dir.appendingPathComponent("input.blend"), info: info,
                             name: r.name ?? "Render", isAnimation: animation, frame: r.frame ?? info.frame_current,
                             start: r.start ?? info.frame_start, end: r.end ?? info.frame_end,
                             pct: r.pct ?? info.pct, samples: r.samples ?? info.samples, fast: r.fast ?? false,
                             pcs: defaultPCs(blender: info.blender, animation: animation), step: r.step)
            do {
                let h = try HeldJob.create(s, source: "Claude")
                held.append(h)
                refreshJobs()
                let names = cfg.allPCs.filter { h.pcs.contains($0.id) }.map(pcName)
                return ["held": true, "split": true, "job_id": "held-" + h.id, "pcs": names]
            } catch {
                return ["held": false, "split": false, "error": error.localizedDescription]
            }
        case "cancel", "remove":
            guard let job = jobs.first(where: { $0.id == r.job }) else { return ["error": "No job \(r.job ?? "")."] }
            if r.action == "cancel" { cancel(job, source: "Claude connector") } else { remove(job, source: "Claude connector") }
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

    /// `source`: what asked (the Cancel button, the Claude connector…), written to cancel.log.
    func cancel(_ job: PCJob, source: String = "Cancel button") {
        if let h = heldJob(job) { return discardHeld(h, source: source) }
        if let run = splits.run(job.id) { return run.cancel(source: source) }
        CancelLog.write("cancel \(job.id) (\(job.displayName), \(job.state ?? "")) on \(job.pc ?? "main") by \(source)")
        let pc = rpc(for: job)
        Task {
            do { try await pc.cancel(job.id, by: source.replacingOccurrences(of: " ", with: "-")) } catch { alert = error.localizedDescription }
            refreshSoon()
        }
    }

    func remove(_ job: PCJob, source: String = "Remove button") {
        if let h = heldJob(job) { return discardHeld(h, source: source) }
        if let run = splits.run(job.id) { return splits.remove(run, source: source) }
        CancelLog.write("remove \(job.id) (\(job.displayName), \(job.state ?? "")) on \(job.pc ?? "main") by \(source)")
        let pc = rpc(for: job)
        Task {
            do { try await pc.delete(job.id, by: source.replacingOccurrences(of: " ", with: "-")) } catch { alert = error.localizedDescription }
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
