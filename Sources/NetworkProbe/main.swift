// Tries every way out of the process and prints one line per attempt:
// "<probe> ok" when it got through, "<probe> refused <reason>" when it did not.
// scripts/prove-offline.sh signs it with the app's exact entitlements.
// Usage: NetworkProbe <tcp-port> <udp-port>, for listeners on 127.0.0.1 and ::1
import Darwin
import Foundation
import Network

let tcpPort = UInt16(CommandLine.arguments[1])!
let udpPort = UInt16(CommandLine.arguments[2])!

enum Outcome {
    case ok(String)
    case refused(String)
}

func report(_ name: String, _ outcome: Outcome) {
    switch outcome {
    case .ok(let detail): print("\(name) ok \(detail)")
    case .refused(let reason): print("\(name) refused \(reason)")
    }
    fflush(stdout)
}

func errnoText() -> String { String(cString: strerror(errno)) }

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
    guard fd >= 0 else { return .refused("socket: \(errnoText())") }
    defer { close(fd) }
    var timeout = timeval(tv_sec: 3, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    let result = withUnsafePointer(to: &storage) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, length) } }
    return result == 0 ? .ok("connected") : .refused("connect: \(errnoText())")
}

func udp(_ host: String, _ port: UInt16) -> Outcome {
    var (storage, length, family) = address(host, port)
    let fd = socket(family, SOCK_DGRAM, 0)
    guard fd >= 0 else { return .refused("socket: \(errnoText())") }
    defer { close(fd) }
    let sent = withUnsafePointer(to: &storage) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, "x", 1, 0, $0, length) }
    }
    return sent == 1 ? .ok("sent") : .refused("sendto: \(errnoText())")
}

func dns(_ name: String) -> Outcome {
    var info: UnsafeMutablePointer<addrinfo>?
    let status = getaddrinfo(name, "443", nil, &info)
    defer { if info != nil { freeaddrinfo(info) } }
    return status == 0 ? .ok("resolved") : .refused("getaddrinfo: \(String(cString: gai_strerror(status)))")
}

func fetch(_ url: String) -> Outcome {
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var outcome: Outcome = .refused("timeout")
    var request = URLRequest(url: URL(string: url)!)
    request.timeoutInterval = 5
    URLSession(configuration: .ephemeral).dataTask(with: request) { _, response, error in
        if let error { outcome = .refused("URLSession: \(error.localizedDescription)") }
        else { outcome = .ok("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)") }
        done.signal()
    }.resume()
    _ = done.wait(timeout: .now() + 8)
    return outcome
}

func networkFramework(_ host: String, _ port: UInt16) -> Outcome {
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var outcome: Outcome = .refused("timeout")
    let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    connection.stateUpdateHandler = { state in
        switch state {
        case .ready: outcome = .ok("ready"); done.signal()
        case .failed(let error): outcome = .refused("NWConnection: \(error)"); done.signal()
        case .waiting(let error): outcome = .refused("NWConnection waiting: \(error)"); done.signal()
        default: break
        }
    }
    connection.start(queue: .global())
    _ = done.wait(timeout: .now() + 5)
    connection.cancel()
    return outcome
}

func child(_ host: String, _ port: UInt16) -> Outcome {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
    process.arguments = ["-z", "-w", "2", host, String(port)]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return .refused("spawn: \(error.localizedDescription)") }
    process.waitUntilExit()
    return process.terminationStatus == 0 ? .ok("nc connected") : .refused("nc exit \(process.terminationStatus)")
}

report("tcp-ipv4-loopback", tcp("127.0.0.1", tcpPort))
report("tcp-ipv6-loopback", tcp("::1", tcpPort))
report("udp-ipv4-loopback", udp("127.0.0.1", udpPort))
report("udp-ipv6-loopback", udp("::1", udpPort))
report("tcp-ipv4-public", tcp("1.1.1.1", 443))
report("tcp-ipv6-public", tcp("2606:4700:4700::1111", 443))
report("udp-ipv4-public-dns", udp("1.1.1.1", 53))
report("dns-lookup", dns("example.com"))
report("urlsession-hostname", fetch("https://example.com/"))
report("urlsession-loopback", fetch("http://127.0.0.1:\(tcpPort)/"))
report("network-framework-loopback", networkFramework("127.0.0.1", tcpPort))
report("child-process-loopback", child("127.0.0.1", tcpPort))
