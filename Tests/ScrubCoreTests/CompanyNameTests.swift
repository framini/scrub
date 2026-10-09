import Foundation
@testable import ScrubCore
import Testing

/// A name that ends in a company's legal form, in any of its spellings ("m.b.H.", "Ges.m.b.H.", "L.L.C.", "Cía. Ltda."),
/// or holds a word naming a trade or a body ("Banco", "Exchange", "Versicherung", "Société"), is a company's:
/// it stays as written under a payee's or a merchant's key, in a column of names and in a sentence, while the
/// people beside it are replaced. A person's name with "& Co." or "e Hijos" after it is a company's too.
@Suite struct CompanyNameTests {
    static let companies = [
        "Hartwell Bau Gesellschaft m.b.H.", "Lindqvist Handel Ges.m.b.H.", "Norvale Exchange L.L.C.", "Corrigan & Pell L.L.P.",
        "Coralta Banco", "Envíos Quillamar Cía. Ltda.", "Brightwater Seguros", "Ostervald Versicherung", "Société Lumière Vauclain",
        "Grupo Andalán", "Pemberton Logistics", "Fundación Arroyo Claro", "Haldane Capital", "Transportes Ribeira", "Mendes Serviços",
    ]

    @Test(arguments: 1...2)
    func aCompanyUnderAPersonsKeyStays(_ seed: Int) throws {
        for company in Self.companies {
            let record: [String: Any] = ["transaction_id": "TX-50213", "payee_name": company, "merchant": ["name": company],
                                         "payer_name": "Lucía Ferreyra", "amount": 412.5]
            let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            let result = try Scrubber.scrub(data, name: "payment.json", forceFullDetection: false, seed: UInt64(seed))
            let output = String(decoding: result.output, as: UTF8.self)
            #expect(output.components(separatedBy: company).count == 3, "\(company) → \(output)")
            #expect(!output.contains("Lucía") && !output.contains("Ferreyra"), "\(output)")
            #expect(!result.findings.contains { $0.original.contains(company) }, "\(result.findings.map(\.original))")
        }
    }

    @Test func aCompanyInAColumnOfNamesStays() throws {
        let csv = "name,city,amount\n" + Self.companies.map { "\"\($0)\",Quito,120.00" }.joined(separator: "\n") + "\nAna Lucero,Cuenca,80.00\n"
        let result = try Scrubber.scrub(Data(csv.utf8), name: "payees.csv", forceFullDetection: false, seed: 3)
        let output = String(decoding: result.output, as: UTF8.self)
        for company in Self.companies { #expect(output.contains(company), "\(company) → \(output)") }
        #expect(!output.contains("Ana Lucero"), "\(output)")
    }

    @Test(arguments: 1...3)
    func aCompanyInASentenceStaysWhileItsPeopleGo(_ seed: Int) throws {
        let text = """
        Transferencia recibida de Envíos Quillamar Cía. Ltda. por USD 400, autorizada por Laura Méndez.
        Zahlung an Ostervald Versicherung und an Brandt & Co. erledigt, Ansprechpartnerin Wiebke Strothmann.
        Distribuidor: Ramírez e Hijos, contacto Pedro Quispe.
        Le virement de la Société Lumière Vauclain a été reçu, contact Ghislaine Morvillier.
        Payment from Norvale Exchange L.L.C. to Grace Holt was refunded by Coralta Banco.

        """
        let result = try Scrubber.scrub(Data(text.utf8), name: "Pasted text", forceFullDetection: false, seed: UInt64(seed))
        let output = String(decoding: result.output, as: UTF8.self)
        for kept in ["Envíos Quillamar Cía. Ltda.", "Ostervald Versicherung", "Brandt & Co.", "Ramírez e Hijos", "Société Lumière Vauclain", "Coralta Banco", "Norvale Exchange L.L.C."] {
            #expect(output.contains(kept), "\(kept) in \(output)")
        }
        // Each person is replaced, or asked about where the text's language leaves a guess unsure; never left unseen.
        let asked = result.unresolved.compactMap(\.original).joined(separator: " ")
        for gone in ["Laura", "Méndez", "Wiebke", "Strothmann", "Quispe", "Ghislaine", "Morvillier", "Grace", "Holt"] {
            #expect(!output.contains(gone) || asked.contains(gone), "\(gone) in \(output)")
        }
        #expect(!result.findings.contains { ["Ramírez", "Hijos", "Banco", "Exchange", "Versicherung"].contains(where: $0.original.contains) }, "\(result.findings.map(\.original))")
    }

    @Test func aLegalFormIsReadInEverySpelling() {
        for name in ["Example Bau Gesellschaft m.b.H.", "Example Bau GmbH", "Example Handel Ges.m.b.H.", "Example Trading L.L.C.", "Example Trading LLC",
                     "Example Law L.L.P.", "Example Envíos Cía. Ltda.", "Example Holdings P.L.C."] {
            #expect(NameEvidence.companyName(name), "\(name)")
        }
        for name in ["Laura Méndez", "Grace Holt", "Wiebke Strothmann", "Ramírez"] { #expect(!NameEvidence.companyName(name), "\(name)") }
    }
}
