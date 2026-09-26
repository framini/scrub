import Darwin
import Foundation

public enum PrivateFile {
    public static func write(_ data: Data, to destination: URL) throws {
        let manager = FileManager.default
        let directory = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)
        defer { try? manager.removeItem(at: directory) }
        let staging = directory.appendingPathComponent(".scrub-\(UUID().uuidString)")
        let descriptor = open(staging.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var closed = false
        defer {
            if !closed { _ = close(descriptor) }
            if manager.fileExists(atPath: staging.path) { try? manager.removeItem(at: staging) }
        }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                offset += count
            }
        }
        guard fchmod(descriptor, 0o600) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard close(descriptor) == 0 else { closed = true; throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        closed = true
        guard rename(staging.path, destination.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
