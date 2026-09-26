// Tries every way out of the process and prints one line per attempt: ok,
// denied (the OS refused on policy) or failed (anything else, inconclusive).
// scripts/prove-offline.sh signs it with the app's exact entitlements.
import Darwin
import Foundation
import Network

if CommandLine.arguments.count != 3 || UInt16(CommandLine.arguments[1]) == nil || UInt16(CommandLine.arguments[2]) == nil {
    fputs("Usage: NetworkProbe <tcp-port> <udp-port>\n", stderr)
    exit(2)
}
let tcpPort = UInt16(CommandLine.arguments[1]) ?? 0
let udpPort = UInt16(CommandLine.arguments[2]) ?? 0

enum Outcome {
    case ok(String)
    case denied(String)
    case failed(String)
}

func report(_ name: String, _ outcome: Outcome) {
    switch outcome {
    case .ok(let detail): print("\(name) ok \(detail)")
    case .denied(let reason): print("\(name) denied \(reason)")
    case .failed(let reason): print("\(name) failed \(reason)")
    }
    fflush(stdout)
}

func errnoText() -> String { String(cString: strerror(errno)) }
func permission(_ code: Int32) -> Bool { code == EPERM || code == EACCES }
func socketFailure(_ operation: String) -> Outcome {
    let code = errno
    let detail = "\(operation): \(String(cString: strerror(code)))"
    return permission(code) ? .denied(detail) : .failed(detail)
}
func errorFailure(_ error: Error, label: String) -> Outcome {
    let ns = error as NSError
    let detail = "\(label): \(error.localizedDescription)"
    if ns.domain == NSPOSIXErrorDomain && permission(Int32(ns.code)) { return .denied(detail) }
    if ns.domain == NSURLErrorDomain && ns.localizedDescription.localizedCaseInsensitiveContains("operation not permitted") { return .denied(detail) }
    if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error {
        if case .denied = errorFailure(underlying, label: label) { return .denied(detail) }
    }
    return .failed(detail)
}

func address(_ host: String, _ port: UInt16) -> (sockaddr_storage, socklen_t, Int32) {
    var storage = sockaddr_storage()
    if host.contains(":") {
        var a = sockaddr_in6()
        a.sin6_family = sa_family_t(AF_INET6)
        a.sin6_port = port.bigEndian
        inet_pton(AF_INET6, host, &a.sin6_addr)
        withUnsafeBytes(of: a) { bytes in withUnsafeMutableBytes(of: &storage) { $0.copyMemory(from: bytes) } }
        return (storage, socklen_t(MemoryLayout<sockaddr_in6>.size), AF_INET6)
    }
    var a = sockaddr_in()
    a.sin_family = sa_family_t(AF_INET)
    a.sin_port = port.bigEndian
    inet_pton(AF_INET, host, &a.sin_addr)
    withUnsafeBytes(of: a) { bytes in withUnsafeMutableBytes(of: &storage) { $0.copyMemory(from: bytes) } }
    return (storage, socklen_t(MemoryLayout<sockaddr_in>.size), AF_INET)
}

func tcp(_ host: String, _ port: UInt16) -> Outcome {
    var (storage, length, family) = address(host, port)
    let fd = socket(family, SOCK_STREAM, 0)
    guard fd >= 0 else { return socketFailure("socket") }
    defer { close(fd) }
    var timeout = timeval(tv_sec: 3, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    let result = withUnsafePointer(to: &storage) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, length) } }
    return result == 0 ? .ok("connected") : socketFailure("connect")
}

func udp(_ host: String, _ port: UInt16) -> Outcome {
    var (storage, length, family) = address(host, port)
    let fd = socket(family, SOCK_DGRAM, 0)
    guard fd >= 0 else { return socketFailure("socket") }
    defer { close(fd) }
    let sent = withUnsafePointer(to: &storage) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, "x", 1, 0, $0, length) }
    }
    return sent == 1 ? .ok("sent") : socketFailure("sendto")
}

func dns(_ name: String) -> Outcome {
    var info: UnsafeMutablePointer<addrinfo>?
    let status = getaddrinfo(name, "443", nil, &info)
    defer { if info != nil { freeaddrinfo(info) } }
    if status == 0 { return .ok("resolved") }
    if status == EAI_SYSTEM { return socketFailure("getaddrinfo") }
    return .failed("getaddrinfo: \(String(cString: gai_strerror(status)))")
}

func fetch(_ url: String) -> Outcome {
    guard let target = URL(string: url) else { return .failed("invalid URL") }
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var outcome: Outcome = .failed("timeout")
    var request = URLRequest(url: target)
    request.timeoutInterval = 5
    URLSession(configuration: .ephemeral).dataTask(with: request) { _, response, error in
        if let error { outcome = errorFailure(error, label: "URLSession") }
        else { outcome = .ok("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)") }
        done.signal()
    }.resume()
    _ = done.wait(timeout: .now() + 8)
    return outcome
}

func networkFramework(_ host: String, _ port: UInt16) -> Outcome {
    guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return .failed("invalid port") }
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var outcome: Outcome = .failed("timeout")
    let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
    connection.stateUpdateHandler = { state in
        switch state {
        case .ready: outcome = .ok("ready"); done.signal()
        case .failed(let error): outcome = networkFailure(error); done.signal()
        case .waiting(let error): outcome = networkFailure(error); done.signal()
        default: break
        }
    }
    connection.start(queue: .global())
    _ = done.wait(timeout: .now() + 5)
    connection.cancel()
    return outcome
}

func networkFailure(_ error: NWError) -> Outcome {
    if case .posix(let code) = error, permission(code.rawValue) { return .denied("NWConnection: \(error)") }
    return .failed("NWConnection: \(error)")
}

func child(_ host: String, _ port: UInt16) -> Outcome {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
    process.arguments = ["-z", "-w", "2", host, String(port)]
    process.standardOutput = FileHandle.nullDevice
    let errors = Pipe()
    process.standardError = errors
    do { try process.run() } catch { return errorFailure(error, label: "spawn") }
    process.waitUntilExit()
    if process.terminationStatus == 0 { return .ok("nc connected") }
    let detail = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return detail.localizedCaseInsensitiveContains("operation not permitted") ? .denied("nc: \(detail)") : .failed("nc exit \(process.terminationStatus): \(detail)")
}

report("tcp-ipv4-loopback", tcp("127.0.0.1", tcpPort))
report("tcp-ipv6-loopback", tcp("::1", tcpPort))
report("udp-ipv4-loopback", udp("127.0.0.1", udpPort))
report("udp-ipv6-loopback", udp("::1", udpPort))
report("tcp-ipv4-public", tcp("1.1.1.1", 443))
report("tcp-ipv6-public", tcp("2606:4700:4700::1111", 443))
report("udp-ipv4-public-dns", udp("1.1.1.1", 53))
report("dns-lookup", dns("apple.com"))
report("urlsession-hostname", fetch("https://www.apple.com/"))
report("urlsession-loopback", fetch("http://127.0.0.1:\(tcpPort)/"))
report("network-framework-loopback", networkFramework("127.0.0.1", tcpPort))
report("child-process-loopback", child("127.0.0.1", tcpPort))
