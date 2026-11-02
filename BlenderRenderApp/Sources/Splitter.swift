import Foundation

/// A range of frames one PC renders in one go.
struct SplitBatch: Codable {
    let start: Int
    var end: Int
    var status = "pending"  // pending, running, done
    var pc: String?
    var jobID: String?
    var attempts = 0
}

/// One animation shared between PCs, saved after every change so it survives an app restart.
struct SplitState: Codable {
    let id: String
    let name: String
    let start: Int
    let end: Int
    let step: Int
    let pct: Int
    let samples: Int
    let fast: Bool
    let video: Bool
    let pcs: [PCEntry]
    let submitted: Double
    var state = "rendering"  // rendering, done, failed, cancelled
    var ended: Double?
    var error: String?
    var batches: [SplitBatch]
    var output: String?
    var files: Int?
    var log: [String] = []
    /// Measured seconds per frame, by PC id; each PC's next batch is cut to fit.
    var speeds: [String: Double]?

    var frameCount: Int { (end - start) / step + 1 }
    var framesDone: Int { batches.filter { $0.status == "done" }.reduce(0) { $0 + frames(in: $1) } }
    func frames(in b: SplitBatch) -> Int { (b.end - b.start) / step + 1 }
}

private struct BatchFailed: Error { let reason: String }
/// The PC was switched off on its own end before finishing the batch; not the batch's fault.
private struct HandedBack: Error {}

/// Runs one split job from this Mac, which works as the coordinator: a PC that's free asks for work
/// and gets a batch cut to its measured speed, so a faster GPU does more and no PC holds up the end
/// for long. Batches whose PC drops out go back in line for the others.
@MainActor
final class SplitRun {
    private(set) var state: SplitState
    private let cfg: Config
    private let onChange: () -> Void
    private var batchProgress: [Int: Double] = [:]
    private var activity: [String: String] = [:]
    /// Frames on their way back to this Mac, by PC, while that PC already renders its next batch.
    private var copying: [String: String] = [:]
    /// While this Mac joins the frames into the video: frames joined so far, and since when.
    private var joining: (done: Int, since: Date)?
    private var supervisor: Task<Void, Never>?
    /// PCs that failed too often and sit out the rest of this job.
    /// Whether a job ahead of this one in the queue still has frames for this PC.
    var workAhead: () -> Bool = { false }
    /// Batches in a row that a PC has to fail before it sits out the rest of the job.
    private static let pcFailureLimit = 2
    private static let attemptLimit = 3
    /// How long a PC may stay silent before its batch goes to another PC.
    private static let silenceLimit = 120.0
    /// How long a batch should keep a PC busy: longer saves reloading the file, shorter shares more evenly.
    private static let batchSeconds = 300.0
    /// Only light scenes reach this; it keeps one batch's frames to a sensible copy back to the Mac.
    /// At 0.2 s a frame, 60 was mostly opening the file and copying, not rendering.
    private static let maxBatchFrames = 1000
    private static let busy = "busy with another job"
    private static let off = "switched off on the PC"
    /// Until a PC has been measured.
    private static let firstBatchFrames = 2

    static var root: URL { Config.fileURL.deletingLastPathComponent().appendingPathComponent("splits") }
    private var dir: URL { Self.root.appendingPathComponent(state.id) }
    private var blend: URL { dir.appendingPathComponent("input.blend") }
    private var framesDir: URL { dir.appendingPathComponent("frames") }

    init(state: SplitState, cfg: Config, onChange: @escaping () -> Void) {
        self.state = state
        self.cfg = cfg
        self.onChange = onChange
    }

    /// Takes over `packed`, moving it into the job's folder, and starts rendering.
    func begin(packed: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: framesDir, withIntermediateDirectories: true)
        try fm.moveItem(at: packed, to: blend)
        save()
        resume()
    }

    func resume() {
        for i in state.batches.indices where state.batches[i].status == "running" {
            state.batches[i].status = "pending"  // the app quit mid-batch; workers clear what's left on the PCs
        }
        supervisor = Task {
            await withTaskGroup(of: Void.self) { group in
                for pc in state.pcs { group.addTask { await self.worker(pc) } }
            }
            await finish()
        }
    }

    func cancel() {
        guard state.state == "rendering" else { return }
        state.state = "cancelled"
        state.ended = Date().timeIntervalSince1970
        note("Cancelled")
        for pc in state.pcs { let rpc = rpc(pc), jobs = state.batches.filter { $0.pc == pc.id && $0.status == "running" }.compactMap(\.jobID), id = state.id
            Task {
                for job in jobs { try? await rpc.delete(job) }
                try? await rpc.cacheDrop(id)
            }
        }
        cleanUp()
        changed()
    }

    /// Every PC this job could still use, including those waiting for work.
    func nudgePCs() {
        guard cfg.keepAwake, running else { return }
        for pc in state.pcs { let rpc = rpc(pc); Task { try? await rpc.nudgeAwake() } }
    }

    func remove() {
        cancel()
        try? FileManager.default.removeItem(at: dir)
    }

    var logText: String { state.log.joined(separator: "\n") }

    /// How the job looks in the queue: the same row as a job on one PC.
    var job: PCJob {
        var j = PCJob(id: "split-" + state.id)
        j.name = state.name
        j.mode = "animation"
        j.state = isWaiting ? "queued" : state.state
        j.start = state.start
        j.end = state.end
        j.step = state.step
        j.pct = state.pct
        j.submitted = state.submitted
        j.started = state.submitted
        j.ended = state.ended
        j.error = state.error
        j.files = state.files
        j.split = true
        let done = Double(state.framesDone) + batchProgress.reduce(0.0) { $0 + $1.value * Double(state.frames(in: state.batches[$1.key])) }
        j.progress = state.state == "done" ? 1 : min(1, done / Double(state.frameCount))
        if let joining, state.state == "rendering" {
            let total = state.frameCount
            j.progress = Double(joining.done) / Double(max(total, 1))
            j.frame = state.start + joining.done * state.step  // past the first: "Estimating time left…"
            j.note = state.video ? "Joining the frames into the video on this Mac · \(joining.done) of \(total)"
                                 : "Moving the frames into the download folder"
            let now = Date().timeIntervalSince1970, spent = now - joining.since.timeIntervalSince1970
            if joining.done >= 10 {
                j.eta = spent / Double(joining.done) * Double(total - joining.done)
                j.eta_at = now
            }
            return j
        }
        if state.state == "rendering" && !isWaiting {
            let now = Date().timeIntervalSince1970
            if done >= 1 {
                j.eta = (now - state.submitted) / done * (Double(state.frameCount) - done)
                j.eta_at = now
            }
            let working = state.pcs.compactMap { pc -> String? in
                let doing = [activity[pc.id], copying[pc.id]].compactMap { $0 }
                return doing.isEmpty ? nil : "\(pc.displayName): " + doing.joined(separator: ", ")
            }
            j.note = (["\(state.framesDone) of \(state.frameCount) frames"] + working).joined(separator: " · ")
        }
        return j
    }

    /// Not started: every PC is on something else. Once frames are in, a pause doesn't move it back.
    private var isWaiting: Bool {
        running && state.framesDone == 0 && !state.batches.contains { $0.status == "running" }
            && activity.values.allSatisfy { $0 == Self.busy || $0 == Self.off }
    }

    /// True while any PC still has frames of this job to render; later jobs wait until then.
    var holdsPCs: Bool {
        running && state.batches.contains { $0.status != "done" }
    }

    // MARK: running

    private func rpc(_ pc: PCEntry) -> RenderPC { RenderPC(cfg: cfg.config(for: pc)) }
    private var running: Bool { state.state == "rendering" }
    private var allDone: Bool { state.batches.allSatisfy { $0.status == "done" } }

    private func note(_ line: String) {
        let f = DateFormatter()
        f.timeStyle = .medium
        state.log.append(f.string(from: Date()) + "  " + line)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: dir.appendingPathComponent("state.json"), options: .atomic)
    }

    private func changed() {
        save()
        onChange()
    }

    private func worker(_ pc: PCEntry) async {
        let rpc = rpc(pc)
        var ready = false, failures = 0
        var strays = state.batches.filter { $0.pc == pc.id && $0.status != "done" }.compactMap(\.jobID)
        // The PC starts its next batch while the last one's frames copy back; over Wi-Fi the copy
        // can take as long as the render. One copy at a time per PC.
        var copy: Task<Void, Never>?
        defer { activity[pc.id] = nil }
        while running && !allDone {
            guard state.batches.contains(where: { $0.status == "pending" }) else {
                try? await Task.sleep(for: .seconds(3))  // another PC might still hand one back
                continue
            }
            guard !workAhead() else {  // one job at a time, in queue order; this one doesn't even need the file yet
                activity[pc.id] = nil
                onChange()
                try? await Task.sleep(for: .seconds(3))
                continue
            }
            do {
                if !ready {
                    activity[pc.id] = "connecting"
                    changed()
                    _ = try await rpc.connect()
                    if try await !rpc.cacheHas(state.id) {
                        activity[pc.id] = "receiving the file"
                        changed()
                        try await rpc.cachePut(state.id, blend: blend)
                    }
                    ready = true
                }
                for job in strays { try? await rpc.delete(job) }
                strays = []
                // Pull, don't push: a batch queued behind other work would sit there while other PCs go idle.
                let list = try await rpc.list()
                if list.off == true {
                    if activity[pc.id] != Self.off {
                        activity[pc.id] = Self.off
                        changed()
                    }
                    try? await Task.sleep(for: .seconds(5))
                    continue
                }
                if list.jobs.contains(where: \.isActive) {
                    if activity[pc.id] != Self.busy {
                        activity[pc.id] = Self.busy
                        changed()
                    }
                    try? await Task.sleep(for: .seconds(5))
                    continue
                }
                guard running, let i = nextBatch(for: pc) else { continue }
                do {
                    let job = try await render(i, on: rpc, pc: pc)
                    failures = 0
                    activity[pc.id] = nil
                    await copy?.value
                    if let job { copy = Task { await self.copyBack(i, job: job, on: rpc, pc: pc) } }
                } catch is HandedBack {
                    batchProgress[i] = nil
                    release(i)
                    note("\(pc.displayName) was switched off; frames \(state.batches[i].start)-\(state.batches[i].end) go to another PC")
                } catch let e as BatchFailed {
                    batchProgress[i] = nil
                    failures += 1
                    state.batches[i].attempts += 1
                    release(i)
                    note("\(pc.displayName) failed frames \(state.batches[i].start)-\(state.batches[i].end): \(e.reason)")
                    if state.batches[i].attempts >= Self.attemptLimit {
                        fail("Frames \(state.batches[i].start)–\(state.batches[i].end) failed \(Self.attemptLimit) times: \(e.reason)")
                    } else if failures >= Self.pcFailureLimit {
                        note("\(pc.displayName) sits out the rest of this job")
                        activity[pc.id] = nil
                        changed()
                        await copy?.value
                        return
                    }
                } catch {
                    if let job = state.batches[i].jobID { strays.append(job) }
                    batchProgress[i] = nil
                    release(i)
                    throw error
                }
            } catch {
                ready = false
                if running {
                    activity[pc.id] = "offline, retrying"
                    note("\(pc.displayName): \(error.localizedDescription)")
                    changed()
                    try? await Task.sleep(for: .seconds(15))
                }
            }
        }
        await copy?.value
    }

    /// Copy a finished batch back; if that fails, its frames go back in line for any PC.
    private func copyBack(_ i: Int, job: String, on rpc: RenderPC, pc: PCEntry) async {
        let b = state.batches[i]
        copying[pc.id] = "copying frames \(b.start)–\(b.end) to this Mac"
        onChange()
        defer { copying[pc.id] = nil; onChange() }
        do {
            try await collect(i, job: job, on: rpc)
        } catch {
            guard running else { return }
            batchProgress[i] = nil
            if error is BatchFailed { state.batches[i].attempts += 1 } else { try? await rpc.delete(job) }
            release(i)
            note("Copying frames \(b.start)-\(b.end) from \(pc.displayName) failed: \((error as? BatchFailed)?.reason ?? error.localizedDescription)")
            if state.batches[i].attempts >= Self.attemptLimit {
                fail("Frames \(b.start)–\(b.end) failed \(Self.attemptLimit) times")
            }
        }
    }

    /// The next frames for `pc`: cuts them off the first pending batch and leaves the rest in line.
    private func nextBatch(for pc: PCEntry) -> Int? {
        guard let i = state.batches.firstIndex(where: { $0.status == "pending" }) else { return nil }
        let b = state.batches[i]
        let measured = state.speeds?[pc.id].map { Int(Self.batchSeconds / max($0, 0.01)) } ?? Self.firstBatchFrames
        let waiting = state.batches.filter { $0.status == "pending" }.reduce(0) { $0 + state.frames(in: $1) }
        let fairShare = Int((Double(waiting) / Double(state.pcs.count)).rounded(.up))
        let frames = max(1, min(measured, Self.maxBatchFrames, fairShare))
        if frames < state.frames(in: b) {
            let cut = b.start + frames * state.step
            state.batches[i].end = cut - state.step
            state.batches.append(SplitBatch(start: cut, end: b.end))
        }
        return i
    }

    private func release(_ i: Int) {
        state.batches[i].status = "pending"
        state.batches[i].pc = nil
        state.batches[i].jobID = nil
        changed()
    }

    private func fail(_ reason: String) {
        guard running else { return }
        state.state = "failed"
        state.error = reason
        state.ended = Date().timeIntervalSince1970
        note(reason)
        for pc in state.pcs { let rpc = rpc(pc), id = state.id; Task { try? await rpc.cacheDrop(id) } }
        cleanUp()
        changed()
    }

    /// Renders batch `i` on the PC; returns the PC's job id once it's done, nil if the split was cancelled.
    private func render(_ i: Int, on rpc: RenderPC, pc: PCEntry) async throws -> String? {
        let b = state.batches[i]
        state.batches[i].status = "running"
        state.batches[i].pc = pc.id
        activity[pc.id] = "frames \(b.start)–\(b.end)"
        changed()
        var opts: [String: Any] = ["name": state.name, "mode": "animation", "start": b.start, "end": b.end,
                                   "pct": state.pct, "samples": state.samples, "step": state.step,
                                   "frames_only": true, "parent": state.id, "blend": state.id]
        if state.fast { opts["fast"] = true }
        if !cfg.keepAwake { opts["keep_awake"] = false }
        let sent = Date()
        let job = try await rpc.submitBatch(options: opts)
        guard running else {  // cancelled while this was on its way, so cancel() didn't know its id
            try? await rpc.delete(job)
            return nil
        }
        state.batches[i].jobID = job
        changed()

        var lastHeard = Date()
        while running {
            do {
                let list = try await rpc.list()
                let found = list.jobs.first { $0.id == job }
                lastHeard = Date()
                if list.off == true && found?.state != "rendering" && found?.state != "done" {
                    try? await rpc.delete(job)
                    throw HandedBack()
                }
                switch found?.state {
                case "queued", "rendering":
                    batchProgress[i] = found?.progress ?? 0
                    onChange()
                case "done":
                    let perFrame = Date().timeIntervalSince(sent) / Double(state.frames(in: b))
                    var speeds = state.speeds ?? [:]
                    speeds[pc.id] = speeds[pc.id].map { ($0 + perFrame) / 2 } ?? perFrame
                    state.speeds = speeds
                    batchProgress[i] = 1
                    changed()
                    return job
                case "failed":
                    let tail = (try? await rpc.log(job)).flatMap { $0.split(separator: "\n").last.map(String.init) }
                    try? await rpc.delete(job)
                    throw BatchFailed(reason: found?.error ?? tail ?? "Blender stopped")
                default:
                    throw BatchFailed(reason: "the job disappeared from the PC")
                }
            } catch let e as BatchFailed {
                throw e
            } catch let e as HandedBack {
                throw e
            } catch {
                if Date().timeIntervalSince(lastHeard) > Self.silenceLimit { throw error }
            }
            try await Task.sleep(for: .seconds(2))
        }
        return nil
    }

    /// Fetch a finished batch, count its frames and clear it off the PC.
    private func collect(_ i: Int, job: String, on rpc: RenderPC) async throws {
        let fm = FileManager.default
        let incoming = dir.appendingPathComponent("incoming-\(job)")
        defer { try? fm.removeItem(at: incoming) }
        _ = try await rpc.download(job, into: incoming)
        guard running else { return }
        let files = try fm.contentsOfDirectory(atPath: incoming.path).filter { $0 != "log.txt" }
        let expected = state.frames(in: state.batches[i])
        guard files.count == expected else {
            try? await rpc.delete(job)
            throw BatchFailed(reason: "got \(files.count) of \(expected) frames")
        }
        for f in files {
            let dst = framesDir.appendingPathComponent(f)
            try? fm.removeItem(at: dst)
            try fm.moveItem(at: incoming.appendingPathComponent(f), to: dst)
        }
        try? await rpc.delete(job)
        batchProgress[i] = nil
        state.batches[i].status = "done"
        changed()
    }

    private func finish() async {
        guard running else { return }
        guard allDone else { return fail("No PC could finish the job. Open the log for details.") }
        for pc in state.pcs { try? await rpc(pc).cacheDrop(state.id) }
        activity = [:]
        joining = (0, Date())
        changed()
        defer { joining = nil }
        let safe = state.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let folder = URL(fileURLWithPath: cfg.downloadDir).appendingPathComponent("\(safe) \(f.string(from: Date()))")
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            if state.video {
                try await assemble(into: folder)
            } else {
                for name in try fm.contentsOfDirectory(atPath: framesDir.path) {
                    try fm.moveItem(at: framesDir.appendingPathComponent(name), to: folder.appendingPathComponent(name))
                }
            }
            state.files = try fm.contentsOfDirectory(atPath: folder.path).count
            state.output = folder.path
            state.state = "done"
            state.ended = Date().timeIntervalSince1970
            note("Finished: \(folder.path)")
            cleanUp()
            changed()
        } catch {
            activity = [:]
            state.state = "failed"
            state.error = "Couldn't join the frames: \(error.localizedDescription)"
            state.ended = Date().timeIntervalSince1970
            note(state.error ?? "")
            changed()  // the frames stay in the job's folder, so nothing rendered is lost
        }
    }

    private func assemble(into folder: URL) async throws {
        guard let script = Bundle.main.resourceURL?.appendingPathComponent("assemble_video.py") else {
            throw ShellError(message: "assemble_video.py missing from the app bundle")
        }
        let progress = dir.appendingPathComponent("join_progress")
        let json = try JSONSerialization.data(withJSONObject: ["name": state.name, "start": state.start, "step": state.step,
                                                               "pct": state.pct, "progress": progress.path] as [String: Any])
        let watch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if let text = try? String(contentsOf: progress, encoding: .utf8), let n = Int(text), let self {
                    self.joining?.done = n
                    self.onChange()
                }
            }
        }
        defer { watch.cancel(); try? FileManager.default.removeItem(at: progress) }
        let b64 = json.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        _ = try await Shell.run(cfg.macBlender, ["-b", blend.path, "--factory-startup", "-P", script.path,
                                                 "--", framesDir.path, folder.path, b64])
    }

    private func cleanUp() {
        activity = [:]
        batchProgress = [:]
        let fm = FileManager.default
        try? fm.removeItem(at: blend)
        try? fm.removeItem(at: framesDir)
    }
}

/// Every split job on this Mac, finished ones included until they're removed.
@MainActor
final class SplitManager {
    private(set) var runs: [SplitRun] = []
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) { self.onChange = onChange }

    var jobs: [PCJob] { runs.map(\.job) }
    var isActive: Bool { runs.contains { $0.state.state == "rendering" } }
    func nudgePCs() { runs.forEach { $0.nudgePCs() } }
    func run(_ jobID: String) -> SplitRun? { runs.first { $0.job.id == jobID } }

    private func make(_ state: SplitState, cfg: Config) -> SplitRun {
        let run = SplitRun(state: state, cfg: cfg, onChange: onChange)
        run.workAhead = { [weak self, unowned run] in
            self?.runs.contains { $0 !== run && $0.state.submitted < run.state.submitted && $0.holdsPCs } ?? false
        }
        return run
    }

    /// Pick up jobs from a previous launch; unfinished ones carry on where they stopped.
    func restore(cfg: Config) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: SplitRun.root.path)) ?? [] {
            let file = SplitRun.root.appendingPathComponent(name).appendingPathComponent("state.json")
            guard let data = try? Data(contentsOf: file), let state = try? JSONDecoder().decode(SplitState.self, from: data) else { continue }
            runs.append(make(state, cfg: cfg))
        }
        runs.sort { $0.state.submitted < $1.state.submitted }
        for run in runs where run.state.state == "rendering" { run.resume() }
    }

    /// Returns the new job's id.
    @discardableResult func start(_ s: JobSetup, pcs: [PCEntry], cfg: Config) throws -> String {
        let step = s.step ?? (s.fast ? JobSetup.fastStep : 1)
        let state = SplitState(id: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
                               name: s.name, start: s.start, end: s.end, step: step, pct: s.pct, samples: s.samples,
                               fast: s.fast, video: s.info.video, pcs: pcs, submitted: Date().timeIntervalSince1970,
                               batches: [SplitBatch(start: s.start, end: s.end)])
        let run = make(state, cfg: cfg)
        runs.append(run)
        try run.begin(packed: s.packed)
        onChange()
        return run.job.id
    }

    func remove(_ run: SplitRun) {
        run.remove()
        runs.removeAll { $0 === run }
        onChange()
    }
}
