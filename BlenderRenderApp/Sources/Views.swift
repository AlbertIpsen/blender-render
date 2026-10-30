import SwiftUI
import UniformTypeIdentifiers

// Motion: critically damped springs for UI state (no overshoot – nothing here is flicked),
// replaced by plain cross-fades when Reduce Motion is on.
extension Animation {
    static let ui = Animation.spring(response: 0.35, dampingFraction: 1)
}

private func uiAnimation(_ reduceMotion: Bool) -> Animation { reduceMotion ? .easeInOut(duration: 0.2) : .ui }

// MARK: - Window

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var picking = Box(false)
    @StateObject private var dropTargeted = Box(false)

    var body: some View {
        content
            .frame(minWidth: 620, minHeight: 460)
            .overlay { if dropTargeted.value { DropOverlay(host: state.cfg.displayHost).transition(dropTransition) } }
            .animation(uiAnimation(reduceMotion), value: dropTargeted.value)
            .dropDestination(for: URL.self) { urls, _ in
                state.add(urls)
                return urls.contains { $0.pathExtension.lowercased() == "blend" }
            } isTargeted: { dropTargeted.value = $0 }
            .toolbar {
                ToolbarItem(placement: .automatic) { ConnectionPill() }
                ToolbarItem(placement: .primaryAction) {
                    Button { picking.value = true } label: { Label("Add Files", systemImage: "plus") }
                        .help("Add .blend files to the render queue")
                        .disabled(!state.cfg.isConfigured)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { if state.update != nil { UpdateBanner() } }
            .animation(uiAnimation(reduceMotion), value: state.update)
            .navigationTitle("BlenderRender")
            .navigationSubtitle(state.summary)
            .sheet(item: Binding(get: { state.setups.first }, set: { _ in })) { SetupSheet(setup: $0) }
            .sheet(item: $state.logRequest) { LogView(job: $0) }
            .sheet(isPresented: $state.showGuide) { GuideView() }
            .fileImporter(isPresented: $picking.value, allowedContentTypes: [UTType(filenameExtension: "blend") ?? .data],
                          allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { state.add(urls) }
            }
            .alert("BlenderRender", isPresented: Binding(get: { state.alert != nil }, set: { if !$0 { state.alert = nil } })) {
                Button("OK") { state.alert = nil }
            } message: { Text(state.alert ?? "") }
            .onOpenURL { state.add([$0]) }
    }

    // The overlay materializes (scale + fade together) rather than just fading in.
    private var dropTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97))
    }

    @ViewBuilder private var content: some View {
        if !state.cfg.isConfigured {
            SetUpPCView()
        } else if state.uploads.isEmpty && state.jobs.isEmpty {
            EmptyQueueView(choose: { picking.value = true })
        } else {
            JobList(logJob: $state.logRequest)
        }
    }
}

/// Full-window drop target shown while a file is dragged over the window.
struct UpdateBanner: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
            Text("BlenderRender \(state.update?.version ?? "") is available").font(.callout.weight(.medium))
            Spacer()
            if state.installingUpdate { ProgressView().controlSize(.small) }
            Button("Later") { state.update = nil }.disabled(state.installingUpdate)
            Button("Update & Restart") { state.installUpdate() }
                .buttonStyle(.borderedProminent).disabled(state.installingUpdate)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct DropOverlay: View {
    let host: String

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .padding(16)
            VStack(spacing: 10) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 44, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                Text("Drop to Render")
                    .font(.title2.weight(.semibold)).tracking(-0.3)
                Text("Textures are packed on this Mac, then the file renders on \(host).")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .allowsHitTesting(false)
    }
}

struct EmptyQueueView: View {
    @EnvironmentObject var state: AppState
    let choose: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Drop .blend Files to Render", systemImage: "square.and.arrow.down.on.square")
        } description: {
            Text("Each file renders on \(state.cfg.displayHost) with its own camera and render settings. When it's done, download the images here.")
        } actions: {
            Button("Choose Files…", action: choose).buttonStyle(.borderedProminent).controlSize(.large)
        }
    }
}

struct SetUpPCView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        ContentUnavailableView {
            Label("Connect Your Render PC", systemImage: "desktopcomputer.and.arrow.down")
        } description: {
            Text("BlenderRender sends your .blend files to a Windows PC with an NVIDIA GPU. Setting one up takes about 10 minutes.")
        } actions: {
            Button("Show Setup Guide") { state.showGuide = true }.buttonStyle(.borderedProminent).controlSize(.large)
            Button("I've Already Run the Script – Open Settings") { openSettings() }.buttonStyle(.link)
        }
    }
}

// MARK: - Connection status (toolbar)

struct ConnectionPill: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openSettings) private var openSettings
    @StateObject private var showing = Box(false)

    var body: some View {
        Button { showing.value.toggle() } label: {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                    .shadow(color: color.opacity(0.6), radius: 3)
                Text(short).font(.callout.weight(.medium))
            }
            .padding(.horizontal, 4)
        }
        .help("Render PC status")
        .popover(isPresented: $showing.value, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Label(title, systemImage: "desktopcomputer").font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                if state.cfg.allPCs.count > 1 {
                    Divider()
                    ForEach(state.cfg.allPCs) { pc in
                        Label(pc.displayName, systemImage: state.pcVersions[pc.id] == nil ? "circle" : "circle.fill")
                            .font(.callout).foregroundStyle(state.pcVersions[pc.id] == nil ? .secondary : .primary)
                    }
                }
                Divider()
                HStack {
                    Button("Reconnect") { state.reconnect(); showing.value = false }
                    Button("Setup Guide") { state.showGuide = true; showing.value = false }
                    Spacer()
                    Button("Settings…") { openSettings(); showing.value = false }
                }
            }
            .padding(16)
            .frame(width: 320)
        }
    }

    private var color: Color {
        switch state.status {
        case .online: return .green  // an idle worker is fine: it starts with the next job
        case .connecting: return .yellow
        case .offline, .notConfigured: return .red
        }
    }
    private var short: String {
        switch state.status {
        case .online: return state.rendering.isEmpty ? "Ready to Render" : "Rendering"
        case .connecting: return "Connecting…"
        case .offline: return "Offline"
        case .notConfigured: return "Not Set Up"
        }
    }
    private var title: String {
        switch state.status {
        case .online(let host, _, _): return host
        case .connecting: return "Connecting to \(state.cfg.displayHost)"
        case .offline: return "Can't reach \(state.cfg.displayHost)"
        case .notConfigured: return "No render PC yet"
        }
    }
    private var detail: String {
        switch state.status {
        case .online(_, let gpu, let worker):
            let g = gpu.isEmpty ? "GPU shows after the first render." : Notifier.prettyGPU(gpu)
            return g + "\n" + (worker ? "Queue is running." : "Queue is idle; it starts with the next job.")
        case .connecting: return "Checking the render queue on the PC."
        case .offline(let why): return "Is the PC on and awake?\n\n" + why
        case .notConfigured: return "Enter the PC's address and Windows user in Settings."
        }
    }
}

// MARK: - Queue

struct JobList: View {
    @EnvironmentObject var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var logJob: PCJob?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if !state.uploads.isEmpty || !state.rendering.isEmpty {
                    group("Now Rendering", uploads: state.uploads, jobs: state.rendering, numbered: false)
                }
                if !state.upNext.isEmpty {
                    group("Up Next", uploads: [], jobs: state.upNext, numbered: true)
                }
                if !state.finished.isEmpty {
                    group("Finished", uploads: [], jobs: state.finished, numbered: false)
                }
            }
            .padding(20)
        }
        .animation(uiAnimation(reduceMotion), value: state.layoutKey)
    }

    /// Inset grouped container (as in System Settings): a section label over one rounded surface,
    /// rows separated by hairlines that start at the text, not the glyph.
    private func group(_ title: String, uploads: [Upload], jobs: [PCJob], numbered: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 4)
            VStack(spacing: 0) {
                ForEach(Array(uploads.enumerated()), id: \.element.id) { i, up in
                    if i > 0 { Divider().padding(.leading, 50) }
                    UploadRow(upload: up)
                }
                ForEach(Array(jobs.enumerated()), id: \.element.id) { i, job in
                    if i > 0 || !uploads.isEmpty { Divider().padding(.leading, 50) }
                    JobRow(job: job, position: numbered ? i + 1 : nil, logJob: $logJob)
                }
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
        }
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
    }
}

/// Leading status glyph shared by uploads and jobs; same size everywhere so rows align.
struct StatusGlyph: View {
    enum Kind { case progress(Double), busy, queued(Int), done, failed, cancelled }
    let kind: Kind

    var body: some View {
        ZStack {
            switch kind {
            case .progress(let p):
                Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 3)
                Circle().trim(from: 0, to: max(0.02, p))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.ui, value: p)
            case .busy:
                ProgressView().controlSize(.small)
            case .queued(let n):
                Image(systemName: n <= 50 ? "\(n).circle" : "clock").font(.system(size: 20)).foregroundStyle(.secondary)
            case .done:
                Image(systemName: "checkmark.circle.fill").font(.system(size: 20)).foregroundStyle(.green)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 18)).foregroundStyle(.orange)
            case .cancelled:
                Image(systemName: "minus.circle").font(.system(size: 20)).foregroundStyle(.tertiary)
            }
        }
        .frame(width: 24, height: 24)
    }
}

struct UploadRow: View {
    @EnvironmentObject var state: AppState
    let upload: Upload

    var body: some View {
        HStack(spacing: 12) {
            StatusGlyph(kind: glyph)
            VStack(alignment: .leading, spacing: 3) {
                Text(upload.file.deletingPathExtension().lastPathComponent).font(.body.weight(.semibold))
                Text(detail).font(.callout).foregroundStyle(isFailed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(3).textSelection(.enabled).monospacedDigit()
            }
            Spacer(minLength: 12)
            if isFailed { Button("Dismiss") { state.dismissUpload(upload.id) }.controlSize(.small) }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var isFailed: Bool { if case .failed = upload.phase { return true } else { return false } }
    private var glyph: StatusGlyph.Kind {
        switch upload.phase {
        case .uploading: return .progress(upload.transfer.fraction ?? 0)
        case .failed: return .failed
        default: return .busy
        }
    }
    private var detail: String {
        switch upload.phase {
        case .packing: return "Packing textures on this Mac…"
        case .waitingForSetup: return "Choose render options…"
        case .uploading:
            let t = upload.transfer
            return "Sending to the render PC · " + (t.fraction.map { "\(Int($0 * 100))% · " } ?? "") + t.text
        case .failed(let msg): return msg
        }
    }
}

/// Bar and "Downloading · 42% · 45 MB of 120 MB · 12 MB/s · 8 s left" under a job being downloaded.
struct DownloadProgress: View {
    let transfer: Transfer

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let f = transfer.fraction {
                ProgressView(value: f).progressViewStyle(.linear).tint(.accentColor).animation(.ui, value: f)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            Text(text).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                .contentTransition(.numericText())
        }
    }

    private var text: String {
        if transfer.total == nil && transfer.done == 0 { return "Starting download…" }
        if let f = transfer.fraction, f >= 1 { return "Unpacking…" }
        return "Downloading · " + (transfer.fraction.map { "\(Int($0 * 100))% · " } ?? "") + transfer.text
    }
}

struct JobRow: View {
    @EnvironmentObject var state: AppState
    let job: PCJob
    let position: Int?
    @Binding var logJob: PCJob?
    @StateObject private var confirmRemove = Box(false)
    @StateObject private var hovering = Box(false)

    var body: some View {
        HStack(spacing: 12) {
            StatusGlyph(kind: glyph)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(job.displayName).font(.body.weight(.semibold)).lineLimit(1)
                    Text(kind).font(.caption).foregroundStyle(.secondary)
                }
                if job.state == "rendering" {
                    ProgressView(value: job.progress ?? 0)
                        .progressViewStyle(.linear).tint(.accentColor)
                        .animation(.ui, value: job.progress ?? 0)
                    // Time left leads (it's what you want to know); ticks every second between PC updates.
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(job.timeLeftText(at: ctx.date) ?? (job.mode == "animation" && (job.frame ?? 0) <= (job.start ?? 1)
                                                                ? "Estimating time left after the first frame…"
                                                                : "Estimating time left…"))
                            .font(.callout.weight(.medium)).monospacedDigit()
                            .contentTransition(.numericText())
                    }
                }
                Text(detail).font(.callout).monospacedDigit()
                    .foregroundStyle(job.state == "failed" ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
                if let t = state.downloads[job.id] { DownloadProgress(transfer: t) }
            }
            Spacer(minLength: 12)
            secondaryActions.opacity(hovering.value ? 1 : 0)
            primaryAction
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering.value = h } }
        .contextMenu {
            if job.isActive { Button("Cancel Render") { state.cancel(job) } }
            if (job.files ?? 0) > 0 { Button("Download") { state.download(job) } }
            if state.downloaded[job.id] != nil { Button("Show in Finder") { state.reveal(job) } }
            Button("Show Blender Log") { logJob = job }
            Divider()
            Button(job.split == true ? "Remove…" : "Remove from Render PC…", role: .destructive) { confirmRemove.value = true }
        }
        .confirmationDialog(job.split == true ? "Remove “\(job.displayName)”?" : "Remove “\(job.displayName)” from the render PC?",
                            isPresented: $confirmRemove.value) {
            Button("Remove", role: .destructive) { state.remove(job) }
        } message: {
            Text(job.split == true ? (job.isActive ? "The render stops on every PC and its frames are deleted." : "Downloads on this Mac are kept.")
                 : job.isActive ? "The render stops and its files on the PC are deleted."
                              : "Its files on the PC are deleted. Downloads on this Mac are kept.")
        }
    }

    @ViewBuilder private var primaryAction: some View {
        if job.isActive {
            Button("Cancel") { state.cancel(job) }.controlSize(.small)
        } else if (job.files ?? 0) > 0 {
            if state.downloads[job.id] != nil {
                EmptyView()
            } else if state.downloaded[job.id] != nil {
                Button { state.reveal(job) } label: { Label("Show in Finder", systemImage: "folder") }
                    .controlSize(.small)
            } else {
                Button { state.download(job) } label: { Label("Download", systemImage: "arrow.down.circle.fill") }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
        }
    }

    // Secondary actions stay out of the way until the pointer is on the row; all are also in the context menu.
    private var secondaryActions: some View {
        HStack(spacing: 2) {
            if state.downloaded[job.id] != nil {
                iconButton("arrow.down.circle", "Download again") { state.download(job) }
            }
            iconButton("doc.text.magnifyingglass", "Show Blender log") { logJob = job }
            iconButton("trash", "Remove from render PC") { confirmRemove.value = true }
        }
    }

    private func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 24, height: 22) }
            .buttonStyle(.borderless).foregroundStyle(.secondary).help(help)
    }

    private var glyph: StatusGlyph.Kind {
        switch job.state {
        case "rendering": return .progress(job.progress ?? 0)
        case "queued": return .queued(position ?? 1)
        case "done": return .done
        case "failed": return .failed
        default: return .cancelled
        }
    }

    private var kind: String {
        var parts = [job.mode == "animation" ? "Frames \(job.start ?? 0)–\(job.end ?? 0)" : "Still"]
        if job.split == true { parts.append("Split across PCs") }
        if let n = job.step, n > 1 { parts.append("Fast preview (every \(n)th)") }
        if let p = job.pct { parts.append("\(p)%") }
        return parts.joined(separator: " · ")
    }

    private var detail: String {
        switch job.state {
        case "rendering":
            if let note = job.note { return note }
            var parts: [String] = []
            if job.mode == "animation", let f = job.frame, let s = job.start, let e = job.end {
                let n = max(1, job.step ?? 1)
                parts.append("Frame \((f - s) / n + 1) of \((e - s) / n + 1)")
            }
            if let s = job.sample, let n = job.samples { parts.append("Sample \(s) of \(n)") }
            parts.append("\(Int((job.progress ?? 0) * 100))%")
            return parts.joined(separator: " · ")
        case "queued":
            return position == 1 ? "Starts next" : "Waiting · \(position ?? 0) in line"
        case "done":
            let n = job.files ?? 0
            return job.outputSummary + " ready" + took
        case "failed":
            return (job.error ?? "Render failed – open the Blender log for details")
                + ((job.files ?? 0) > 0 ? " · partial results" : "")
        case "cancelled":
            return "Cancelled" + ((job.files ?? 0) > 0 ? " · partial results" : "")
        default:
            return job.state ?? ""
        }
    }

    private var took: String {
        guard let s = job.started, let e = job.ended else { return "" }
        return " · rendered in " + Self.duration(Int(e - s))
    }

    static func duration(_ secs: Int) -> String {
        secs >= 3600 ? "\(secs / 3600) h \(secs % 3600 / 60) min" : secs >= 60 ? "\(secs / 60) min \(secs % 60) s" : "\(secs) s"
    }

    /// Cycles' "01:23.45" / "1:02:03.40" → "1 min 23 s"; nil when empty.
    static func short(_ cycles: String) -> String? {
        let parts = cycles.split(separator: ":").map { Double($0) ?? 0 }
        guard !parts.isEmpty, !cycles.isEmpty else { return nil }
        let secs = parts.reversed().enumerated().reduce(0.0) { $0 + $1.element * pow(60, Double($1.offset)) }
        return duration(Int(secs.rounded()))
    }
}

// MARK: - Add sheet

struct SetupSheet: View {
    @EnvironmentObject var state: AppState
    @StateObject private var form: Box<JobSetup>
    init(setup: JobSetup) { _form = StateObject(wrappedValue: Box(setup)) }
    private var setup: JobSetup { form.value }
    private var pcCount: Int { state.splitPCs(blender: setup.info.blender).count }
    private var mismatched: [String] { state.mismatchedPCs(blender: setup.info.blender) }

    var body: some View {
        let i = setup.info
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "cube.transparent.fill")
                    .font(.system(size: 30)).foregroundStyle(Color.accentColor)
                    .frame(width: 52, height: 52)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    TextField("Name", text: $form.value.name)
                        .textFieldStyle(.plain).font(.title2.weight(.semibold))
                    Text("\(i.engine.capitalized) · \(i.res_x)×\(i.res_y) · \(i.samples) samples · \(i.camera ?? "no camera") · Blender \(i.blender)")
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(20)

            if i.camera == nil || !i.missing.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    if i.camera == nil {
                        Label("The scene has no active camera, so there's nothing to render.", systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                    }
                    if !i.missing.isEmpty {
                        Label("Missing on this Mac, so not packed: \(i.missing.joined(separator: ", "))", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.callout).padding(.horizontal, 20)
            }

            Form {
                Section {
                    Picker("Render", selection: $form.value.isAnimation) {
                        Text("Still Image").tag(false)
                        Text("Animation").tag(true)
                    }
                    .pickerStyle(.segmented)
                    if setup.isAnimation {
                        Stepper(value: $form.value.start, in: -100000...setup.end) {
                            LabeledContent("First frame", value: "\(setup.start)")
                        }
                        Stepper(value: $form.value.end, in: setup.start...100000) {
                            LabeledContent("Last frame", value: "\(setup.end)")
                        }
                        if pcCount >= 2 {
                        Toggle("Split across \(pcCount) PCs", isOn: $form.value.split)
                    }
                    Toggle("Fast preview", isOn: Binding(get: { setup.fast }, set: { on in
                            form.value.fast = on
                            if on {  // preview size and samples; still adjustable below
                                form.value.pct = min(form.value.pct, JobSetup.fastPct)
                                if i.engine == "CYCLES" { form.value.samples = min(form.value.samples, JobSetup.fastSamples) }
                            }
                        }))
                    } else {
                        Stepper(value: $form.value.frame, in: -100000...100000) {
                            LabeledContent("Frame", value: "\(setup.frame)")
                        }
                    }
                } footer: {
                    if setup.isAnimation && !mismatched.isEmpty {
                        Text("Not used, different Blender version from this Mac: \(mismatched.joined(separator: ", ")).")
                    }
                    if setup.isAnimation && setup.fast {
                        Text("Every \(JobSetup.fastStep)th frame: \((setup.end - setup.start) / JobSetup.fastStep + 1) of \(setup.end - setup.start + 1) frames, about \(JobSetup.fastStep)× faster. Same look as the final render; the video keeps its length but plays at a lower frame rate.")
                    } else if setup.isAnimation {
                        Text("\(setup.end - setup.start + 1) frames, saved as " + (i.video ? "a video in the file's output format." : "numbered PNG files."))
                    }
                }
                Section {
                    Stepper(value: $form.value.pct, in: 10...400, step: 10) {
                        LabeledContent("Resolution", value: "\(setup.pct)%  ·  \(i.res_x * setup.pct / 100)×\(i.res_y * setup.pct / 100)")
                    }
                    if i.engine == "CYCLES" {
                        Stepper(value: $form.value.samples, in: 1...65536, step: setup.samples >= 512 ? 128 : 16) {
                            LabeledContent("Samples", value: "\(setup.samples)")
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: setup.isAnimation ? (pcCount >= 2 ? 345 : 300) : 190)
            .monospacedDigit()

            HStack {
                Button("Cancel", role: .cancel) { state.discard(setup) }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add to Queue") { state.send(setup) }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(setup.name.trimmingCharacters(in: .whitespaces).isEmpty || i.camera == nil)
            }
            .padding(20)
        }
        .frame(width: 520)
        .animation(.ui, value: setup.isAnimation)
    }
}

// MARK: - Settings window (⌘,)

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var form = Box(Config())
    @StateObject private var loaded = Box(false)
    @StateObject private var addingPC = Box(false)

    private func pcEnabled(_ pc: PCEntry) -> Binding<Bool> {
        Binding {
            pc.id == "main" ? form.value.mainPCInSplits : pc.enabled
        } set: { on in
            if pc.id == "main" { form.value.mainPCInSplits = on }
            else if let i = form.value.extraPCs.firstIndex(where: { $0.id == pc.id }) { form.value.extraPCs[i].enabled = on }
        }
    }

    var body: some View {
        Form {
            Section {
                TextField("Address", text: $form.value.host, prompt: Text("192.168.1.50"))
                TextField("Windows user", text: $form.value.user)
                TextField("Queue folder", text: $form.value.queueDir)
            } header: {
                Text("Render PC")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("The values setup_windows_pc.ps1 printed on the PC. This Mac signs in with its SSH key, so there's no password.")
                    Button("Setting up a new PC? Open the Setup Guide") { state.showGuide = true }.buttonStyle(.link)
                }
            }
            Section {
                ForEach(form.value.allPCs) { pc in
                    HStack {
                        Circle().fill(state.pcVersions[pc.id] == nil ? Color.red : .green).frame(width: 8, height: 8)
                        Toggle(pc.displayName, isOn: pcEnabled(pc))
                        if pc.id != "main" {
                            Button { form.value.extraPCs.removeAll { $0.id == pc.id } } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless).help("Remove this PC")
                        }
                    }
                }
                Button("Add PC…") { addingPC.value = true }
            } header: {
                Text("PCs That Share Animations")
            } footer: {
                Text("With two or more PCs switched on, animations can be split between them. This Mac hands out the frames, so it has to stay on until the job is done. Stills and everything else render on the PC above.")
            }
            Section("Downloads") {
                LabeledContent("Save renders to") {
                    HStack {
                        Text(form.value.downloadDir).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Choose…") { chooseFolder() }
                    }
                }
                Toggle("Download renders automatically when they finish", isOn: $form.value.autoDownload)
            }
            Section {
                Toggle("Keep Mac alive while rendering", isOn: $form.value.keepAwake)
            } header: {
                Text("This Mac")
            } footer: {
                Text("Stops the Mac sleeping on its own while files are sending, jobs are queued or rendering, or renders are downloading. The screen can still turn off.")
            }
            Section {
                TextField("Blender on this Mac", text: $form.value.macBlender)
                TextField("Test folder", text: $form.value.testDir, prompt: Text("Empty – use the render PC"))
            } header: {
                Text("Advanced")
            } footer: {
                Text("Blender on this Mac packs each file's textures before upload. A test folder makes this Mac act as the render PC.")
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $addingPC.value) {
            AddPCView { pc in
                if form.value.host.isEmpty {
                    (form.value.host, form.value.user) = (pc.host, pc.user)
                } else {
                    form.value.extraPCs.append(pc)
                }
                state.saveConfig(form.value)
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Revert") { form.value = state.cfg }.disabled(form.value == state.cfg)
                Button("Save & Connect") { state.saveConfig(form.value) }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(form.value == state.cfg)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
        .frame(width: 520, height: 640)
        .onAppear { if !loaded.value { form.value = state.cfg; loaded.value = true } }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: form.value.downloadDir)
        if panel.runModal() == .OK, let url = panel.url { form.value.downloadDir = url.path }
    }
}

// MARK: - Log

struct LogView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let job: PCJob
    @StateObject private var text = Box("Loading…")

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Blender Log").font(.headline)
                Text(job.displayName).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            ScrollView {
                Text(text.value).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .frame(width: 720, height: 480)
        .task { text.value = await state.log(job) }
    }
}

/// Plain observable value holder; stands in for @State, whose macro needs the full Xcode toolchain.
final class Box<T>: ObservableObject {
    @Published var value: T
    init(_ value: T) { self.value = value }
}
