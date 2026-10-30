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
    /// Job whose Blender log sheet is open (from a row or a "Show Log" notification button).
    @Published var logRequest: PCJob?

    private var connected = false
    private var pollTask: Task<Void, Never>?

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
        jobs = []
        startPolling()
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
    }

    /// One refresh; returns seconds until the next one.
    private func poll() async -> Double {
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
            notifyChanges(old: jobs, new: list.jobs)
            jobs = list.jobs
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

    func reconnect() {
        connected = false
        startPolling()
    }

    func refreshSoon() { Task { _ = await poll() } }

    private func notifyChanges(old: [PCJob], new: [PCJob]) {
        guard !old.isEmpty else { return }
        let before = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0.state ?? "") })
        for job in new where before[job.id] != nil && before[job.id] != job.state {
            switch job.state {
            case "done":
                if cfg.autoDownload && (job.files ?? 0) > 0 && downloaded[job.id] == nil { download(job, reveal: false) }
                let pc = self.pc, gpu = currentGPU
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
        let size = (try? FileManager.default.attributesOfItem(atPath: s.packed.path)[.size] as? NSNumber)?.int64Value
        update(s.id) { $0.phase = .uploading; $0.transfer = Transfer(total: size) }
        var opts: [String: Any] = ["name": s.name, "mode": s.isAnimation ? "animation" : "still",
                                   "pct": s.pct, "samples": s.samples, "source": s.packed.lastPathComponent]
        if s.isAnimation { opts["start"] = s.start; opts["end"] = s.end } else { opts["frame"] = s.frame }
        let pc = self.pc, id = s.id
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

    func dismissUpload(_ id: UUID) { uploads.removeAll { $0.id == id } }

    private func update(_ id: UUID, _ change: (inout Upload) -> Void) {
        if let i = uploads.firstIndex(where: { $0.id == id }) { change(&uploads[i]) }
    }

    // MARK: job actions

    func cancel(_ job: PCJob) {
        let pc = self.pc
        Task {
            do { try await pc.cancel(job.id) } catch { alert = error.localizedDescription }
            refreshSoon()
        }
    }

    func remove(_ job: PCJob) {
        let pc = self.pc
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
        let pc = self.pc
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
        do { return try await pc.log(job.id) } catch { return error.localizedDescription }
    }
}
