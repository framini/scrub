import Foundation
@testable import ScrubCore
import Testing

/// The name of a published standard or a catalogued flaw is nobody's ID,
/// whichever detector reads it so ("RFC4716" in a man page was replaced by
/// the context model as an ID). Personal IDs beside them still go.
@Suite struct StandardsTests {
    /// A manual page for an invented key tool, with a person and a passport number in a note after it.
    static let prose = """
    -e Reads a private or public key file and prints to stdout a public key in one of the formats the -m option names. The default export format is “RFC4716”. This lets other programs, including several commercial terminal suites, read keys made here.

    -F hostname Searches for the given hostname in a hosts file and lists every entry found. Useful to find hashed host names, and with the -H option to print found keys in hashed form.

    -i Reads an unencrypted private (or public) key file in the format the -m option names and prints a compatible key to stdout. This lets keys made by other software be used here. The default import format is “RFC4716”.

    -m key_format Names a key format for the -i (import) and -e (export) options. The supported key formats are: “RFC4716” (RFC 4716/SSH2 public or private key), “PKCS8” (PKCS8 public or private key) or “PEM” (PEM public key).

    Timestamps follow ISO 8601 and the audit covers ISO/IEC 27001:2013, NIST SP 800-63B and FIPS 140-2; the patch fixes CVE-2021-44228 (CWE-502) on IEEE 802.11ac links.
    Corentin Vasquelle, passport no. 553901274, asked about it on Monday.
    """
    static let standards = ["RFC4716", "RFC 4716", "ISO 8601", "ISO/IEC 27001:2013", "NIST SP 800-63B", "FIPS 140-2", "CVE-2021-44228", "CWE-502", "IEEE 802.11ac", "PKCS8"]

    @Test func standardsAreFound() {
        let found = Standards.ranges(in: Self.prose).map { TextRanges.substring(Self.prose, $0) }
        for name in Self.standards where name != "PKCS8" { #expect(found.contains(name), "\(name) in \(found)") }
        #expect(Standards.ranges(in: "passport no. 553901274, case 4471, room B12").isEmpty)
    }

    @Test func standardsStayOnEveryPath() throws {
        for path in PIIGaps.InputPath.allCases {
            let (data, name) = PIIGaps.wrap(Self.prose, path)
            for seed in UInt64(1)...3 {
                let result = try Scrubber.scrub(data, name: name, forceFullDetection: false, seed: seed)
                let output = PIIGaps.readable(result.output, path)
                for standard in Self.standards { #expect(output.contains(standard), "\(path): \(standard) changed in \(output)") }
                // Type oracle: the person and the passport number still go, the number as nine digits.
                #expect(!output.contains("Vasquelle") && !output.contains("553901274"), "\(path): \(output)")
                #expect(output.firstMatch(of: /passport no\. \d{9}/) != nil, "\(path): \(output)")
            }
        }
    }
}
