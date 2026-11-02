import Foundation

/// A job added to the queue that waits for its PCs to be chosen and Start to be pressed.
///
/// Kept on this Mac, so the PCs can still change: held/<id>/job.json (this) and input.blend (the
/// packed file). Start turns it into a split job (same id: "held-<id>" becomes "split-<id>") or sends
/// it whole to one PC, and the folder goes. The Claude connector adds jobs here too (inbox "hold").
struct HeldJob: Codable {
    let id: String
    var name: String
    let info: BlendInfo
    var isAnimation: Bool
    var frame: Int
    var start: Int
    var end: Int
    var pct: Int
    var samples: Int
    var fast: Bool
    var step: Int?
    /// PCEntry ids: one gets the whole job; two or more share an animation's frames.
    var pcs: [String]
    let submitted: Double
    /// "app" or "Claude", for the row.
    var source: String

    static var root: URL { Config.fileURL.deletingLastPathComponent().appendingPathComponent("held") }
    var dir: URL { Self.root.appendingPathComponent(id) }
    var blend: URL { dir.appendingPathComponent("input.blend") }
    /// Where Start records what became of it, for the connector's status (the folder itself goes).
    static var startedFile: URL { root.appendingPathComponent("started.json") }

    init(_ s: JobSetup, source: String) {
        id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        (name, info, isAnimation, frame, start, end) = (s.name, s.info, s.isAnimation, s.frame, s.start, s.end)
        (pct, samples, fast, step, pcs) = (s.pct, s.samples, s.fast, s.step, s.pcs)
        submitted = Date().timeIntervalSince1970
        self.source = source
    }

    /// Back into the shape `send` takes.
    var setup: JobSetup {
        JobSetup(id: UUID(), packed: blend, info: info, name: name, isAnimation: isAnimation, frame: frame,
                 start: start, end: end, pct: pct, samples: samples, fast: fast, pcs: pcs, step: step)
    }

    var job: PCJob {
        var j = PCJob(id: "held-" + id)
        j.name = name
        j.mode = isAnimation ? "animation" : "still"
        j.state = "held"
        j.start = isAnimation ? start : frame
        j.end = isAnimation ? end : frame
        j.frame = isAnimation ? nil : frame
        j.pct = pct
        j.samples = samples
        j.step = step ?? (fast ? JobSetup.fastStep : nil)
        j.submitted = submitted
        j.held = true
        return j
    }

    /// Moves the packed file in and saves.
    static func create(_ s: JobSetup, source: String) throws -> HeldJob {
        let h = HeldJob(s, source: source)
        try FileManager.default.createDirectory(at: h.dir, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: s.packed, to: h.blend)
        try h.save()
        return h
    }

    func save() throws {
        try JSONEncoder().encode(self).write(to: dir.appendingPathComponent("job.json"), options: .atomic)
    }

    static func loadAll() -> [HeldJob] {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).compactMap { name in
            let dir = root.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("job.json")),
                  let h = try? JSONDecoder().decode(HeldJob.self, from: data),
                  fm.fileExists(atPath: h.blend.path) else { return nil }
            return h
        }.sorted { $0.submitted < $1.submitted }
    }

    /// Note what it became ("split-<id>", or a job id on a PC) and drop the folder.
    func started(as jobID: String, on pc: String?) {
        var map = (try? Data(contentsOf: Self.startedFile))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        map[id] = ["job": jobID, "pc": pc ?? ""] as [String: Any]
        if let data = try? JSONSerialization.data(withJSONObject: map) { try? data.write(to: Self.startedFile, options: .atomic) }
        try? FileManager.default.removeItem(at: dir)
    }

    func discard() { try? FileManager.default.removeItem(at: dir) }
}
