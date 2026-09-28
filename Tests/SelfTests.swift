import Foundation

@MainActor func runSelfTests() {
    var count = 0
    func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
        guard condition() else { fputs("FAIL: \(name)\n", stderr); exit(1) }
        count += 1; print("PASS: \(name)")
    }
    func make(_ gateway: Bool = true, _ dns: Bool = true, _ tcp1: Bool = true, _ tcp2: Bool = true, _ web: Bool = true, code: Int? = 200) -> Snapshot {
        Snapshot(time: Date(), interface: "en0", localIP: "192.0.2.2", gateway: "192.0.2.1", pathAvailable: true, proxyOrVPN: false, probes: [
            Probe(id: "gateway", title: "", target: "", ok: gateway, milliseconds: gateway ? 2 : nil, detail: ""),
            Probe(id: "dns", title: "", target: "example.com", ok: dns, milliseconds: dns ? 20 : nil, detail: ""),
            Probe(id: "tcp1", title: "", target: "", ok: tcp1, milliseconds: tcp1 ? 30 : nil, detail: ""),
            Probe(id: "tcp2", title: "", target: "", ok: tcp2, milliseconds: tcp2 ? 50 : nil, detail: ""),
            Probe(id: "web0", title: "", target: "example.com", ok: web, milliseconds: code != nil ? 80 : nil, detail: "", statusCode: code)
        ])
    }
    expect(diagnose(make()).key == "healthy", "healthy layered result")
    expect(diagnose(make(false)).key == "healthy", "blocked ICMP alone is not outage")
    expect(diagnose(make(true, false)).key == "dns", "DNS failure with successful direct TCP")
    expect(diagnose(make(false, false, false, false, false, code: nil)).key == "path", "all probes failing leaves local/upstream attribution uncertain")
    expect(diagnose(make(true, true, false, false, false, code: nil)).key == "upstream", "gateway reachable but upstream inaccessible")
    expect(diagnose(make(true, true, true, true, false, code: 503)).key == "website", "HTTP 503 is service issue not total network outage")
    expect(diagnose(make(true, true, true, true, false, code: 302)).key == "website", "redirect not accepted as proven target health")
    expect(diagnose(make(true, true, false, false, true)).key == "restricted", "web works through proxy while direct TCP blocked")
    expect(!diagnose(make(true, true, false, false, true)).problematic, "restricted direct TCP does not trigger outage incident")
    expect(diagnose(make(true, true, true, false, true)).key == "partial", "one external target fails")
    var local = make(); local.pathAvailable = false
    expect(diagnose(local).key == "local", "no usable network path")
    local = make(); local.localIP = ""
    expect(diagnose(local).key == "local", "no valid local IP")
    var vpn = make(); vpn.proxyOrVPN = true
    expect(diagnose(vpn).evidence.contains("不同路径"), "VPN caveat retained")
    var slow = make(); slow.probes[2].milliseconds = 800; slow.probes[3].milliseconds = 800
    expect(diagnose(slow).key == "slow", "high latency distinct from disconnection")
    expect(make().externalLatency == 40, "external latency is mean successful TCP RTT")
    expect(make(true, true, false, false).externalLatency == nil, "missing latency is nil not zero")
    var stability = Stability()
    let bad = diagnose(local), good = diagnose(make())
    expect(!stability.ingest(bad), "first anomaly not confirmed")
    expect(!stability.ingest(bad), "second anomaly not confirmed")
    expect(stability.ingest(bad), "third consecutive anomaly confirmed")
    expect(!stability.ingest(bad), "same incident does not notify repeatedly")
    expect(!stability.ingest(good), "first recovery not confirmed")
    expect(stability.ingest(good), "second recovery confirmed")
    stability.reset()
    _ = stability.ingest(bad); _ = stability.ingest(good)
    expect(!stability.ingest(bad) && stability.count == 1, "intermittent failures restart streak")
    expect(Configuration.validate(host: "www.apple.com", websites: "https://example.com\nhttp://localhost:1234") == nil, "valid settings accepted")
    expect(Configuration.validate(host: "--flushcache", websites: "https://example.com") != nil, "malformed DNS label rejected")
    expect(Configuration.validate(host: "a;rm", websites: "https://example.com") != nil, "invalid DNS characters rejected")
    expect(Configuration.validate(host: "example.com", websites: "https://user:pass@example.com") != nil, "embedded credentials rejected")
    expect(Configuration.validate(host: "example.com", websites: "file:///etc/passwd") != nil, "non HTTP scheme rejected")
    expect(Configuration.validate(host: "example.com", websites: "") != nil, "empty target list rejected")
    expect(field("gateway", in: "    gateway: fe80::1%en0\n") == "fe80::1%en0", "IPv6 route parsing retains colons")
    expect(field("HTTPEnable", in: "  HTTPEnable : 1\n") == "1", "system proxy flags parsed")
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("NetworkLens-tests-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let model = Monitor(directory: temporary)
    var failing = make(true, true, true, true, false, code: 503)
    let base = Date()
    for i in 0..<3 { failing.time = base.addingTimeInterval(Double(i * 5)); model.accept(failing) }
    expect(model.incidents.count == 1 && model.incidents[0].end == nil, "confirmed incident persisted once")
    expect(model.incidents[0].start == base, "incident begins at first anomalous sample")
    model.accept(failing)
    expect(model.incidents.count == 1, "continued outage not duplicated")
    var recovered = make(); recovered.time = base.addingTimeInterval(20)
    model.accept(recovered)
    expect(model.incidents[0].end == nil, "incident remains open during first recovery")
    recovered.time = base.addingTimeInterval(25); model.accept(recovered)
    expect(model.incidents[0].ending == "连续两轮恢复可达", "recovery closes incident with reason")
    let reload = Monitor(directory: temporary)
    expect(reload.incidents.count == 1 && reload.incidents[0].end != nil, "event file reloads after restart")
    expect(FileManager.default.fileExists(atPath: temporary.appendingPathComponent("samples.jsonl").path), "real sample log written")
    for i in 0..<3 { failing.time = base.addingTimeInterval(Double(30 + i * 5)); model.accept(failing) }
    model.interruptEvidence("test pause")
    expect(model.incidents.last?.ending == "test pause" && model.stability.count == 0, "pause interrupts evidence without claiming recovery")
    print("\(count) tests passed")
}
