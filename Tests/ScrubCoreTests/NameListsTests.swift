import Foundation
@testable import ScrubCore
import Testing

@Test func theNameListsLoadOnlyAsShipped() throws {
    // Loaded from the bundle and checked against the checksum in code.
    #expect(NameLists.shared.first.count > 5000 && NameLists.shared.surname.count > 20000 && NameLists.shared.ordinary.count > 20000)
    let url = try #require(ModelResources.bundle?.url(forResource: "NameLists", withExtension: "txt"))
    var data = try Data(contentsOf: url)
    #expect(NameLists.parse(data) != nil)
    data.append(contentsOf: Array("[first]\nzzyzx\n".utf8))
    #expect(NameLists.parse(data) == nil, "an altered list is refused")
}

@Test func namesThatAreWordsAreMarkedSo() {
    // Evidence, not verdicts: a name that is also a word needs a cue.
    for name in ["Emma", "Mary", "Okonkwo"] where NameLists.isFirst(name) || NameLists.isSurname(name) { #expect(NameLists.isName(name), "\(name)") }
    for word in ["Rose", "Will", "Hunter", "June", "Day", "Long"] { #expect(!NameLists.isName(word) && NameLists.isWordlike(word), "\(word)") }
    for word in ["advisers", "article", "database"] { #expect(NameLists.isOrdinary(word), "\(word)") }
}
