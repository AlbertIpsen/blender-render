import SwiftUI

/// What a PC reported on the last look, for the Render PCs window.
struct PCLive {
    var jobs: [PCJob] = []
    var stats: PCStats?
    var error: String?
    /// When the PC last answered.
    var seen: Date?
    /// Switched off for rendering on the PC itself.
    var off = false
    /// Pause All, from this Mac.
    var paused = false
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
                       splitDone: state.splitDone(on: pc.id), speed: state.splitSpeed(on: pc.id))
            }
            if !state.nearbyToAdd.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("On this network").font(.headline)
                    ForEach(state.nearbyToAdd) { n in NearbyRow(n: n) { state.addToPool(n) } }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.quaternary))
            }
        }
        .task { await state.watchPCs() }
    }
}

struct PCCard: View {
    let pc: PCEntry
    let version: PCVersion?
    let live: PCLive?
    let splitDone: (batches: Int, frames: Int)
    let speed: Double?

    private var online: Bool { version != nil && live?.error == nil }
    private var active: [PCJob] {
        (live?.jobs ?? []).filter(\.isActive).sorted { ($0.state == "rendering" ? 0 : 1) < ($1.state == "rendering" ? 0 : 1) }
    }
    private var rendering: Bool { active.contains { $0.state == "rendering" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if online { facts(machine) } else if let error = live?.error { offline(error) }
            if !active.isEmpty {
                Divider()
                ForEach(active) { line($0) }
            }
            if !history.isEmpty {
                Divider()
                facts(history)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }

    /// Label and value rows, so every number says what it is.
    private func facts(_ rows: [(String, String)]) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 3) {
            ForEach(rows, id: \.0) { label, value in
                GridRow {
                    Text(label).foregroundStyle(.secondary)
                    Text(value).monospacedDigit().textSelection(.enabled)
                }
            }
        }
        .font(.caption)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(pc.name.isEmpty ? version?.host ?? pc.displayName : pc.displayName).font(.headline)
            Spacer()
            Text(status).font(.callout.weight(.medium)).foregroundStyle(online ? .primary : .secondary)
        }
    }

    private var color: Color {
        if !online { return live == nil && version == nil ? .yellow : .red }
        if live?.paused == true || (live?.off == true && !rendering) { return .orange }
        return rendering ? .accentColor : .green
    }

    private var status: String {
        if !online { return live == nil ? "Checking…" : "Offline" }
        if live?.paused == true { return rendering ? "Paused mid-render" : "Paused" }
        if live?.off == true { return rendering ? "Rendering, switched off after this" : "Switched off on the PC" }
        if rendering { return "Rendering" }
        return active.isEmpty ? "Ready" : "Starting…"
    }

    /// The computer itself: where it is, its Blender, its graphics card and how busy it is.
    private var machine: [(String, String)] {
        var rows: [(String, String)] = []
        if !pc.host.isEmpty { rows.append(("Address", pc.user.isEmpty ? pc.host : "\(pc.host) (Windows user \(pc.user))")) }
        if let b = version?.blender_version, !b.isEmpty { rows.append(("Blender", b)) }
        let s = live?.stats
        let gpu = s?.gpu_name ?? version?.gpu ?? ""
        if !gpu.isEmpty { rows.append(("Graphics card", Notifier.prettyGPU(gpu))) }
        if let load = s?.gpu_load {
            rows.append(("GPU load", "\(Int(load))%" + (s?.gpu_temp.map { " at \(Int($0.rounded())) °C" } ?? "")))
        }
        if let u = s?.vram_used, let t = s?.vram_total {
            rows.append(("Video memory", String(format: "%.1f of %.1f GB in use", u / 1024, t / 1024)))
        }
        if let d = s?.disk_free {
            rows.append(("Free disk", ByteCountFormatter.string(fromByteCount: Int64(d), countStyle: .file)))
        }
        return rows
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
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text((job.state == "rendering" ? "Rendering " : "Next: ") + job.displayName)
                    .font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Spacer()
                if let left = job.secondsLeft().flatMap(PCJob.timeLeft) {
                    Text(left).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if job.state == "rendering" {
                ProgressView(value: job.progress ?? 0)
            }
            facts(rows(job))
        }
    }

    /// What it's doing on one job: its share of a split, and how far it is (no samples: frames say enough).
    private func rows(_ job: PCJob) -> [(String, String)] {
        var rows: [(String, String)] = []
        if job.parent != nil, let a = job.start, let b = job.end {
            let n = (b - a) / max(1, job.step ?? 1) + 1
            rows.append(("Its share", "frames \(a)–\(b) of the split job (\(n) frame\(n == 1 ? "" : "s"))"))
        }
        guard job.state == "rendering" else { return rows + [("Status", "waiting for the job before it")] }
        if job.mode == "animation", let f = job.frame, let a = job.start, let b = job.end {
            let step = max(1, job.step ?? 1)
            rows.append(("On frame", "\((f - a) / step + 1) of \((b - a) / step + 1) (frame \(f))"))
        }
        rows.append((job.parent != nil ? "Share done" : "Done", "\(Int((job.progress ?? 0) * 100))%"))
        return rows
    }

    /// Its record: frames it has done for the running split, its speed there, and jobs it has finished.
    private var history: [(String, String)] {
        var rows: [(String, String)] = []
        if splitDone.batches > 0 {
            rows.append(("Done for this split", "\(splitDone.frames) frame\(splitDone.frames == 1 ? "" : "s") in \(splitDone.batches) batch\(splitDone.batches == 1 ? "" : "es")"))
        }
        if let speed { rows.append(("Speed", String(format: "%.1f s per frame", speed))) }
        let jobs = (live?.jobs ?? []).filter { $0.parent == nil }
        let done = jobs.filter { $0.state == "done" }.count, failed = jobs.filter { $0.state == "failed" }.count
        if done + failed > 0 {
            rows.append(("Jobs finished here", "\(done)" + (failed > 0 ? " (\(failed) failed)" : "")))
        }
        return rows
    }
}

/// "Allow this computer to do render jobs": other BlenderRender computers may use This Mac's GPU.
struct ShareToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Allow this computer to do render jobs").font(.body.weight(.medium))
                Text("Other Macs with BlenderRender on this network can add this Mac to their render pool and render on its GPU.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
    }
}

/// A BlenderRender computer on the network that isn't in the pool yet.
struct NearbyRow: View {
    let n: Nearby
    let add: () -> Void

    private var detail: String {
        var parts = [n.isMac ? "Mac" : "PC"]
        if !n.gpuName.isEmpty { parts.append(n.gpuName) }
        if !n.blender.isEmpty { parts.append("Blender " + n.blender) }
        if !n.allow { parts.append("doesn't take render jobs now") } else if n.rendering { parts.append("rendering") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: n.isMac ? "desktopcomputer" : "pc").frame(width: 22).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(n.name)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Add", action: add)
        }
    }
}
