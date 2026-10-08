import Foundation

/// An address in any country's own layout, read piece by piece: each piece
/// between commas or line breaks is a unit or post office box, a street, a
/// locality (a postcode with its city or region), a country, or a place name
/// (a district, a county, a building). Its stand-in keeps every piece in its
/// place and every separator as written, so "Lindenhofer Straße 48a⏎70178
/// Stuttgart" becomes "Ahornstraße 12⏎80331 München", and one in the US,
/// Canada, the UK or Australia takes its city, region and postcode from one real place.
struct AddressBlock {
    enum Role: Equatable { case country, unit, street, locality, place }

    struct Locality: Equatable {
        /// The postcode as written, without a country prefix or label ("D-", "CEP").
        var postal: String?
        var city: String?
        var region: String?
    }

    let pieces: [String]
    let separators: [String]
    let roles: [Role]
    /// What each locality piece holds, by the piece's index, in order.
    let localities: [(index: Int, locality: Locality)]
    /// The country, from a country piece, a postcode's shape, a known city or the street's words; nil when none says.
    let country: String?

    /// The locality the address is placed by: the first with a postcode, or the first.
    var main: Locality? { (localities.first { $0.locality.postal != nil } ?? localities.first)?.locality }

    /// Commas, line breaks, bullets and bars part an address's pieces, and so does a dash with spaces round it ("BP 77496 - 47350 Lachapelle").
    private static let pieceBreak = TextPattern(#"[ \t]*(?:,|;|·|•|\|)[ \t]*(?:\r?\n[ \t]*)?|[ \t]*\r?\n[ \t]*|[ \t]+[-–][ \t]+"#)

    /// The pieces of `text`, or nil for anything an address is not: more than
    /// eight pieces, a piece over 64 characters, or no street, unit or postcode.
    static func read(_ text: String) -> AddressBlock? {
        let ns = text as NSString
        guard ns.length <= 400 else { return nil }
        var pieces: [String] = [], separators: [String] = [], start = 0
        for match in TextRanges.matches(pieceBreak, in: text) {
            pieces.append(ns.substring(with: NSRange(location: start, length: match.range.location - start)))
            separators.append(ns.substring(with: match.range))
            start = NSMaxRange(match.range)
        }
        pieces.append(ns.substring(from: start))
        guard pieces.count <= 8, pieces.allSatisfy({ !$0.trimmingCharacters(in: .whitespaces).isEmpty && $0.count <= 64 }) else { return nil }
        var roles: [Role] = [], localities: [(index: Int, locality: Locality)] = [], countries: [String] = []
        for (index, piece) in pieces.enumerated() {
            if let country = countryName(piece) {
                roles.append(.country); countries.append(country)
            } else if isUnit(piece) {
                roles.append(.unit)
            } else if isStreet(piece) || !piece.contains(where: \.isNumber) && namesStreet(piece) && !readsAsBuilding(piece) {
                // "Hauptstraße" or "Sallow Lane" with no number is a street all the same.
                roles.append(.street)
            } else if let locality = locality(piece) {
                roles.append(.locality); localities.append((index, locality))
            } else if piece.contains(where: \.isNumber) {
                roles.append(.street)
            } else {
                roles.append(.place)
            }
        }
        // "Austin" over "TX 78701", or "São Paulo - SP" over "01310-930": a place
        // right before a locality with no city is that city.
        // "Cap-de-la-Madeleine, QC, G8W 5L1": a region on its own before the postcode, the city before that.
        for (position, item) in localities.enumerated() where item.locality.city == nil && item.index > 0 && roles[item.index - 1] == .place {
            var filled = item.locality
            var before = item.index - 1
            let piece = pieces[before].trimmingCharacters(in: .whitespaces)
            if filled.region == nil, Places.region(piece) != nil && (piece == piece.uppercased() || piece.count > 3) || Places.regionAbroad(piece) != nil {
                filled.region = piece
                roles[before] = .locality
                localities.append((before, Locality(postal: nil, city: nil, region: piece)))
                guard before > 0, roles[before - 1] == .place else { localities[position].locality = filled; continue }
                before -= 1
            }
            let named = cityAndRegion(pieces[before])
            filled.city = named.city
            filled.region = filled.region ?? named.region
            localities[position].locality = filled
            roles[before] = .locality
            localities.append((before, Locality(postal: nil, city: named.city, region: named.region)))
        }
        localities.sort { $0.index < $1.index }
        guard roles.contains(where: { $0 == .street || $0 == .unit }) || localities.contains(where: { $0.locality.postal != nil }) else { return nil }
        let country = countries.first ?? Self.country(localities: localities.map(\.locality), streets: zip(pieces, roles).filter { $0.1 == .street }.map(\.0),
                                                      units: zip(pieces, roles).filter { $0.1 == .unit || $0.1 == .place }.map(\.0))
        return AddressBlock(pieces: pieces, separators: separators, roles: roles, localities: localities, country: country)
    }

    // MARK: Pieces

    private static let unitWords = #"flat|apt|apartment|appt|app|apto|bât|suite|ste|unit|floor|fl|level|lvl|room|rm|bldg|block|blk|shop|lot|plot|pmb|top|wohnung|bâtiment|bat|piso|escalier|étage|etage|bureau|sala|bloco|int|depto|kat|lgh|house no|no"#
    private static let boxWords = #"p\.?\s?o\.?\s?box|post office box|gpo box|locked bag|private bag|postfach|postbus|postboks|b\.?p\.?|cs|apartado(?: de correos)?|casella postale|box|c\.?p\.?|caixa postal"#
    private static let unit = TextPattern(#"(?i)^\s*(?:(?:"# + unitWords + #")(?![\p{L}])\.?\s*[#n°º.]*\s*[\p{L}\d][\p{L}\d./-]{0,7}|#\s?\d[\d-]*|\d{1,2}(?:st|nd|rd|th|e|er|ème|\.)?\s+(?:floor|étage|piso|og|stock|andar|etg|etasje|kerros)|(?:ground|first|second|third|fourth|fifth|top|lower|upper)\s+floor|rez-de-chaussée|bajo|r/c|\d{1,2}\s?[º°ª]\s*(?:[\p{L}]{1,5}\.?)?|\d{1,2}\.\s?(?:th|tv|mf|sal)\.?|\d{1,2}[rª]\s+\d{1,2}[ªa]|(?:"# + boxWords + #")\s*\d[\d ]*(?:\s+(?:stn|station)\s+\p{L}+)?)\s*$"#)
    static func isUnit(_ piece: String) -> Bool { !TextRanges.matches(unit, in: piece).isEmpty }

    /// Words that name a kind of street, on their own or ending one: "Rue", "Via", "Straße", "-gracht".
    static let streetKinds: Set<String> = ["rue", "avenue", "av", "avda", "boulevard", "bd", "bvd", "allée", "impasse", "chemin", "quai", "route", "cours", "passage", "chaussée",
                                           "via", "viale", "piazza", "piazzale", "corso", "largo", "vicolo", "strada", "lungomare", "calle", "c/", "avenida", "plaza", "pza", "paseo",
                                           "camino", "ronda", "travesía", "carrera", "calz", "calzada", "rua", "r", "travessa", "praça", "estrada", "alameda", "ul", "ulica", "al", "aleja",
                                           "os", "straße", "strasse", "str", "weg", "platz", "gasse", "allee", "gate", "vei", "veien", "plass", "gade", "vej", "gata", "gatan", "vägen",
                                           "katu", "tie", "straat", "laan", "gracht", "plein", "kade", "dijk", "steeg", "jalan", "blk", "náměstí", "nábřeží", "třída",
                                           "street", "st", "road", "rd", "lane", "ln", "drive", "close", "crescent", "way", "place", "terrace", "court", "highway", "square",
                                           "gardens", "grove", "mews", "rise", "walk", "parade", "quay", "ave"]
    static let streetSuffixes = ["straße", "strasse", "str.", "weg", "gasse", "platz", "allee", "ring", "damm", "ufer", "steig", "pfad", "straat", "laan", "gracht", "plein",
                                 "kade", "singel", "dijk", "steeg", "gatan", "vägen", "gränd", "torget", "stigen", "gade", "vej", "allé", "stræde", "veien", "vegen",
                                 "gata", "katu", "tie", "kuja", "polku", "gaden", "vejen", "torvet"]
    static let englishKinds: Set<String> = ["st", "street", "rd", "road", "ave", "av", "avenue", "blvd", "boulevard", "dr", "drive", "ln", "lane", "ct", "court", "way", "pl", "place",
                                            "pkwy", "parkway", "ter", "terrace", "cir", "circle", "hwy", "highway", "trl", "trail", "loop", "sq", "square", "close", "cl", "crescent",
                                            "cres", "gardens", "gdns", "grove", "gr", "mews", "rise", "row", "walk", "parade", "pde", "tce", "view", "green", "vale", "hill", "chase",
                                            "wharf", "esplanade", "esp", "circuit", "cct", "quay", "yard", "path", "pike", "alley", "bvd"]
    /// A piece that is a street by its words, with or without a number: "Rua Calçada do Mirante", "Av. Insurgentes Sur 1602".
    static func isStreet(_ piece: String) -> Bool {
        let words = piece.split(whereSeparator: { $0 == " " || $0 == "\t" }).map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".,")) }
        guard let first = words.first, words.count >= 2 else { return false }
        if streetKinds.contains(first) { return true }
        // "9999 Sevilla St", "64 Buzard Lane": a number and a name ending in a kind of street.
        if let last = words.last, englishKinds.contains(last), piece.contains(where: \.isNumber) { return true }
        return words.contains { word in streetSuffixes.contains { word.hasSuffix($0) && word.count > $0.count + 2 } } && piece.contains(where: \.isNumber)
    }

    /// Words that end a building's or a street's name: "Corrib House", "Wexley Lane".
    static let placeWords: Set<String> = ["house", "court", "lodge", "cottage", "mansions", "building", "point", "tower", "hall", "barn", "farm", "works", "mill", "place",
                                          "wharf", "apartments", "residency", "towers", "enclave", "heights", "complex", "plaza", "centre", "center", "hub", "residences",
                                          "suites", "yard", "forge", "granary", "rectory", "chambers", "studios", "street", "road", "lane", "avenue", "drive", "close",
                                          "crescent", "gardens", "grove", "terrace", "way", "walk", "mews", "rise", "row", "square", "hill", "parade", "quay", "torre", "edificio"]
    /// A name that reads as a building's, a unit's or a street's rather than a person's.
    static func readsAsPlace(_ value: String) -> Bool {
        let words = value.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".,")) }
        guard let first = words.first, let last = words.last else { return false }
        // One word alone ("Lane", "Court") is as often a person's name.
        guard words.count >= 2 else { return isUnit(value) }
        return isUnit(value) || placeWords.contains(last) || placeWords.contains(first) || first == "the" || streetKinds.contains(first) || isStreet(value)
            || value.range(of: "(?i)^(?:" + boxWords + ")$", options: .regularExpression) != nil
    }

    /// An address typed all in lowercase, cased as it would be written so it
    /// reads as one: "14 rookery lane, leeds ls6 2ab" → "14 Rookery Lane, Leeds LS6 2AB",
    /// "kerkstraat 41, 3511 lx utrecht" → "Kerkstraat 41, 3511 LX Utrecht". Nil for
    /// text with a capital letter or none at all.
    static func cased(_ text: String) -> String? {
        guard text.contains(where: \.isLetter), !text.contains(where: \.isUppercase) else { return nil }
        var words: [(range: Range<String.Index>, core: String)] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard !text[index].isWhitespace else { index = text.index(after: index); continue }
            var end = index
            while end < text.endIndex, !text[end].isWhitespace { end = text.index(after: end) }
            words.append((index..<end, String(text[index..<end]).trimmingCharacters(in: CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "'’")))))
            index = end
        }
        var result = text
        for (position, word) in words.enumerated().reversed() {
            let core = word.core
            guard core.contains(where: \.isLetter) else { continue }
            let next = position + 1 < words.count ? words[position + 1].core : ""
            let previous = position > 0 ? words[position - 1].core : ""
            let written: String
            if core.contains(where: \.isNumber) {
                // A postcode or a unit's number: "ls6", "2ab", "4b", "n1e".
                written = String(text[word.range]).uppercased()
            } else if core.count <= 3, core.allSatisfy(\.isLetter), !keptLower.contains(core), !caseUnits.contains(core),
                      next.contains(where: \.isNumber) && next.contains(where: \.isLetter) || next.count >= 4 && next.allSatisfy(\.isNumber)
                        || core.count <= 2 && previous.count == 4 && previous.allSatisfy(\.isNumber) {
                // A region's code before its postcode ("il 60610", "on n2a 3k9", "vic 3066"), a Dutch postcode's letters ("3511 lx").
                written = String(text[word.range]).uppercased()
            } else if keptLower.contains(core) {
                continue
            } else {
                // "berlin-mitte" → "Berlin-Mitte", "jean-jaurès" → "Jean-Jaurès".
                var capitalNext = true
                written = String(text[word.range].map { character -> Character in
                    let upper = character.uppercased()
                    let out = capitalNext && character.isLetter && upper.count == 1 ? Character(upper) : character
                    if character.isLetter || character.isNumber { capitalNext = false } else if character == "-" || character == "/" { capitalNext = true }
                    return out
                })
            }
            result.replaceSubrange(word.range, with: written)
        }
        return result == text ? nil : result
    }
    /// Words a written address keeps in lowercase: articles and links in its languages.
    private static let keptLower: Set<String> = ["de", "la", "las", "los", "le", "les", "des", "du", "del", "dei", "della", "delle", "degli", "das", "da", "do", "dos", "di",
                                                 "van", "der", "den", "het", "am", "an", "im", "auf", "of", "the", "and", "y", "e", "et", "und", "en", "au", "aux", "bis", "ter",
                                                 "l'", "d'", "i", "nº", "n", "og", "och"]
    private static let caseUnits: Set<String> = ["apt", "ste", "no", "top", "box", "po", "bp", "cs", "al", "ul", "os", "pl", "av", "rd", "st", "dr", "ln", "ct", "int", "lgh", "kat", "fl", "rm"]

    /// The pieces of an address, as `read` parts them, without their separators.
    static func pieces(_ text: String) -> [String] {
        let ns = text as NSString
        var pieces: [String] = [], start = 0
        for match in TextRanges.matches(pieceBreak, in: text) {
            pieces.append(ns.substring(with: NSRange(location: start, length: match.range.location - start)).trimmingCharacters(in: .whitespaces))
            start = NSMaxRange(match.range)
        }
        pieces.append(ns.substring(from: start).trimmingCharacters(in: .whitespaces))
        return pieces.filter { !$0.isEmpty }
    }

    /// A piece that names a street by its words alone, with no number: "Hauptstraße",
    /// "Church Lane", "rue des Lilas", "Strandvejen".
    static func namesStreet(_ piece: String) -> Bool {
        let words = piece.split(whereSeparator: { $0 == " " || $0 == "\t" }).map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".,")) }
        guard let first = words.first, let last = words.last else { return false }
        if words.count >= 2 && (streetKinds.contains(first) || englishKinds.contains(last)) { return true }
        return words.contains { word in streetSuffixes.contains { word.hasSuffix($0) && word.count > $0.count + 2 } }
    }

    /// A piece whose last word is a building's, not a street's: "Kestrel House", "Pear Tree Cottage".
    private static func readsAsBuilding(_ piece: String) -> Bool {
        guard let last = piece.split(separator: " ").last?.lowercased() else { return false }
        return ["house", "cottage", "lodge", "farm", "barn", "manor", "grange", "mill", "hall", "croft", "rectory", "vicarage", "granary", "forge", "stables",
                "manse", "chapel", "malthouse", "mansions", "tower", "building", "centre", "center"].contains(last)
    }

    /// A piece that names a building or a house: "The Old Rectory", "Honeysuckle Cottage", "Kestrel House".
    static func namesBuilding(_ piece: String) -> Bool {
        piece.split(separator: " ").count >= 2 && readsAsPlace(piece)
    }

    /// Whether the piece names a city, region, county or country Scrub knows,
    /// in any case: "Leeds", "berlin-mitte", "Co. Galway", "Oxfordshire", "Germany".
    static func knownPlace(_ piece: String) -> Bool {
        let lower = piece.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        if lower.range(of: #"^(?:co\.?|county)\s+\p{L}"#, options: .regularExpression) != nil { return true }
        let words = lower.split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init)
        for start in words.indices {
            for end in start..<min(words.count, start + 3) where knownPlaces.contains(words[start...end].joined(separator: " ")) { return true }
        }
        return false
    }
    /// Whether the words are, all of them, a place Scrub knows by name.
    static func isKnownPlace(_ words: String) -> Bool { knownPlaces.contains(words.lowercased()) }
    private static let knownPlaces: Set<String> = {
        var names = Set(Places.all.map { $0.city.lowercased() } + Places.abroad.map { $0.city.lowercased() } + Places.regions.map { $0.name.lowercased() })
        names.formUnion(countries.keys.filter { $0.count > 2 })
        names.formUnion(counties)
        return names
    }()
    /// Counties of Britain and Ireland, which a house's address often ends with.
    static let counties: Set<String> = ["oxfordshire", "warwickshire", "gloucestershire", "hertfordshire", "buckinghamshire", "wiltshire", "somerset", "dorset", "devon", "cornwall",
                                        "cumbria", "essex", "kent", "surrey", "suffolk", "norfolk", "shropshire", "herefordshire", "worcestershire", "lincolnshire", "hampshire",
                                        "cambridgeshire", "northumberland", "derbyshire", "powys", "gwynedd", "aberdeenshire", "perthshire", "fife", "argyll", "lancashire",
                                        "cheshire", "staffordshire", "leicestershire", "rutland", "berkshire", "north yorkshire", "east sussex", "west sussex", "county durham",
                                        "nottinghamshire", "northamptonshire", "bedfordshire", "west yorkshire", "south yorkshire", "merseyside", "east riding of yorkshire",
                                        "isle of wight", "midlothian", "east lothian", "west lothian", "ayrshire", "dumfriesshire", "inverness-shire", "ross-shire", "sutherland",
                                        "pembrokeshire", "carmarthenshire", "ceredigion", "monmouthshire", "denbighshire", "flintshire", "anglesey"]

    /// Whether the text holds something only an address does: a kind of street
    /// ("Lane", "rue", "-straße"), a unit or a box, a postcode beside a place or
    /// in a shape no other number has, or a region, country or city Scrub knows.
    /// Capitalised words around a number ("Summary Total 370 Complete") hold none.
    static func hasCue(_ text: String) -> Bool {
        // Written all in lowercase, the cue is a postcode, a unit or box with its number, or a place Scrub knows, in any case ("3511 lx utrecht").
        if text.contains(where: \.isLetter), !text.contains(where: \.isUppercase), text.contains(where: \.isNumber), AddressModel.accepts(text) { return true }
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "/" && $0 != "'" && $0 != "-" }).map(String.init)
        let lower = words.map { $0.lowercased() }
        if lower.contains(where: { streetKinds.contains($0) || unitNames.contains($0) }) { return true }
        if lower.contains(where: { word in streetSuffixes.contains { word.hasSuffix($0.trimmingCharacters(in: CharacterSet(charactersIn: "."))) && word.count > $0.count + 2 } }) { return true }
        if !TextRanges.matches(boxCue, in: text).isEmpty || !TextRanges.matches(shapedPostcode, in: text).isEmpty { return true }
        for (index, word) in words.enumerated() {
            if Places.region(word) != nil && word == word.uppercased() && word.count >= 2 || Places.regionAbroad(word) != nil || countryName(word) != nil && word.count > 2 { return true }
            if word.first?.isUppercase == true, knownCountry(city: word) != nil { return true }
            // "70178 Stuttgart", "Leeds 6011": a postcode's digits beside a place's name.
            if word.count >= 4, word.count <= 6, word.allSatisfy(\.isNumber), [index - 1, index + 1].contains(where: { words.indices.contains($0) && words[$0].first?.isUppercase == true && !words[$0].contains(where: \.isNumber) }) { return true }
        }
        return false
    }
    private static let unitNames: Set<String> = ["flat", "apt", "apartment", "appt", "apto", "suite", "ste", "unit", "floor", "level", "room", "bldg", "building", "block", "blk", "shop",
                                                 "lot", "plot", "pmb", "wohnung", "bâtiment", "piso", "escalier", "étage", "bureau", "sala", "bloco", "depto", "house", "cottage", "farm"]
    private static let boxCue = TextPattern(#"(?i)(?<![\p{L}])(?:"# + boxWords + #")\s*\d"#)
    /// Postcodes in a shape that is no plain number: Canadian, British, Irish, Dutch, Portuguese, Polish, Brazilian, Japanese, Swedish and Czech.
    private static let shapedPostcode = TextPattern(#"(?<![\p{L}\d/-])(?:[A-Z]{1,2}-)?(?:[A-Z]\d[A-Z] ?\d[A-Z]\d|[A-Z]{1,2}\d[A-Z\d]? ?\d[A-Z]{2}|[AC-FHKNPRTV-Y]\d[\dW] ?[0-9AC-FHKNPRTV-Y]{4}|\d{4} ?[A-Z]{2}|\d{5}-\d{3}|\d{4}-\d{3}|\d{3}-\d{4}|\d{2}-\d{3}|\d{3} \d{2})(?![\p{L}\d/-])"#)

    /// Postcodes by the shapes countries write them in, most particular first.
    /// A number beside a "/" is a house's ("1207/12"), not a postcode.
    static let postcode = TextPattern(#"(?<![\p{L}\d/-])(?:[A-Z]{1,2}-)?(?:[A-Z]\d[A-Z] ?\d[A-Z]\d|[A-Z]{1,2}\d[A-Z\d]? ?\d[A-Z]{2}|[AC-FHKNPRTV-Y]\d[\dW] ?[0-9AC-FHKNPRTV-Y]{4}|\d{4} ?[A-Z]{2}|\d{5}-\d{3,4}|\d{4}-\d{3}|\d{3}-\d{4}|\d{2}-\d{3}|\d{3} \d{2}|\d{4,6})(?![\p{L}\d/-])"#)
    private static let label = TextPattern(#"(?i)^(?:c\.?\s?p\.?|cep|zip|postcode|plz)\s*:?\s*"#)

    /// A piece holding a postcode, with the words beside it: "Leeds LS6 2AB",
    /// "70178 Stuttgart", "ID 83702", "Fitzroy VIC 3065", "Singapore 520418",
    /// "50122 Firenze (FI)"; or a known city with its district ("Dublin 1").
    static func locality(_ piece: String) -> Locality? {
        var text = piece.trimmingCharacters(in: .whitespaces)
        if let match = TextRanges.matches(label, in: text).first { text = String((text as NSString).substring(from: NSMaxRange(match.range))) }
        let ns = text as NSString
        let matches = TextRanges.matches(postcode, in: text)
        guard let match = matches.last, matches.count == 1 else {
            let named = cityAndRegion(text)
            return matches.isEmpty && text.range(of: #"^\p{L}[\p{L} .'-]* \d{1,2}[A-Z]?$"#, options: .regularExpression) != nil && knownCountry(city: named.city ?? "") != nil ? named : nil
        }
        let code = ns.substring(with: match.range)
        let postal = code.range(of: #"^[A-Z]{1,2}-"#, options: .regularExpression).map { String(code[$0.upperBound...]) } ?? code
        // The city and region sit on one side of the postcode, written as they are in the piece.
        let before = ns.substring(to: match.range.location), after = ns.substring(from: NSMaxRange(match.range))
        let edges = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "-–,/"))
        var side = (before.contains(where: \.isLetter) ? before : after).trimmingCharacters(in: edges)
        if before.contains(where: \.isLetter) && after.contains(where: \.isLetter) { return nil }
        // A locality holds no house number, only a district's ("Praha 2"): "12 Long Street 8001" is a street.
        let words = side.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard words.dropLast().allSatisfy({ !$0.contains(where: \.isNumber) }), words.last.map({ !$0.contains(where: \.isNumber) || $0.count <= 2 && $0.allSatisfy(\.isNumber) }) ?? true, words.count <= 6 else { return nil }
        var region: String?
        // A region in brackets ("Firenze (FI)"), or its code or name after the city ("Fitzroy VIC", "Bengaluru, Karnataka");
        // one capital letter is a district ("København K").
        if let bracket = side.range(of: #"\s*\(([^()]{1,30})\)$"#, options: .regularExpression) {
            region = String(side[bracket]).trimmingCharacters(in: CharacterSet(charactersIn: " ()"))
            side = String(side[..<bracket.lowerBound]).trimmingCharacters(in: edges)
        } else if Places.region(side).map({ _ in side.count > 3 || side == side.uppercased() }) == true || Places.regionAbroad(side) != nil {
            return Locality(postal: postal, city: nil, region: side)
        } else if let last = side.split(separator: " ").last.map(String.init), side.contains(" "),
                  Places.region(last) != nil && last == last.uppercased() || Places.regionAbroad(last) != nil
                    || last.count >= 2 && last.count <= 4 && last == last.uppercased() && last.allSatisfy(\.isLetter) && side.dropLast(last.count) != side.dropLast(last.count).uppercased() {
            region = last
            side = String(side.dropLast(last.count)).trimmingCharacters(in: edges)
        }
        return Locality(postal: postal, city: side.isEmpty ? nil : side, region: region)
    }

    /// "São Paulo - SP" is a city and its region; "Tamworth" a city alone.
    static func cityAndRegion(_ piece: String) -> Locality {
        let text = piece.trimmingCharacters(in: .whitespaces)
        if let match = text.range(of: #"^(.+?)\s*[-–/]\s*([A-Z]{2,4})$"#, options: .regularExpression) {
            let whole = String(text[match])
            if let split = whole.range(of: #"\s*[-–/]\s*[A-Z]{2,4}$"#, options: .regularExpression) {
                return Locality(postal: nil, city: String(whole[..<split.lowerBound]), region: String(whole[split].drop { !$0.isLetter }))
            }
        }
        return Locality(postal: nil, city: text, region: nil)
    }

    private static let countries: [String: String] = {
        var table: [String: String] = [:]
        let list = "US:usa,us,u.s.a,u.s,united states,united states of america,america|CA:canada|GB:uk,u.k,united kingdom,great britain,england,scotland,wales,northern ireland|AU:australia|NZ:new zealand,nz,aotearoa|IE:ireland,éire,eire,republic of ireland|DE:germany,deutschland|FR:france|NL:netherlands,the netherlands,nederland,holland|BE:belgium,belgique,belgië,belgien|ES:spain,españa,espana|IT:italy,italia|PT:portugal|AT:austria,österreich,osterreich|CH:switzerland,schweiz,suisse,svizzera|SE:sweden,sverige|DK:denmark,danmark|NO:norway,norge|FI:finland,suomi|PL:poland,polska|CZ:czech republic,czechia,česko,česká republika|IN:india|SG:singapore|ZA:south africa|MX:mexico,méxico|BR:brazil,brasil|JP:japan"
        for entry in list.split(separator: "|") {
            let halves = entry.split(separator: ":")
            for name in halves[1].split(separator: ",") { table[String(name)] = String(halves[0]) }
        }
        return table
    }()

    static func countryName(_ piece: String) -> String? {
        countries[piece.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()]
    }

    /// The country a city is in, among the places Scrub knows, when only one has it.
    static func knownCountry(city: String) -> String? {
        // "Praha 2" is in Praha, "København K" is København K.
        let lower = city.lowercased()
        // A city named whole outranks one it only begins: "Porto" is Porto, not Porto Alegre.
        let exact = Set(Places.all.filter { $0.city.lowercased() == lower }.map(\.country) + Places.abroad.filter { $0.city.lowercased() == lower }.map(\.country))
        if !exact.isEmpty { return exact.count == 1 ? exact.first : nil }
        let found = Set(Places.abroad.filter { lower.hasPrefix($0.city.lowercased() + " ") || $0.city.lowercased().hasPrefix(lower + " ") }.map(\.country))
        return found.count == 1 ? found.first : nil
    }

    /// The country postcodes, a region, a known city or the street's words point to.
    static func country(localities: [Locality], streets: [String], units: [String] = []) -> String? {
        for postal in localities.compactMap(\.postal) {
            let upper = postal.uppercased()
            if let known = Places.country(postal: upper), known != "US", known != "AU" { return known }
            if upper.range(of: #"^\d{4} ?[A-Z]{2}$"#, options: .regularExpression) != nil { return "NL" }
            if upper.range(of: #"^\d{4}-\d{3}$"#, options: .regularExpression) != nil { return "PT" }
            if upper.range(of: #"^\d{5}-\d{3}$"#, options: .regularExpression) != nil { return "BR" }
            if upper.range(of: #"^\d{3}-\d{4}$"#, options: .regularExpression) != nil { return "JP" }
            if upper.range(of: #"^\d{2}-\d{3}$"#, options: .regularExpression) != nil { return "PL" }
            if upper.range(of: #"^[AC-FHKNPRTV-Y]\d[\dW] ?[0-9AC-FHKNPRTV-Y]{4}$"#, options: .regularExpression) != nil { return "IE" }
        }
        let words = " " + (streets + units).joined(separator: " ").lowercased() + " "
        let hints: [(String, String)] = [("straße", "DE"), ("strasse", "CH"), ("str. ", "DE"), ("gasse", "AT"), (" rue ", "FR"), (" allée ", "FR"), (" chemin ", "FR"),
                                         (" quai ", "FR"), (" impasse ", "FR"), (" boulevard ", "FR"), (" avenue de ", "FR"), (" bis ", "FR"), (" cedex", "FR"), (" via ", "IT"), (" piazza ", "IT"), (" viale ", "IT"), (" corso ", "IT"), (" strada ", "IT"), (" contrada ", "IT"), (" vicolo ", "IT"), (" largo ", "IT"), (" calle ", "ES"), (" avda", "ES"), (" c/", "ES"), (" avenida ", "ES"),
                                         (" col. ", "MX"), (" carrera ", "ES"), (" plaza ", "ES"), (" paseo ", "ES"), (" camino ", "ES"), (" ronda ", "ES"),
                                         (" rua ", "PT"), (" travessa ", "PT"), (" alameda ", "PT"), (" estrada ", "PT"), (" praça ", "PT"), (" piazzale ", "IT"),
                                         (" ul. ", "PL"), (" al. ", "PL"), (" aleja ", "PL"), (" os. ", "PL"), ("gatan ", "SE"), ("vägen ", "SE"), (" gade ", "DK"), ("gade ", "DK"),
                                         ("vej ", "DK"), ("veien ", "NO"), (" gate ", "NO"), ("katu ", "FI"), ("straat ", "NL"), ("gracht ", "NL"), ("laan ", "NL"), ("weg ", "DE"),
                                         (" postfach ", "DE"), (" postbus ", "NL"), (" postboks ", "NO"), (" apartado ", "ES"), (" casella postale ", "IT"),
                                         (" caixa postal ", "BR"), (" bp ", "FR"), (" b.p. ", "FR")]
        let streetCountry = hints.first { words.contains($0.0) }?.1
        for locality in localities {
            // "VIC 3065", "WA 6050" (Western Australia, by its postcode), "TX 78701".
            if let region = locality.region, let postal = locality.postal, let country = Places.country(postal: postal), Places.region(region, in: country)?.country == country { return country }
            // A province's two letters on a "Viale" are Italian ("41500 Padova (BA)"), not a Brazilian state's.
            if let region = locality.region.flatMap(Places.regionAbroad), streetCountry == nil || streetCountry == region { return region }
            if let city = locality.city, let country = knownCountry(city: city) { return country }
        }
        return streetCountry
    }
}
