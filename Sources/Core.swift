import Foundation
import Network
import Darwin

struct Probe: Codable, Identifiable {
    var id: String
    var title: String
    var target: String
    var ok: Bool
    var milliseconds: Double?
    var detail: String
    var statusCode: Int? = nil
}
struct Snapshot: Codable {
    var time: Date
    var interface: String
    var localIP: String
    var gateway: String
    var pathAvailable: Bool
    var proxyOrVPN: Bool
    var probes: [Probe]
    var externalLatency: Double? {
        let values = probes.filter { $0.id.hasPrefix("tcp") && $0.ok }.compactMap(\.milliseconds).sorted()
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}
struct Diagnosis: Equatable {
    var key: String
    var title: String
    var evidence: String
    var problematic: Bool
    static let pending = Diagnosis(key: "pending", title: "正在检测", evidence: "等待第一轮实测结果。", problematic: false)
}
struct Incident: Codable, Identifiable {
    var id = UUID()
    var start: Date
    var end: Date?
    var title: String
    var evidence: String
    var ending: String?
}
struct Configuration: Codable {
    var interval: Double = 5
    var timeout: Double = 3
    var dnsHost = "www.apple.com"
    var websites = ["https://www.apple.com", "https://www.baidu.com"]
    var notifications = false
    var floating = false
    var opacity: Double = 0.97
    var theme = "system"
    static func validate(host: String, websites: String) -> String? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        if host.isEmpty || host.count > 253 || host.contains("..") || host.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            return "DNS 目标请填写域名，不包含协议或路径。"
        }
        let labels = host.hasSuffix(".") ? String(host.dropLast()).split(separator: ".") : host.split(separator: ".")
        if labels.isEmpty || labels.contains(where: { $0.count > 63 || $0.hasPrefix("-") || $0.hasSuffix("-") }) {
            return "DNS 域名的每一段须为 1–63 个字符，且不以连字符开头或结尾。"
        }
        let rows = websites.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if rows.isEmpty || rows.count > 5 { return "请设置 1–5 个网站，每行一个。" }
        for row in rows {
            guard let u = URLComponents(string: row), ["http", "https"].contains(u.scheme ?? ""), let h = u.host, !h.isEmpty,
                  u.user == nil, u.password == nil, u.fragment == nil else { return "网站须为完整 HTTP(S) 地址，不包含用户名、密码或片段。" }
        }
        return nil
    }
}

func diagnose(_ s: Snapshot) -> Diagnosis {
    let dns = s.probes.first { $0.id == "dns" }
    let gateway = s.probes.first { $0.id == "gateway" }
    let tcp = s.probes.filter { $0.id.hasPrefix("tcp") }
    let web = s.probes.filter { $0.id.hasPrefix("web") }
    let tcpOK = tcp.filter(\.ok).count
    let webOK = web.filter(\.ok).count
    let reachedWeb = web.contains { $0.statusCode != nil }
    let suffix = s.proxyOrVPN ? " 检测到 VPN/系统代理；直连 TCP 与网站可能经过不同路径。" : ""
    func result(_ key: String, _ title: String, _ evidence: String, _ bad: Bool = true) -> Diagnosis {
        Diagnosis(key: key, title: title, evidence: evidence + suffix, problematic: bad)
    }
    if !s.pathAvailable || s.localIP.isEmpty {
        return result("local", "疑似本机连接异常", "网络路径不可用，或当前接口没有有效 IP。先检查 Wi-Fi/网线与 VPN。")
    }
    if s.gateway.isEmpty && s.interface.isEmpty {
        return result("route", "疑似路由异常", "未发现默认路由；尚不能定位到公司网络或远程服务。")
    }
    if dns?.ok == false && tcpOK > 0 {
        return result("dns", "疑似 DNS 解析异常", "直连外网 TCP 有响应，但系统解析器未解析出指定域名。也可能仅该域名异常或负缓存。")
    }
    if tcpOK == 0 && !reachedWeb {
        if gateway?.ok == false {
            return result("path", "疑似本地或出口链路异常", "网关 ICMP、两个外网 TCP 和网站均未成功；也可能是防火墙/探测限制，证据不足以锁定本机或公司出口。")
        }
        return result("upstream", "疑似出口或上游异常", "外网 TCP 与网站均失败。网关有响应时，仅能说明本机到网关可达；仍需排查认证、策略及上游。")
    }
    if webOK < web.count {
        let failed = web.filter { !$0.ok }.map(\.target).joined(separator: "、")
        return result("website", "疑似目标服务或路径异常", "部分链路可达，但 \(failed) 异常；可能是服务端状态、TLS、代理或目标路径问题。")
    }
    if tcpOK == 0 && reachedWeb {
        return result("restricted", "网站可达 · 直连探测受限", "网站有 HTTP 响应，两个直连 TCP 探测失败；不判定为断网。请结合 VPN、代理及公司策略。", false)
    }
    if tcpOK < tcp.count {
        return result("partial", "部分外网探测异常", "至少一个外网 TCP 目标可达，另一个失败；不能据此认定整体断网。")
    }
    if (s.externalLatency ?? 0) > 500 || (dns?.milliseconds ?? 0) > 1000 {
        return result("slow", "网络可达 · 延迟偏高", "外网平均 TCP 建连超过 500 ms 或 DNS 超过 1000 ms；这是响应延迟，不是带宽测速。")
    }
    let note = gateway?.ok == false ? " 网关未响应 ICMP，可能禁止 ping，不作为断网证据。" : ""
    return result("healthy", "网络连接正常", "本轮 DNS、外网 TCP 与配置网站均通过。" + note + " 仅代表所选目标的当前结果。", false)
}

struct Stability {
    var candidate = ""
    var count = 0
    var confirmed: Diagnosis = .pending
    mutating func ingest(_ value: Diagnosis) -> Bool {
        if candidate == value.key { count += 1 } else { candidate = value.key; count = 1 }
        let threshold = value.problematic ? 3 : 2
        if count >= threshold && confirmed.key != value.key {
            confirmed = value
            return true
        }
        return false
    }
    mutating func reset() { self = Stability() }
}

struct CommandResult { var text: String; var code: Int32; var timedOut: Bool }
func command(_ executable: String, _ arguments: [String], timeout: Double) async -> CommandResult {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = pipe
            let done = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in done.signal() }
            do { try process.run() }
            catch { continuation.resume(returning: CommandResult(text: "", code: -1, timedOut: false)); return }
            // The invoked system utilities have small output; no shell or user command execution.
            let timedOut = done.wait(timeout: .now() + timeout) == .timedOut
            if timedOut {
                process.terminate()
                if done.wait(timeout: .now() + 0.25) == .timedOut {
                    kill(process.processIdentifier, SIGKILL)
                    done.wait()
                }
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            try? pipe.fileHandleForReading.close()
            continuation.resume(returning: CommandResult(text: String(data: data, encoding: .utf8) ?? "", code: process.terminationStatus, timedOut: timedOut))
        }
    }
}
func field(_ key: String, in text: String) -> String {
    for line in text.split(separator: "\n") {
        let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 2 && parts[0] == key { return parts[1] }
    }
    return ""
}
func address(of interface: String) -> String {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0 else { return "" }
    defer { freeifaddrs(list) }
    var item = list
    var v6 = ""
    while let current = item {
        defer { item = current.pointee.ifa_next }
        guard String(cString: current.pointee.ifa_name) == interface, let addr = current.pointee.ifa_addr else { continue }
        let family = Int32(addr.pointee.sa_family)
        guard family == AF_INET || family == AF_INET6 else { continue }
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
            let value = String(cString: buffer)
            if family == AF_INET && !value.hasPrefix("127.") && !value.hasPrefix("169.254.") { return value }
            if family == AF_INET6 && !value.hasPrefix("fe80:") && value != "::1" { v6 = value }
        }
    }
    return v6
}
func milliseconds(since start: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 }

final class TCPProbe: @unchecked Sendable {
    private let queue: DispatchQueue
    private let connection: NWConnection
    private let continuation: CheckedContinuation<Probe, Never>
    private let host: String
    private let port: UInt16
    private let id: String
    private let start = DispatchTime.now().uptimeNanoseconds
    // Mutable state is confined to queue.
    private var finished = false
    private var deadline: DispatchWorkItem?
    private init(host: String, port: UInt16, id: String, continuation: CheckedContinuation<Probe, Never>) {
        self.host = host; self.port = port; self.id = id; self.continuation = continuation
        queue = DispatchQueue(label: "networklens.\(id)")
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    }
    static func run(host: String, port: UInt16, id: String, timeout: Double) async -> Probe {
        await withCheckedContinuation { continuation in
            let probe = TCPProbe(host: host, port: port, id: id, continuation: continuation)
            probe.queue.async { probe.begin(timeout: timeout) }
        }
    }
    private func begin(timeout: Double) {
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready: finish(true, "TCP 建连成功（直连，不使用 HTTP 代理）")
            case .failed(let error): finish(false, "建连失败：\(error)")
            default: break
            }
        }
        let timer = DispatchWorkItem { [self] in finish(false, "TCP 建连超时") }
        deadline = timer
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout, execute: timer)
    }
    private func finish(_ ok: Bool, _ detail: String) {
        guard !finished else { return }; finished = true
        deadline?.cancel(); deadline = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation.resume(returning: Probe(id: id, title: "外网 TCP", target: "\(host):\(port)", ok: ok,
            milliseconds: ok ? milliseconds(since: start) : nil, detail: detail))
    }
}
final class HeaderProbe: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Probe, Never>?
    private var session: URLSession?
    private var start: UInt64 = 0
    private var target = ""
    private var probeID = ""
    private var deadline: DispatchWorkItem?
    static func run(_ url: URL, id: String, timeout: Double) async -> Probe {
        let delegate = HeaderProbe()
        return await withCheckedContinuation { continuation in
            delegate.continuation = continuation
            delegate.target = url.host ?? "目标网站" // Deliberately do not record path/query credentials.
            delegate.probeID = id
            delegate.start = DispatchTime.now().uptimeNanoseconds
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = timeout
            config.timeoutIntervalForResource = timeout
            config.httpShouldSetCookies = false
            config.httpCookieStorage = nil
            config.urlCredentialStorage = nil
            config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
            delegate.session = session
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            let timer = DispatchWorkItem { delegate.finish(ok: false, detail: "网站请求超时", code: nil) }
            delegate.deadline = timer
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout + 0.2, execute: timer)
            session.dataTask(with: request).resume()
        }
    }
    private func finish(ok: Bool, detail: String, code: Int?) {
        lock.lock()
        guard let c = continuation else { lock.unlock(); return }
        continuation = nil
        let timer = deadline; deadline = nil
        let s = session; session = nil
        lock.unlock()
        timer?.cancel(); s?.invalidateAndCancel()
        c.resume(returning: Probe(id: probeID, title: "指定网站", target: target, ok: ok,
            milliseconds: code != nil ? milliseconds(since: start) : nil, detail: detail, statusCode: code))
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else { completionHandler(.cancel); finish(ok: false, detail: "非 HTTP 响应", code: nil); return }
        let code = response.statusCode
        completionHandler(.cancel)
        finish(ok: (200..<400).contains(code) || code == 405,
               detail: code == 405 ? "HTTP 405：网络可达，服务器不支持 HEAD；业务状态未验证" : "HTTP \(code) · HEAD 响应（含 DNS/TLS 时间）", code: code)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let e = error as NSError? { finish(ok: false, detail: "请求失败（\(e.domain) \(e.code)）；检查 TLS、代理或目标路径", code: nil) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Report the original endpoint response; do not turn a login redirect into a false healthy destination.
        completionHandler(nil)
        finish(ok: false, detail: "HTTP \(response.statusCode)：重定向；网络可达，需人工检查目标/认证页面", code: response.statusCode)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }
}

struct Engine {
    static func sample(config: Configuration, pathAvailable: Bool? = nil) async -> Snapshot {
        async let proxyResult = command("/usr/sbin/scutil", ["--proxy"], timeout: 1)
        var route = await command("/sbin/route", ["-n", "get", "default"], timeout: 1)
        if field("interface", in: route.text).isEmpty {
            route = await command("/sbin/route", ["-n", "get", "-inet6", "default"], timeout: 1)
        }
        let interface = field("interface", in: route.text)
        let rawGateway = field("gateway", in: route.text)
        let gateway = rawGateway.hasPrefix("link#") ? "" : rawGateway
        let ip = address(of: interface)
        let proxy = await proxyResult
        let proxyEnabled = ["HTTPEnable", "HTTPSEnable", "SOCKSEnable", "ProxyAutoConfigEnable", "ProxyAutoDiscoveryEnable"].contains { field($0, in: proxy.text) == "1" }
        let timeout = config.timeout
        var probes = await withTaskGroup(of: Probe.self, returning: [Probe].self) { group in
            group.addTask {
                guard !gateway.isEmpty else { return Probe(id: "gateway", title: "本地网关", target: "未提供 IP 网关", ok: false, milliseconds: nil, detail: "点对点/VPN 或默认路由未提供可探测网关") }
                let start = DispatchTime.now().uptimeNanoseconds
                let isV6 = gateway.contains(":")
                let result = await command(isV6 ? "/sbin/ping6" : "/sbin/ping", ["-n", "-c", "1", gateway], timeout: timeout)
                var latency: Double?
                if let range = result.text.range(of: "time=") {
                    let number = result.text[range.upperBound...].prefix { $0.isNumber || $0 == "." }
                    latency = Double(number)
                }
                return Probe(id: "gateway", title: "本地网关", target: gateway, ok: result.code == 0,
                    milliseconds: result.code == 0 ? (latency ?? milliseconds(since: start)) : nil,
                    detail: result.code == 0 ? "ICMP 响应成功" : "ICMP 未通过（退出码 \(result.code)\(result.timedOut ? "，超时" : "")）。\(result.text.split(separator: "\n").first(where: { $0.contains("ping:") || $0.contains("ping6:") }).map { String($0.prefix(180)) } ?? "可能禁止 ICMP 或未授权本地网络访问")；不单独判定断网")
            }
            group.addTask {
                let start = DispatchTime.now().uptimeNanoseconds
                let result = await command("/usr/bin/dscacheutil", ["-q", "host", "-a", "name", config.dnsHost], timeout: timeout)
                let ok = !result.timedOut && result.code == 0 && (result.text.contains("ip_address:") || result.text.contains("ipv6_address:"))
                return Probe(id: "dns", title: "DNS 解析", target: config.dnsHost, ok: ok,
                    milliseconds: ok ? milliseconds(since: start) : nil,
                    detail: ok ? "系统解析器成功（可能命中缓存；含进程开销）" : "系统解析失败或超时；可能是域名、DNS 或策略问题")
            }
            group.addTask { await TCPProbe.run(host: "1.1.1.1", port: 443, id: "tcp1", timeout: timeout) }
            group.addTask { await TCPProbe.run(host: "8.8.8.8", port: 443, id: "tcp2", timeout: timeout) }
            for (i, value) in config.websites.enumerated() {
                if let url = URL(string: value) { group.addTask { await HeaderProbe.run(url, id: "web\(i)", timeout: timeout) } }
            }
            var values: [Probe] = []
            for await value in group { values.append(value) }
            return values
        }
        let ranks = ["gateway": 0, "dns": 1, "tcp1": 2, "tcp2": 3]
        probes.sort { (ranks[$0.id] ?? 4, $0.id) < (ranks[$1.id] ?? 4, $1.id) }
        return Snapshot(time: Date(), interface: interface, localIP: ip, gateway: gateway,
            pathAvailable: pathAvailable ?? !ip.isEmpty, proxyOrVPN: proxyEnabled || interface.hasPrefix("utun") || interface.hasPrefix("ppp"), probes: probes)
    }
}
