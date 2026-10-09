import Foundation
@testable import ScrubCore
import Testing

/// What sits around an XML document's root is written back as it was: the
/// declaration, the line breaks between the comments before and after the
/// root, and the file's final newline, whatever inside the root is replaced.
struct XMLLayoutTests {
    static func scrub(_ text: String, seed: UInt64 = 1) throws -> String {
        String(decoding: try Scrubber.scrub(Data(text.utf8), name: "export.xml", forceFullDetection: false, seed: seed).output, as: UTF8.self)
    }

    @Test func aPaymentFileKeepsItsFinalNewline() throws {
        let transfer = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Document xmlns="urn:example:pain.001">
          <CstmrCdtTrfInitn>
            <GrpHdr><MsgId>MSG-20261002-0007</MsgId><NbOfTxs>1</NbOfTxs></GrpHdr>
            <PmtInf>
              <Dbtr><Name>Odalys Fenwright</Name></Dbtr>
              <DbtrAcct><Id><IBAN>DE89370400440532013000</IBAN></Id></DbtrAcct>
              <CdtTrfTxInf><Amt><InstdAmt Ccy="EUR">250.00</InstdAmt></Amt></CdtTrfTxInf>
            </PmtInf>
          </CstmrCdtTrfInitn>
        </Document>

        """
        for seed in UInt64(0)..<3 {
            let output = try Self.scrub(transfer, seed: seed)
            #expect(!output.contains("Fenwright") && !output.contains("DE89370400440532013000"), "\(output)")
            #expect(output.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Document"), "\(output)")
            #expect(output.hasSuffix("</Document>\n"), "\(output)")
            #expect(output.filter { $0 == "\n" }.count == transfer.filter { $0 == "\n" }.count)
        }
    }

    @Test func commentsAroundTheRootKeepTheirLines() throws {
        let config = "<?xml version=\"1.0\"?>\r\n<!-- generated 2026-10-02, owner Tobiah Quennell -->\r\n<?xml-stylesheet type=\"text/xsl\" href=\"view.xsl\"?>\r\n<configuration>\r\n  <appSettings>\r\n    <add key=\"AdminContact\" value=\"tobiah.quennell@example.com\"/>\r\n    <add key=\"Retries\" value=\"5\"/>\r\n  </appSettings>\r\n</configuration>\r\n<!-- end of file -->\r\n"
        let output = try Self.scrub(config)
        #expect(!output.contains("Quennell") && !output.contains("tobiah.quennell"), "\(output)")
        #expect(output.hasPrefix("<?xml version=\"1.0\"?>\r\n<!-- generated 2026-10-02, owner "), "\(output.debugDescription)")
        #expect(output.contains(" -->\r\n<?xml-stylesheet type=\"text/xsl\" href=\"view.xsl\"?>\r\n<configuration>\r\n  <appSettings>\r\n"), "\(output.debugDescription)")
        #expect(!output.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "\(output.debugDescription)")
        #expect(output.hasSuffix("</configuration>\r\n<!-- end of file -->\r\n"), "\(output.debugDescription)")
    }
}
