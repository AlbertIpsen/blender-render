import SwiftUI

/// What a PC reported on the last look, for the Render PCs window.
struct PCLive {
    var jobs: [PCJob] = []
    var stats: PCStats?
    var error: String?
    /// When the PC last answered.
    var seen: Date?
}

/// The Render PCs window.
struct PCsView: View {
    var body: some View {
        ScrollView { PCCards().padding(16) }
            .frame(minWidth: 460, minHeight: 300)
    }
}

/// One live card per PC: its hardware, what it's rendering and what's waiting.
struct PCCards: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 12) {
            ForEach(state.cfg.allPCs) { pc in
                PCCard(pc: pc, version: state.pcVersions[pc.id], live: state.pcLive[pc.id],
                       batchesDone: state.splitBatchesDone(on: pc.id), speed: state.splitSpeed(on: pc.id), isMain: pc.id == "main")
            }
        }
        .task { await state.watchPCs() }
    }
}

struct PCCard: View {
    let pc: PCEntry
    let version: PCVersion?
    let live: PCLive?
    let batchesDone: Int
    let speed: Double?
    let isMain: Bool

    private var online: Bool { version != nil && live?.error == nil }
    private var active: [PCJob] {
        (live?.jobs ?? []).filter(\.isActive).sorted { ($0.state == "rendering" ? 0 : 1) < ($1.state == "rendering" ? 0 : 1) }
    }
    private var rendering: Bool { active.contains { $0.state == "rendering" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if online { hardware } else if let error = live?.error { offline(error) }
            if !active.isEmpty {
                Divider()
                ForEach(active) { line($0) }
            }
            if let history { Text(history).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 9, height: 9)
                Text(pc.name.isEmpty ? version?.host ?? pc.displayName : pc.displayName).font(.headline)
                Spacer()
                Text(status).font(.callout.weight(.medium)).foregroundStyle(online ? .primary : .secondary)
            }
            Text(identity).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    private var color: Color {
        if !online { return live == nil && version == nil ? .yellow : .red }
        return rendering ? .accentColor : .green
    }

    private var status: String {
        if !online { return live == nil ? "Checking…" : "Offline" }
        if rendering { return "Rendering" }
        return active.isEmpty ? "Ready" : "Starting…"
    }

    /// "192.168.1.130 · arthu · Blender 5.2.1 · Main PC · In splits"
    private var identity: String {
        var parts = [pc.host, pc.user]
        if let b = version?.blender_version, !b.isEmpty { parts.append("Blender " + b) }
        if isMain { parts.append("Main PC") }
        parts.append(pc.enabled ? "In splits" : "Not in splits")
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @ViewBuilder private var hardware: some View {
        let stats = live?.stats
        let name = stats?.gpu_name ?? version?.gpu ?? ""
        if !name.isEmpty {
            Text(Notifier.prettyGPU(name)).font(.callout)
        }
        if let text = Self.meters(stats) {
            Text(text).font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    /// "GPU 87% · 64 °C · VRAM 12.1 of 24.0 GB · 1.3 TB free"
    static func meters(_ s: PCStats?) -> String? {
        guard let s else { return nil }
        var parts: [String] = []
        if let v = s.gpu_load { parts.append("GPU \(Int(v))%") }
        if let v = s.gpu_temp { parts.append("\(Int(v.rounded())) °C") }
        if let u = s.vram_used, let t = s.vram_total {
            parts.append(String(format: "VRAM %.1f of %.1f GB", u / 1024, t / 1024))
        }
        if let v = s.disk_free {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(v), countStyle: .file) + " free")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func offline(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let seen = live?.seen {
                Text("Last seen at \(seen.formatted(date: .omitted, time: .shortened))").font(.callout)
            }
            Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }

    private func line(_ job: PCJob) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(job.displayName).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Spacer()
                if let left = job.secondsLeft().flatMap(PCJob.timeLeft) {
                    Text(left).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if job.state == "rendering" {
                ProgressView(value: job.progress ?? 0)
            }
            Text(detail(job)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private func detail(_ job: PCJob) -> String {
        let batch = job.parent == nil ? "" : "Split batch, frames \(job.start ?? 0)–\(job.end ?? 0) · "
        return batch + (job.state == "rendering" ? job.progressText : "Waiting")
    }

    /// "3 finished · 1 failed · 12 split batches done here"
    private var history: String? {
        let jobs = (live?.jobs ?? []).filter { $0.parent == nil }
        let done = jobs.filter { $0.state == "done" }.count, failed = jobs.filter { $0.state == "failed" }.count
        var parts: [String] = []
        if done > 0 { parts.append("\(done) finished") }
        if failed > 0 { parts.append("\(failed) failed") }
        if batchesDone > 0 { parts.append("\(batchesDone) split \(batchesDone == 1 ? "batch" : "batches") done here") }
        if let speed { parts.append(String(format: "%.1f s per frame", speed)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
