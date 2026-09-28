import AppKit
import SwiftUI
import Charts
import Combine
import Network
import UserNotifications
import ServiceManagement
import UniformTypeIdentifiers

@MainActor final class Monitor: ObservableObject {
    @Published var config: Configuration
    @Published var snapshot: Snapshot?
    @Published var samples: [Snapshot] = []
    @Published var diagnosis: Diagnosis = .pending
    @Published var stability = Stability()
    @Published var incidents: [Incident] = []
    @Published var paused = false
    @Published var sleeping = false
    @Published var busy = false
    @Published var notice = ""
    private var loop: Task<Void, Never>?
    private var generation = UUID()
    private var pathMonitor = NWPathMonitor()
    private var pathAvailable: Bool?
    private var networkIdentity = ""
    private var lastStored = Date.distantPast
    private let directory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    var onWindowSettings: (() -> Void)?

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NetworkLens", isDirectory: true)
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        config = Configuration()
        do {
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            if let data = try? Data(contentsOf: self.directory.appendingPathComponent("settings.json")),
               let saved = try? decoder.decode(Configuration.self, from: data),
               Configuration.validate(host: saved.dnsHost, websites: saved.websites.joined(separator: "\n")) == nil {
                config = saved
                config.interval = min(60, max(5, config.interval))
                config.timeout = min(10, max(1, config.timeout))
                config.opacity = min(1, max(0.8, config.opacity))
            }
            if let data = try? Data(contentsOf: self.directory.appendingPathComponent("incidents.json")),
               let saved = try? decoder.decode([Incident].self, from: data) {
                incidents = Array(saved.suffix(200))
                for index in incidents.indices where incidents[index].end == nil {
                    incidents[index].end = Date()
                    incidents[index].ending = "应用曾退出；中断期间状态未知，非已验证恢复"
                }
            }
        } catch { notice = "本地存储创建失败：\(error.localizedDescription)" }
    }
    func start() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor in self?.pathAvailable = available }
        }
        pathMonitor.start(queue: DispatchQueue(label: "networklens.path"))
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setSleeping(true) }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setSleeping(false) }
        }
        restart()
    }
    func restart() {
        loop?.cancel(); generation = UUID(); busy = false
        guard !paused && !sleeping else { return }
        let token = generation
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.generation == token else { return }
                let began = Date()
                self.busy = true
                let result = await Engine.sample(config: self.config, pathAvailable: self.pathAvailable)
                guard !Task.isCancelled, self.generation == token else { return }
                self.busy = false
                self.accept(result)
                let delay = max(1, self.config.interval - Date().timeIntervalSince(began))
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
            }
        }
    }
    func togglePause() {
        paused.toggle()
        if paused { interruptEvidence("检测已暂停；暂停期间状态未知") }
        else { stability.reset(); diagnosis = .pending }
        restart()
    }
    func setSleeping(_ value: Bool) {
        sleeping = value
        if value { interruptEvidence("Mac 进入休眠；休眠期间状态未知") }
        else { stability.reset(); diagnosis = .pending }
        restart()
    }
    func interruptEvidence(_ reason: String) {
        if let index = incidents.lastIndex(where: { $0.end == nil }) {
            incidents[index].end = Date(); incidents[index].ending = reason
            persistIncidents()
        }
        stability.reset()
    }
    func accept(_ result: Snapshot) {
        let identity = "\(result.interface)|\(result.localIP)|\(result.gateway)"
        if !networkIdentity.isEmpty && networkIdentity != identity {
            interruptEvidence("网络接口/地址/网关发生变化；重新建立检测基线")
            samples.removeAll()
        }
        networkIdentity = identity
        snapshot = result
        samples.append(result)
        samples = Array(samples.suffix(120))
        diagnosis = diagnose(result)
        if stability.ingest(diagnosis) {
            let now = result.time
            let previousIndex = incidents.lastIndex { $0.end == nil }
            if let index = previousIndex {
                incidents[index].end = now
                incidents[index].ending = diagnosis.problematic ? "故障类别变化" : "连续两轮恢复可达"
            }
            if diagnosis.problematic {
                incidents.append(Incident(start: samples.suffix(3).first?.time ?? now, end: nil, title: diagnosis.title, evidence: diagnosis.evidence))
                notify(title: diagnosis.title, body: "已连续 3 轮观测到异常。" + diagnosis.evidence)
            } else if previousIndex != nil {
                notify(title: "网络检测已恢复", body: "连续两轮恢复可达；可在事件记录中查看持续时间。")
            }
            incidents = Array(incidents.suffix(200))
            persistIncidents()
        }
        // Healthy samples are persisted every 30 s; anomalies always persist. RAM chart keeps every sample.
        if diagnosis.problematic || result.time.timeIntervalSince(lastStored) >= 30 {
            appendLog(result); lastStored = result.time
        }
    }
    var displayTitle: String {
        if paused { return "检测已暂停" }
        if sleeping { return "休眠中" }
        if snapshot == nil { return "正在检测网络" }
        if diagnosis.problematic && stability.confirmed.key != diagnosis.key { return "发现异常 · 正在复核" }
        if !diagnosis.problematic && stability.confirmed.problematic { return "正在确认恢复" }
        return diagnosis.title
    }
    var statusColor: Color {
        if paused || sleeping || snapshot == nil { return .secondary }
        return diagnosis.problematic ? .orange : .green
    }
    func save(_ value: Configuration) {
        let changedTargets = config.dnsHost != value.dnsHost || config.websites != value.websites
        let enabledNotifications = !config.notifications && value.notifications
        config = value
        do {
            try encoder.encode(value).write(to: directory.appendingPathComponent("settings.json"), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: directory.appendingPathComponent("settings.json").path)
        } catch { notice = "设置保存失败：\(error.localizedDescription)" }
        if changedTargets { interruptEvidence("检测目标已修改；重新建立检测基线"); samples.removeAll(); snapshot = nil; diagnosis = .pending }
        if enabledNotifications {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
                Task { @MainActor in
                    if !granted { self?.notice = "通知未获系统许可；请在系统设置 → 通知中开启。" }
                    if let error { self?.notice = "通知权限错误：\(error.localizedDescription)" }
                }
            }
        }
        onWindowSettings?()
        restart()
    }
    private func notify(title: String, body: String) {
        guard config.notifications else { return }
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { [weak self] error in
            if let error { Task { @MainActor in self?.notice = "通知发送失败：\(error.localizedDescription)" } }
        }
    }
    private func persistIncidents() {
        do { try encoder.encode(incidents).write(to: directory.appendingPathComponent("incidents.json"), options: .atomic) }
        catch { notice = "事件写入失败：\(error.localizedDescription)" }
    }
    private func appendLog(_ result: Snapshot) {
        let url = directory.appendingPathComponent("samples.jsonl")
        do {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            if let size = attrs?[.size] as? NSNumber, size.intValue > 5_000_000 {
                let previous = directory.appendingPathComponent("samples.previous.jsonl")
                if FileManager.default.fileExists(atPath: previous.path) { try FileManager.default.removeItem(at: previous) }
                try FileManager.default.moveItem(at: url, to: previous)
            }
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            var data = try encoder.encode(result); data.append(0x0a)
            try handle.write(contentsOf: data)
        } catch { notice = "检测记录写入失败：\(error.localizedDescription)" }
    }
    func exportReport() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "NetworkLens-\(Date().formatted(.iso8601.year().month().day())).json"
        panel.allowedContentTypes = [.json]
        panel.message = "报告包含本机 IP、网关、探测主机和事件；分享给 IT 前请检查。网站查询参数不导出。"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        struct Report: Encodable {
            var exported: Date
            var note: String
            var samples: [Snapshot]
            var incidents: [Incident]
        }
        do {
            let report = Report(exported: Date(), note: "仅包含当前会话最近 120 个样本与最近 200 个事件。异常是分层推测，不是确定归因。DNS 可命中缓存；TCP 使用直连，HTTP 使用系统代理。", samples: samples, incidents: incidents)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(report).write(to: destination, options: .atomic)
            notice = "诊断报告已导出。"
        } catch { notice = "导出失败：\(error.localizedDescription)" }
    }
    func openLogs() { NSWorkspace.shared.open(directory) }
    func stop() {
        loop?.cancel(); pathMonitor.cancel()
        interruptEvidence("应用退出；后续状态未知")
    }
}

struct Glass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView(); v.material = .hudWindow; v.blendingMode = .behindWindow; v.state = .active; return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
func metric(_ value: Double?) -> String { value.map { String(format: $0 < 10 ? "%.1f ms" : "%.0f ms", $0) } ?? "—" }

struct Dashboard: View {
    @ObservedObject var monitor: Monitor
    var settings: () -> Void
    var history: () -> Void
    @State private var details = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "waveform.path.ecg").foregroundStyle(.teal).accessibilityHidden(true)
                Text("网络透镜").font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                Button(action: monitor.togglePause) {
                    Image(systemName: monitor.paused ? "play.fill" : "pause.fill")
                        .font(.system(size: 10)).frame(width: 24, height: 24)
                }.buttonStyle(.plain)
                    .help(monitor.paused ? "继续检测" : "暂停检测")
                    .accessibilityLabel(monitor.paused ? "继续检测" : "暂停检测")
                Menu {
                    Button("检测详情") { details = true }
                    Button("设置…", action: settings)
                    Button("异常事件…", action: history)
                    Button("导出报告…", action: monitor.exportReport)
                    Divider()
                    Button("隐藏组件") { NSApp.keyWindow?.orderOut(nil) }
                    Button("退出网络透镜") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 22, height: 24)
                }.menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .fixedSize().help("更多操作").accessibilityLabel("更多操作")
            }.frame(height: 24)

            HStack(spacing: 5) {
                Image(systemName: statusSymbol).font(.system(size: 11)).accessibilityHidden(true)
                Text(compactStatus).font(.system(size: 11, weight: .medium))
                    .lineLimit(1).minimumScaleFactor(0.9)
                Spacer(minLength: 0)
            }.foregroundStyle(monitor.statusColor).frame(height: 18)
                .help(monitor.displayTitle + "\n" + monitor.diagnosis.evidence)
                .accessibilityLabel(monitor.displayTitle)

            VStack(spacing: 0) {
                compactRow("网关", ids: ["gateway"])
                compactRow("DNS", ids: ["dns"])
                compactRow("外网", ids: ["tcp1", "tcp2"])
                compactRow("网站", ids: (0..<5).map { "web\($0)" })
            }.frame(height: 72)
            Divider()
            HStack(spacing: 4) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let stale = monitor.snapshot.map { context.date.timeIntervalSince($0.time) > max(15, monitor.config.interval * 2) } ?? false
                    Text(monitor.paused ? "已暂停" : stale ? "结果已过期" : monitor.snapshot.map { $0.time.formatted(date: .omitted, time: .standard) } ?? "检测中…")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(stale ? Color.orange : Color.secondary)
                }
                Spacer(minLength: 0)
                Button { details.toggle() } label: {
                    HStack(spacing: 3) {
                        if !monitor.notice.isEmpty { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange) }
                        Text("详情")
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                    }.font(.system(size: 10)).frame(height: 24)
                }.buttonStyle(.plain).help("展开检测详情和趋势")
                    .popover(isPresented: $details) { detailView }
            }.frame(height: 24)
        }
        .padding(12).frame(width: 190, height: 190)
        .background(Glass())
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
        .preferredColorScheme(monitor.config.theme == "dark" ? .dark : monitor.config.theme == "light" ? .light : nil)
    }
    var statusSymbol: String {
        if monitor.paused || monitor.sleeping { return "pause.circle.fill" }
        if monitor.snapshot == nil { return "clock" }
        return monitor.diagnosis.problematic ? "exclamationmark.circle.fill" : monitor.diagnosis.key == "restricted" ? "info.circle.fill" : "checkmark.circle.fill"
    }
    var compactStatus: String {
        if monitor.paused { return "检测已暂停" }
        if monitor.sleeping { return "休眠中" }
        if monitor.snapshot == nil { return "正在检测网络" }
        if monitor.diagnosis.problematic && monitor.stability.confirmed.key != monitor.diagnosis.key { return "异常复核 \(min(monitor.stability.count, 3))/3" }
        if !monitor.diagnosis.problematic && monitor.stability.confirmed.problematic { return "正在确认恢复" }
        switch monitor.diagnosis.key {
        case "restricted": return "网站可达 · 直连受限"
        case "healthy": return "网络连接正常"
        case "local": return "疑似本机连接异常"
        case "route": return "疑似路由异常"
        case "dns": return "疑似 DNS 异常"
        case "path": return "疑似本地或出口异常"
        case "upstream": return "疑似出口或上游异常"
        case "website": return "疑似目标服务异常"
        case "partial": return "部分外网探测异常"
        case "slow": return "网络可达 · 延迟偏高"
        default: return monitor.displayTitle
        }
    }
    var connectionText: String {
        guard let s = monitor.snapshot else { return "等待首轮检测" }
        return "\(s.interface.isEmpty ? "无默认接口" : s.interface) · \(s.localIP.isEmpty ? "未获取 IP" : s.localIP)\(s.proxyOrVPN ? " · VPN/代理" : "")"
    }
    @ViewBuilder func compactRow(_ title: String, ids: [String]) -> some View {
        let probes = monitor.snapshot?.probes.filter { ids.contains($0.id) } ?? []
        let passing = probes.filter(\.ok).count
        let values = probes.filter(\.ok).compactMap(\.milliseconds)
        let failed = !probes.isEmpty && passing < probes.count
        let value = probes.isEmpty ? "—" : failed ? (probes.count > 1 ? "\(passing)/\(probes.count) 可达" : "未响应") : metric(values.isEmpty ? nil : values.reduce(0, +) / Double(values.count))
        HStack(spacing: 6) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(value).font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(failed ? Color.orange : Color.primary).monospacedDigit()
        }.font(.system(size: 11)).frame(height: 18)
            .accessibilityElement(children: .combine)
            .help(probes.map { "\($0.target)：\($0.detail)" }.joined(separator: "\n"))
    }
    var detailView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(monitor.displayTitle).font(.headline).foregroundStyle(monitor.statusColor)
                Text(connectionText).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Text(monitor.diagnosis.evidence).font(.caption).fixedSize(horizontal: false, vertical: true)
                if !monitor.notice.isEmpty {
                    Text(monitor.notice).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                }
                Text("外网 TCP 建连趋势 · 最近 \(monitor.samples.count) 次").font(.caption).foregroundStyle(.secondary)
                LatencyChart(samples: monitor.samples).frame(height: 60)
                Divider()
                Text("逐项探测结果").font(.headline)
                ForEach(monitor.snapshot?.probes ?? []) { p in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Label(p.title, systemImage: p.ok ? "checkmark.circle" : "exclamationmark.circle").foregroundStyle(p.ok ? .green : .orange); Spacer(); Text(metric(p.milliseconds)).monospacedDigit() }
                        Text(p.target).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        Text(p.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("网站以 HEAD 请求检测响应；HTTP 响应成功不等于业务功能正常。DNS 可能命中系统缓存。此工具不检查浏览内容，也不修改网络设置。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("导出诊断报告", action: monitor.exportReport)
                    Button("事件记录", action: history)
                }
            }.padding(20)
        }.frame(width: 430, height: 470)
    }
}

struct LatencyChart: View {
    let samples: [Snapshot]
    var body: some View {
        GeometryReader { geometry in
            let maximum = max(20, samples.compactMap(\.externalLatency).max() ?? 20)
            let values = Array(samples.enumerated())
            ZStack(alignment: .topTrailing) {
                Path { p in
                    for fraction in [0.0, 0.5, 1.0] {
                        let y = geometry.size.height * fraction
                        p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: geometry.size.width, y: y))
                    }
                }.stroke(.secondary.opacity(0.15), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                Path { path in
                    var connected = false
                    for (i, s) in values {
                        guard let value = s.externalLatency else { connected = false; continue }
                        let point = CGPoint(x: CGFloat(i) / CGFloat(max(1, samples.count - 1)) * geometry.size.width,
                            y: geometry.size.height - CGFloat(value / maximum) * (geometry.size.height - 10))
                        if connected { path.addLine(to: point) } else { path.move(to: point) }
                        connected = true
                    }
                }.stroke(.teal, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                ForEach(values, id: \.offset) { i, s in
                    if s.externalLatency == nil {
                        Image(systemName: "xmark").font(.system(size: 7, weight: .bold)).foregroundStyle(.orange)
                            .position(x: CGFloat(i) / CGFloat(max(1, samples.count - 1)) * geometry.size.width, y: geometry.size.height - 3)
                    }
                }
                Text("\(Int(maximum)) ms").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                if samples.isEmpty { Text("检测后显示真实趋势").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
        }.accessibilityElement(children: .ignore).accessibilityLabel("最近 \(samples.count) 次外网 TCP 建连趋势，当前 \(metric(samples.last?.externalLatency))。叉号代表两个目标均失败，非零毫秒。")
    }
}

struct SettingsView: View {
    @ObservedObject var monitor: Monitor
    @State var draft: Configuration
    @State var websites: String
    @State var error = ""
    @State var loginMessage = ""
    var close: () -> Void
    init(monitor: Monitor, close: @escaping () -> Void) {
        self.monitor = monitor; self.close = close
        _draft = State(initialValue: monitor.config)
        _websites = State(initialValue: monitor.config.websites.joined(separator: "\n"))
    }
    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("探测设置") {
                    Picker("刷新间隔", selection: $draft.interval) {
                        ForEach([5.0, 10, 15, 30, 60], id: \.self) { Text("\(Int($0)) 秒").tag($0) }
                    }
                    Picker("单项超时", selection: $draft.timeout) {
                        ForEach([2.0, 3, 5, 8, 10], id: \.self) { Text("\(Int($0)) 秒").tag($0) }
                    }
                    TextField("DNS 域名", text: $draft.dnsHost)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("指定网站（每行一个，最多 5 个）")
                        TextEditor(text: $websites).font(.system(.body, design: .monospaced)).frame(height:  seventy).border(.secondary.opacity(0.3)).accessibilityLabel("指定网站列表")
                        Text("使用 HEAD 请求，不携带 Cookie 或保存的凭据。查询参数保存在本机设置中，不写入报告。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("直连 TCP：Cloudflare 1.1.1.1:443、Google 8.8.8.8:443。公司防火墙可能限制；可达性不代表整个互联网。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("桌面外观") {
                    Toggle("悬浮置顶", isOn: $draft.floating)
                    Picker("配色", selection: $draft.theme) { Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark") }
                    HStack { Text("不透明度"); Slider(value: $draft.opacity, in: 0.8...1); Text("\(Int(draft.opacity * 100))%").monospacedDigit().frame(width: 40) }
                }
                Section("提醒与启动") {
                    Toggle("持续异常与恢复时发送通知", isOn: $draft.notifications)
                    Text("连续 3 轮异常才记录和提醒；连续 2 轮可达才确认恢复。通知默认关闭。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text("登录启动")
                        Spacer()
                        Button("启用") { login(true) }
                        Button("停用") { login(false) }
                    }
                    Text(loginMessage.isEmpty ? "登录启动是独立操作，点击即生效。建议先将 App 移入“应用程序”；必要时在系统设置允许。" : loginMessage)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("数据") {
                    HStack { Button("打开本地记录", action: monitor.openLogs); Button("导出报告", action: monitor.exportReport) }
                    Text("不上传日志、不抓包、不修改 DNS/路由/代理。健康样本约每 30 秒落盘；异常逐轮保存。日志轮转约 10 MB。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
            if !error.isEmpty { Text(error).foregroundStyle(.red).font(.caption).padding(.horizontal) }
            HStack {
                Spacer(); Button("取消", action: close).keyboardShortcut(.cancelAction)
                Button("保存") {
                    draft.dnsHost = draft.dnsHost.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let message = Configuration.validate(host: draft.dnsHost, websites: websites) { error = message; return }
                    draft.websites = websites.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    monitor.save(draft); close()
                }.keyboardShortcut(.defaultAction)
            }.padding(16)
        }.frame(width: 520, height: 710)
    }
    var seventy: CGFloat { 70 }
    func login(_ enable: Bool) {
        do {
            if enable { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            switch SMAppService.mainApp.status {
            case .enabled: loginMessage = "已启用登录启动。"
            case .requiresApproval: loginMessage = "等待系统批准：系统设置 → 通用 → 登录项。"
            case .notRegistered: loginMessage = "登录启动已关闭。"
            default: loginMessage = "系统暂未确认状态；请检查登录项设置。"
            }
        } catch { loginMessage = "设置失败：\(error.localizedDescription)" }
    }
}

struct HistoryView: View {
    @ObservedObject var monitor: Monitor
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("异常事件").font(.title2.bold()); Spacer(); Button("导出报告", action: monitor.exportReport) }
            Text("连续 3 轮异常后记录。暂停、休眠及退出不作为已验证恢复。")
                .font(.caption).foregroundStyle(.secondary)
            if monitor.incidents.isEmpty {
                VStack(spacing: 12) { Image(systemName: "checkmark.shield").font(.system(size: 36)).foregroundStyle(.teal); Text("暂无已确认异常"); Text("短暂抖动不会生成断网事件。") .font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(monitor.incidents.reversed()) { event in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Text(event.title).font(.headline); Spacer(); Text(event.end == nil ? "持续中" : "已结束").font(.caption).foregroundStyle(event.end == nil ? .orange : .secondary) }
                        Text(event.start.formatted(date: .abbreviated, time: .standard)).font(.caption).monospacedDigit()
                        if let end = event.end { Text("结束 \(end.formatted(date: .omitted, time: .standard)) · 记录跨度 \(Int(end.timeIntervalSince(event.start))) 秒").font(.caption).foregroundStyle(.secondary) }
                        Text(event.evidence).font(.caption)
                        if let ending = event.ending { Text(ending).font(.caption).foregroundStyle(.secondary) }
                    }.padding(.vertical, 8).textSelection(.enabled)
                }.listStyle(.inset)
            }
        }.padding(20).frame(width: 590, height: 480)
    }
}

final class WidgetPanel: NSPanel { override var canBecomeKey: Bool { true }; override var canBecomeMain: Bool { true } }
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var monitor = Monitor()
    var panel: WidgetPanel!
    var settingsWindow: NSWindow?
    var historyWindow: NSWindow?
    var statusItem: NSStatusItem!
    var subscription: AnyCancellable?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().delegate = self
        let menu = NSMenu()
        add(menu, "显示桌面组件", #selector(showWidget), "1")
        add(menu, "暂停 / 继续检测", #selector(togglePause), "p")
        add(menu, "设置…", #selector(showSettings), ",")
        add(menu, "事件记录…", #selector(showHistory), "h")
        add(menu, "导出报告…", #selector(export), "e")
        menu.addItem(.separator())
        add(menu, "退出网络透镜", #selector(quit), "q")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu = menu
        statusItem.button?.image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "网络透镜")
        statusItem.button?.imagePosition = .imageLeading
        let root = Dashboard(monitor: monitor, settings: { [weak self] in self?.showSettings() }, history: { [weak self] in self?.showHistory() })
        panel = WidgetPanel(contentRect: NSRect(x: 100, y: 100, width: 190, height: 190), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.title = "网络透镜"
        panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear; panel.isOpaque = false
        panel.contentView = NSHostingView(rootView: root)
        panel.setFrameAutosaveName("NetworkLens.compactWidget")
        // The outer window, not just its content, must be an exact 190 pt square.
        panel.setContentSize(NSSize(width: 190, height: 190))
        panel.minSize = NSSize(width: 190, height: 190)
        panel.maxSize = NSSize(width: 190, height: 190)
        if UserDefaults.standard.string(forKey: "NSWindow Frame NetworkLens.compactWidget") == nil, let screen = NSScreen.main {
            panel.setFrameTopLeftPoint(NSPoint(x: screen.visibleFrame.maxX - 214, y: screen.visibleFrame.maxY - 28))
        }
        monitor.onWindowSettings = { [weak self] in self?.applyAppearance() }
        applyAppearance()
        subscription = monitor.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshStatus() }
        }
        showWidget(); monitor.start()
    }
    func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; menu.addItem(item)
    }
    func applyAppearance() {
        panel?.level = monitor.config.floating ? .floating : .normal
        panel?.alphaValue = monitor.config.opacity
        NSApp.appearance = monitor.config.theme == "dark" ? NSAppearance(named: .darkAqua) : monitor.config.theme == "light" ? NSAppearance(named: .aqua) : nil
    }
    func refreshStatus() {
        statusItem.button?.title = monitor.paused ? " 暂停" : monitor.snapshot == nil ? " …" : monitor.diagnosis.problematic ? " !" : " \(metric(monitor.snapshot?.externalLatency))"
        statusItem.button?.toolTip = monitor.displayTitle
    }
    @objc func showWidget() { panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func togglePause() { monitor.togglePause() }
    @objc func showSettings() {
        if let settingsWindow, settingsWindow.isVisible { settingsWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let view = SettingsView(monitor: monitor) { [weak self] in self?.settingsWindow?.close() }
        settingsWindow = makeWindow("网络透镜 · 设置", root: view)
    }
    @objc func showHistory() {
        if let historyWindow { historyWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        historyWindow = makeWindow("网络透镜 · 异常事件", root: HistoryView(monitor: monitor))
    }
    func makeWindow<V: View>(_ title: String, root: V) -> NSWindow {
        let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = title; w.isReleasedWhenClosed = false; w.contentView = NSHostingView(rootView: root)
        w.center(); w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return w
    }
    @objc func export() { monitor.exportReport() }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { monitor.stop() }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                           withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) { completionHandler([.banner, .sound]) }
}

@main struct Entry {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--self-test") {
            runSelfTests(); return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--probe-url"), CommandLine.arguments.count > index + 1,
           let url = URL(string: CommandLine.arguments[index + 1]), ["http", "https"].contains(url.scheme ?? "") {
            Task {
                let result = await HeaderProbe.run(url, id: "web0", timeout: 2)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                if let data = try? encoder.encode(result) { FileHandle.standardOutput.write(data); print("") }
                exit(0)
            }
            RunLoop.main.run(); return
        }
        if CommandLine.arguments.contains("--probe-once") {
            Task {
                let snapshot = await Engine.sample(config: Configuration())
                struct Output: Encodable { var snapshot: Snapshot; var title: String; var evidence: String }
                let diagnosis = diagnose(snapshot)
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                do { let data = try encoder.encode(Output(snapshot: snapshot, title: diagnosis.title, evidence: diagnosis.evidence)); FileHandle.standardOutput.write(data); print(""); exit(0) }
                catch { fputs("Encoding error\n", stderr); exit(1) }
            }
            RunLoop.main.run(); return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
