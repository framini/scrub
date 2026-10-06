import Foundation

/// The names of published standards and catalogued flaws: "RFC 4716" or
/// "RFC4716", "ISO 8601", "ISO/IEC 27001:2013", "IEEE 802.11ac",
/// "CVE-2021-44228", "CWE-79", "ECMA-262", "FIPS 140-2", "NIST SP 800-63B",
/// "ITU-T X.509", "PKCS #8", "BCP 47". Each reads the same for everyone who
/// cites it, so it is never someone's ID, number or secret, whichever
/// detector took it for one.
enum Standards {
    /// A body's own prefix, then the document's number: digits, perhaps in
    /// parts ("802.11", "800-63", "27001:2013") and with a letter or two after.
    private static let pattern = TextPattern(
        #"(?<![\p{L}\p{N}_])(?:(?:RFC|rfc|BCP|STD|ISO(?:/IEC)?(?:/IEEE)?|IEC|IEEE|ANSI|ASTM|ECMA|ETSI|FIPS(?:[ \t]+PUB)?|NIST(?:[ \t]+(?:SP|IR))?|ITU-[TR](?:[ \t]+[A-Z])?|CVE|cve|CWE|CAPEC|PKCS|DIN|BS|JIS|EN)"#
        + #"(?:[ \t]*[-#/]?[ \t]*|[ \t]+No\.?[ \t]*)\d+(?:[-.:/]\d+)*[A-Za-z]{0,3}|X\.\d{3})(?![\p{L}\p{N}_])"#)
    /// What a standard's name can be taken for.
    static let numbered: Set<String> = ["ID_NUMBER", "SECRET", "USERNAME", "US_PASSPORT", "US_BANK_NUMBER", "US_DRIVER_LICENSE", "US_ITIN", "US_SSN", "PHONE_NUMBER", "DATE_OF_BIRTH", "POSTAL_CODE"]

    static func ranges(in text: String) -> [Range<Int>] {
        TextRanges.matches(pattern, in: text).map { $0.range.location..<NSMaxRange($0.range) }
    }

    /// `spans` without the numbers that lie inside a standard's name. A value
    /// a key names in full ("national_id": …) keeps what its key says.
    static func outside(_ spans: [Span], in text: String) -> [Span] {
        let length = (text as NSString).length
        // A value its key names whole, or an identifier a word names ("logbook BS77BOE": a plate, not British Standard 77), is no standard.
        func judged(_ span: Span) -> Bool { numbered.contains(span.entity) && !(span.score == 1 && (span.range == 0..<length || Recognizers.drawn.contains(span.entity))) }
        guard spans.contains(where: judged) else { return spans }
        let named = ranges(in: text)
        guard !named.isEmpty else { return spans }
        return spans.filter { span in !(judged(span) && named.contains { $0.lowerBound <= span.range.lowerBound && span.range.upperBound <= $0.upperBound }) }
    }
}
