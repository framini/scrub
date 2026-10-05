import Foundation

/// A real city with its region and postal codes, so a stand-in address reads
/// as a place that exists: "Denver, CO 80205", never "Denver, TX 98402".
struct Place: Sendable, Equatable {
    let city: String
    let region: String
    let country: String
    /// US ZIP codes, or for Canada and the UK the first half of the postcode.
    let postal: [String]
    /// The local dialling code: "303", or "20" for London.
    let areaCode: String
    let latitude: Double
    let longitude: Double
    let timeZone: String
}

enum Places {
    private static let us = """
    Austin|TX|78701 78702 78703 78704 78745|512|30.2672,-97.7431|America/Chicago
    Denver|CO|80202 80203 80205 80206 80210|303|39.7392,-104.9903|America/Denver
    Seattle|WA|98101 98103 98105 98109 98115|206|47.6062,-122.3321|America/Los_Angeles
    Portland|OR|97201 97205 97209 97214 97232|503|45.5152,-122.6784|America/Los_Angeles
    Phoenix|AZ|85003 85004 85006 85016 85018|602|33.4484,-112.0740|America/Phoenix
    Chicago|IL|60601 60605 60607 60614 60657|312|41.8781,-87.6298|America/Chicago
    Boston|MA|02108 02109 02115 02116 02118|617|42.3601,-71.0589|America/New_York
    Atlanta|GA|30303 30305 30308 30309 30312|404|33.7490,-84.3880|America/New_York
    Nashville|TN|37203 37204 37206 37208 37212|615|36.1627,-86.7816|America/Chicago
    Minneapolis|MN|55401 55403 55404 55405 55408|612|44.9778,-93.2650|America/Chicago
    Columbus|OH|43201 43205 43206 43210 43215|614|39.9612,-82.9988|America/New_York
    Raleigh|NC|27601 27603 27604 27605 27608|919|35.7796,-78.6382|America/New_York
    Sacramento|CA|95811 95814 95816 95818 95819|916|38.5816,-121.4944|America/Los_Angeles
    San Diego|CA|92101 92103 92104 92109 92116|619|32.7157,-117.1611|America/Los_Angeles
    Kansas City|MO|64105 64106 64108 64111 64112|816|39.0997,-94.5786|America/Chicago
    Milwaukee|WI|53202 53203 53204 53207 53212|414|43.0389,-87.9065|America/Chicago
    Salt Lake City|UT|84101 84102 84103 84105 84111|801|40.7608,-111.8910|America/Denver
    Pittsburgh|PA|15206 15212 15213 15217 15222|412|40.4406,-79.9959|America/New_York
    Richmond|VA|23219 23220 23221 23223 23225|804|37.5407,-77.4360|America/New_York
    Omaha|NE|68102 68104 68105 68106 68131|402|41.2565,-95.9345|America/Chicago
    Louisville|KY|40202 40203 40204 40205 40206|502|38.2527,-85.7585|America/Kentucky/Louisville
    Baltimore|MD|21201 21202 21218 21224 21230|410|39.2904,-76.6122|America/New_York
    Indianapolis|IN|46202 46203 46204 46205 46220|317|39.7684,-86.1581|America/Indiana/Indianapolis
    Charlotte|NC|28202 28203 28204 28205 28209|704|35.2271,-80.8431|America/New_York
    Tampa|FL|33602 33606 33609 33611 33629|813|27.9506,-82.4572|America/New_York
    Miami|FL|33125 33130 33131 33133 33137|305|25.7617,-80.1918|America/New_York
    Las Vegas|NV|89101 89102 89104 89117 89123|702|36.1699,-115.1398|America/Los_Angeles
    Detroit|MI|48201 48202 48207 48214 48226|313|42.3314,-83.0458|America/Detroit
    New Orleans|LA|70112 70113 70115 70116 70130|504|29.9511,-90.0715|America/Chicago
    Oklahoma City|OK|73102 73103 73104 73106 73118|405|35.4676,-97.5164|America/Chicago
    Providence|RI|02903 02904 02906 02908 02909|401|41.8240,-71.4128|America/New_York
    Hartford|CT|06103 06105 06106 06112 06114|860|41.7658,-72.6734|America/New_York
    Burlington|VT|05401 05408|802|44.4759,-73.2121|America/New_York
    Des Moines|IA|50309 50310 50311 50312 50315|515|41.5868,-93.6250|America/Chicago
    Little Rock|AR|72201 72202 72204 72205 72207|501|34.7465,-92.2896|America/Chicago
    Birmingham|AL|35203 35205 35209 35222 35233|205|33.5186,-86.8104|America/Chicago
    Jackson|MS|39201 39202 39206 39211 39216|601|32.2988,-90.1848|America/Chicago
    Charleston|SC|29401 29403 29407 29412|843|32.7765,-79.9311|America/New_York
    Honolulu|HI|96813 96814 96815 96816 96822|808|21.3069,-157.8583|Pacific/Honolulu
    Anchorage|AK|99501 99503 99504 99507 99508|907|61.2181,-149.9003|America/Anchorage
    Wichita|KS|67202 67203 67208 67211 67214|316|37.6872,-97.3301|America/Chicago
    Fargo|ND|58102 58103 58104|701|46.8772,-96.7898|America/Chicago
    Sioux Falls|SD|57103 57104 57105 57106|605|43.5446,-96.7311|America/Chicago
    Billings|MT|59101 59102 59105 59106|406|45.7833,-108.5007|America/Denver
    Cheyenne|WY|82001 82007 82009|307|41.1400,-104.8202|America/Denver
    Newark|NJ|07102 07103 07104 07105 07107|973|40.7357,-74.1724|America/New_York
    Wilmington|DE|19801 19802 19805 19806|302|39.7391,-75.5398|America/New_York
    Washington|DC|20001 20002 20003 20009 20010|202|38.9072,-77.0369|America/New_York
    Manchester|NH|03101 03102 03103 03104|603|42.9956,-71.4548|America/New_York
    New York|NY|10001 10003 10011 10025 10128|212|40.7128,-74.0060|America/New_York
    Albuquerque|NM|87102 87104 87106 87108 87110|505|35.0844,-106.6504|America/Denver
    Boise|ID|83702 83704 83705 83706 83709|208|43.6150,-116.2023|America/Boise
    Portland|ME|04101 04102 04103|207|43.6591,-70.2568|America/New_York
    Charleston|WV|25301 25302 25304|304|38.3498,-81.6326|America/New_York
    """
    private static let ca = """
    Toronto|ON|M5V M4W M6G M5A M4Y|416|43.6532,-79.3832|America/Toronto
    Ottawa|ON|K1P K2P K1N K1S|613|45.4215,-75.6972|America/Toronto
    Vancouver|BC|V6B V5K V6K V5T|604|49.2827,-123.1207|America/Vancouver
    Montreal|QC|H2X H3B H2T H2J|514|45.5019,-73.5674|America/Toronto
    Calgary|AB|T2P T2R T3A T2S|403|51.0447,-114.0719|America/Edmonton
    Edmonton|AB|T5J T5K T6E|780|53.5461,-113.4938|America/Edmonton
    Winnipeg|MB|R3C R3M R2W|204|49.8951,-97.1384|America/Winnipeg
    Halifax|NS|B3H B3J B3K|902|44.6488,-63.5752|America/Halifax
    Regina|SK|S4P S4S S4T|306|50.4452,-104.6189|America/Regina
    """
    private static let gb = """
    London|England|SE1 N1 E2 NW3 W2 SW4|20|51.5072,-0.1276|Europe/London
    Manchester|England|M1 M4 M14 M20|161|53.4808,-2.2426|Europe/London
    Birmingham|England|B1 B5 B15|121|52.4862,-1.8904|Europe/London
    Leeds|England|LS1 LS6 LS7|113|53.8008,-1.5491|Europe/London
    Bristol|England|BS1 BS6 BS8|117|51.4545,-2.5879|Europe/London
    Glasgow|Scotland|G1 G3 G12|141|55.8642,-4.2518|Europe/London
    Edinburgh|Scotland|EH1 EH3 EH6|131|55.9533,-3.1883|Europe/London
    Cardiff|Wales|CF10 CF11 CF24|29|51.4816,-3.1791|Europe/London
    Belfast|Northern Ireland|BT1 BT7 BT9|28|54.5973,-5.9301|Europe/London
    """
    private static let au = """
    Sydney|NSW|2000 2010 2026 2037|2|-33.8688,151.2093|Australia/Sydney
    Melbourne|VIC|3000 3065 3141 3182|3|-37.8136,144.9631|Australia/Melbourne
    Brisbane|QLD|4000 4101 4006|7|-27.4698,153.0251|Australia/Brisbane
    Perth|WA|6000 6050 6008|8|-31.9505,115.8605|Australia/Perth
    Adelaide|SA|5000 5067 5006|8|-34.9285,138.6007|Australia/Adelaide
    Hobart|TAS|7000 7004|3|-42.8821,147.3272|Australia/Hobart
    Canberra|ACT|2600 2612|2|-35.2809,149.1300|Australia/Sydney
    Darwin|NT|0800 0810|8|-12.4634,130.8456|Australia/Darwin
    """
    static let all: [Place] = [("US", us), ("CA", ca), ("GB", gb), ("AU", au)].flatMap { country, table in
        table.split(separator: "\n").map { line in
            let fields = line.split(separator: "|").map(String.init)
            let point = fields[4].split(separator: ",").compactMap { Double($0) }
            return Place(city: fields[0], region: fields[1], country: country, postal: fields[2].split(separator: " ").map(String.init),
                         areaCode: fields[3], latitude: point[0], longitude: point[1], timeZone: fields[5])
        }
    }

    /// A city outside the four countries Scrub places addresses in, with one
    /// of its postcodes, so an address there keeps a city of its own country:
    /// "70178 Stuttgart" → "80331 München", never a US city.
    struct Abroad: Sendable {
        let country: String
        let city: String
        let postal: String
        let region: String?

        /// The city's postcode in the original's layout ("1012" → "1012 KX"
        /// beside "1016 GC"), its last digits drawn fresh; where the shapes
        /// differ, in its own layout, with what follows its area drawn fresh ("V94 T9PX" → "V94 K2RD").
        func postal(like original: String, digit: () -> String, letter: () -> Character) -> String {
            let digits = original.filter(\.isNumber), mine = postal.filter(\.isNumber)
            guard digits.count == mine.count, original.filter(\.isLetter).count <= 2 else {
                let area = postal.firstIndex { $0 == " " || $0 == "-" } ?? postal.index(postal.startIndex, offsetBy: min(3, postal.count))
                return String(postal[..<area]) + String(postal[area...].map { $0.isNumber ? Character(digit()) : $0.isLetter ? letter() : $0 })
            }
            var source = Array(mine)
            for index in source.indices.suffix(min(2, max(0, source.count - 3))) { source[index] = Character(digit()) }
            var iterator = source.makeIterator()
            return String(original.map { $0.isNumber ? iterator.next() ?? $0 : $0.isLetter ? letter() : $0 })
        }
    }
    private static let abroadTable = """
    DE|Berlin|10115|;DE|München|80331|;DE|Hamburg|20095|;DE|Köln|50667|;DE|Frankfurt am Main|60311|;DE|Leipzig|04109|;DE|Düsseldorf|40213|;DE|Stuttgart|70173|
    FR|Paris|75002|;FR|Lyon|69002|;FR|Marseille|13001|;FR|Toulouse|31000|;FR|Nantes|44000|;FR|Bordeaux|33000|;FR|Lille|59000|;FR|Strasbourg|67000|
    NL|Amsterdam|1012|;NL|Rotterdam|3011|;NL|Utrecht|3511|;NL|Den Haag|2511|;NL|Eindhoven|5611|;NL|Groningen|9711|
    BE|Bruxelles|1000|;BE|Antwerpen|2000|;BE|Gent|9000|;BE|Liège|4000|;BE|Brugge|8000|
    ES|Madrid|28013|;ES|Barcelona|08002|;ES|Valencia|46002|;ES|Sevilla|41001|;ES|Bilbao|48001|;ES|Zaragoza|50001|
    IT|Roma|00184|RM;IT|Milano|20121|MI;IT|Torino|10121|TO;IT|Napoli|80133|NA;IT|Bologna|40121|BO;IT|Firenze|50123|FI
    PT|Lisboa|1100-148|;PT|Porto|4000-322|;PT|Braga|4700-435|;PT|Coimbra|3000-140|;PT|Faro|8000-138|
    AT|Wien|1010|;AT|Graz|8010|;AT|Linz|4020|;AT|Salzburg|5020|;AT|Innsbruck|6020|
    CH|Zürich|8001|;CH|Genève|1201|;CH|Basel|4051|;CH|Bern|3011|;CH|Lausanne|1003|
    SE|Stockholm|111 51|;SE|Göteborg|411 05|;SE|Malmö|211 22|;SE|Uppsala|753 20|;SE|Västerås|722 15|
    DK|København K|1050|;DK|Aarhus C|8000|;DK|Odense C|5000|;DK|Aalborg|9000|
    NO|Oslo|0150|;NO|Bergen|5003|;NO|Trondheim|7011|;NO|Stavanger|4006|
    FI|Helsinki|00100|;FI|Espoo|02100|;FI|Tampere|33100|;FI|Turku|20100|;FI|Oulu|90100|
    PL|Warszawa|00-001|;PL|Kraków|31-001|;PL|Wrocław|50-001|;PL|Gdańsk|80-001|;PL|Poznań|61-001|
    CZ|Praha|110 00|;CZ|Brno|602 00|;CZ|Ostrava|702 00|;CZ|Plzeň|301 00|
    IE|Dublin|D02 X285|;IE|Cork|T12 K8AF|;IE|Galway|H91 E2K3|;IE|Limerick|V94 T9PX|
    NZ|Auckland|1010|;NZ|Wellington|6011|;NZ|Christchurch|8011|;NZ|Hamilton|3204|;NZ|Dunedin|9016|
    ZA|Cape Town|8001|;ZA|Johannesburg|2001|;ZA|Durban|4001|;ZA|Pretoria|0002|
    IN|Mumbai|400001|Maharashtra;IN|Bengaluru|560001|Karnataka;IN|Chennai|600001|Tamil Nadu;IN|Hyderabad|500001|Telangana;IN|Pune|411001|Maharashtra;IN|Kolkata|700001|West Bengal
    SG|Singapore|018956|
    MX|Ciudad de México|06000|CDMX;MX|Guadalajara|44100|Jalisco;MX|Monterrey|64000|Nuevo León;MX|Puebla|72000|Puebla
    BR|São Paulo|01310-100|SP;BR|Rio de Janeiro|20040-020|RJ;BR|Belo Horizonte|30130-010|MG;BR|Curitiba|80010-000|PR;BR|Porto Alegre|90010-000|RS
    JP|Tokyo|100-0001|;JP|Osaka|530-0001|;JP|Kyoto|600-8216|;JP|Nagoya|450-0002|;JP|Sapporo|060-0001|;JP|Fukuoka|810-0001|
    """
    static let abroad: [Abroad] = abroadTable.split(whereSeparator: { $0 == ";" || $0 == "\n" }).compactMap { entry in
        let fields = entry.trimmingCharacters(in: .whitespaces).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 4 else { return nil }
        return Abroad(country: fields[0], city: fields[1], postal: fields[2], region: fields[3].isEmpty ? nil : fields[3])
    }

    /// Ordinary words streets and districts are named with, by country, for
    /// a stand-in that reads like the original's ("Ahornstraße", "rue des Lilas").
    static let streetWords: [String: [String]] = {
        let table = """
        DE:Linden,Ahorn,Birken,Eichen,Buchen,Rosen,Mühlen,Wiesen,Garten,Berg,Wald,Sonnen,Kirch,Schul,Bahnhof,Markt,Brunnen,Hafen,Tannen,Erlen
        AT:Linden,Ahorn,Birken,Eichen,Rosen,Mühl,Wiesen,Garten,Berg,Wald,Sonnen,Kirchen,Schul,Bahnhof,Markt,Brunnen,Kastanien,Erlen
        CH:Linden,Ahorn,Birken,Eichen,Rosen,Mühle,Wiesen,Garten,Berg,Wald,Sonnen,Kirch,Schul,Bahnhof,Markt,Brunnen,Seefeld,Rebberg
        FR:Lilas,Tilleuls,Peupliers,Acacias,Prés,Vignes,Pins,Roses,Chênes,Platanes,Jardins,Écoles,Saules,Ormes,Glycines,Marronniers
        BE:Lilas,Tilleuls,Acacias,Peupliers,Roses,Linden,Eiken,Beuken,Rozen,Molen,Kerk,School,Dorps,Haven,Wilgen
        NL:Linden,Eiken,Beuken,Berken,Wilgen,Rozen,Tulpen,Molen,Kerk,School,Dorps,Haven,Duin,Beek,Esdoorn,Kastanje,Lijsterbes
        ES:Rosales,Olivos,Pinos,Jazmines,Almendros,Naranjos,Acacias,Robles,Encinas,Lirios,Cipreses,Magnolias,Geranios,Tilos
        MX:Rosales,Olivos,Pinos,Jazmines,Fresnos,Naranjos,Robles,Encinos,Cedros,Laureles,Magnolias,Sauces
        IT:Rose,Pini,Tigli,Ulivi,Giardini,Querce,Glicini,Castagni,Gelsi,Platani,Cipressi,Oleandri,Mandorli,Ciliegi
        PT:Flores,Rosas,Oliveiras,Pinheiros,Palmeiras,Laranjeiras,Acácias,Amoreiras,Castanheiros,Camélias,Violetas,Magnólias
        BR:Flores,Rosas,Oliveiras,Pinheiros,Palmeiras,Laranjeiras,Acácias,Ipês,Jacarandás,Mangueiras,Hortênsias,Orquídeas
        SE:Björk,Ek,Lind,Gran,Tall,Rosen,Sjö,Berg,Dal,Sol,Kvarn,Strand,Hamn,Skog,Äng,Lärk
        DK:Bøge,Elme,Linde,Rose,Skov,Strand,Mølle,Kirke,Skole,Enge,Hasle,Birke,Ege,Kastanie
        NO:Bjørk,Furu,Lind,Skog,Sjø,Berg,Dal,Strand,Kirke,Skole,Eike,Rogn,Hassel,Lønne
        FI:Koivu,Kuusi,Mänty,Pihlaja,Tammi,Vaahtera,Kivi,Ranta,Järvi,Mäki,Puisto,Lehmus,Haapa,Kallio
        PL:Kwiatowa,Lipowa,Brzozowa,Słoneczna,Polna,Leśna,Ogrodowa,Spacerowa,Zielona,Szkolna,Klonowa,Jesionowa,Różana,Wierzbowa
        CZ:Lipová,Zahradní,Polní,Lesní,Krátká,Dlouhá,Školní,Nová,Luční,Sadová,Javorová,Březová,Jasmínová,Růžová
        JP:Higashi,Nishi,Minami,Kita,Naka,Sakura,Matsu,Kawa,Hon,Shin,Midori,Aoba
        """
        var result: [String: [String]] = [:]
        for line in table.split(separator: "\n") {
            let halves = line.trimmingCharacters(in: .whitespaces).split(separator: ":")
            result[String(halves[0])] = halves[1].split(separator: ",").map(String.init)
        }
        return result
    }()

    /// The country a region of a country Scrub has no places in names: an
    /// Indian or Mexican state, a Brazilian one's code.
    static func regionAbroad(_ value: String) -> String? {
        abroadRegionCountry[value.trimmingCharacters(in: .whitespaces).lowercased()]
    }
    private static let abroadRegionCountry: [String: String] = {
        var result: [String: String] = [:]
        for name in "Andhra Pradesh,Assam,Bihar,Delhi,Goa,Gujarat,Haryana,Karnataka,Kerala,Madhya Pradesh,Maharashtra,Odisha,Punjab,Rajasthan,Tamil Nadu,Telangana,Uttar Pradesh,West Bengal".split(separator: ",") { result[name.lowercased()] = "IN" }
        for name in "CDMX,Jalisco,Nuevo León,Puebla,Yucatán,Oaxaca,Chiapas,Veracruz,Guanajuato,Querétaro,Sonora,Chihuahua,Sinaloa,Coahuila".split(separator: ",") { result[name.lowercased()] = "MX" }
        for code in "SP,RJ,MG,RS,BA,PE,CE,DF,GO,AM".split(separator: ",") { result[code.lowercased()] = "BR" }
        return result
    }()

    /// Every region Scrub can write: its code, name and country.
    struct Region: Sendable { let code: String; let name: String; let country: String }
    private static let regionTable: [(String, String)] = [
        ("US", "AL Alabama|AK Alaska|AZ Arizona|AR Arkansas|CA California|CO Colorado|CT Connecticut|DE Delaware|DC District of Columbia|FL Florida|GA Georgia|HI Hawaii|ID Idaho|IL Illinois|IN Indiana|IA Iowa|KS Kansas|KY Kentucky|LA Louisiana|ME Maine|MD Maryland|MA Massachusetts|MI Michigan|MN Minnesota|MS Mississippi|MO Missouri|MT Montana|NE Nebraska|NV Nevada|NH New Hampshire|NJ New Jersey|NM New Mexico|NY New York|NC North Carolina|ND North Dakota|OH Ohio|OK Oklahoma|OR Oregon|PA Pennsylvania|RI Rhode Island|SC South Carolina|SD South Dakota|TN Tennessee|TX Texas|UT Utah|VT Vermont|VA Virginia|WA Washington|WV West Virginia|WI Wisconsin|WY Wyoming|PR Puerto Rico"),
        ("CA", "AB Alberta|BC British Columbia|MB Manitoba|NB New Brunswick|NL Newfoundland and Labrador|NS Nova Scotia|NT Northwest Territories|NU Nunavut|ON Ontario|PE Prince Edward Island|QC Quebec|SK Saskatchewan|YT Yukon"),
        ("AU", "NSW New South Wales|VIC Victoria|QLD Queensland|WA Western Australia|SA South Australia|TAS Tasmania|ACT Australian Capital Territory|NT Northern Territory"),
        ("GB", "ENG England|SCT Scotland|WLS Wales|NIR Northern Ireland"),
    ]
    static let regions: [Region] = regionTable.flatMap { country, list in
        list.split(separator: "|").map { entry in
            let code = String(entry.prefix { $0 != " " })
            return Region(code: code, name: String(entry.dropFirst(code.count + 1)), country: country)
        }
    }
    private static let byName = Dictionary(regions.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
    private static let byCode = Dictionary(regions.filter { $0.country != "GB" }.map { ($0.code, $0) }, uniquingKeysWith: { first, _ in first })

    /// The region a value names: a full name in any case ("Washington",
    /// "NEW YORK"), or a code in capitals ("WA"), since "or", "in" and "me"
    /// are words first. US codes win where Australia shares one ("WA").
    static func region(_ value: String, in country: String? = nil) -> Region? {
        let trimmed = value.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if let country, let local = regions.first(where: { $0.country == country && ($0.name.caseInsensitiveCompare(trimmed) == .orderedSame || $0.code == trimmed) }) { return local }
        if let named = byName[trimmed.lowercased()] { return named }
        return trimmed == trimmed.uppercased() ? byCode[trimmed] : nil
    }

    static func country(_ value: String) -> String? {
        guard !value.contains(where: \.isNumber) else { return nil }
        return switch value.trimmingCharacters(in: .whitespaces).lowercased().filter({ $0.isLetter }) {
        case "us", "usa", "unitedstates", "unitedstatesofamerica", "america": "US"
        case "ca", "can", "canada": "CA"
        case "gb", "gbr", "uk", "unitedkingdom", "greatbritain", "england", "scotland", "wales", "northernireland": "GB"
        case "au", "aus", "australia": "AU"
        case "": nil
        default: "other"
        }
    }

    /// A country written as a code ("IT", "ITA", "UK") or a name ("Italy"), as its two-letter code.
    static func code(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces).uppercased()
        if trimmed == "UK" { return "GB" }
        if trimmed.count == 2, trimmed.allSatisfy({ $0.isASCII && $0.isLetter }), ["US", "CA", "GB", "AU"].contains(trimmed) || abroad.contains(where: { $0.country == trimmed }) { return trimmed }
        if trimmed.count == 3, let code = alpha3[trimmed] { return code }
        return AddressBlock.countryName(value)
    }
    private static let alpha3 = ["USA": "US", "CAN": "CA", "GBR": "GB", "AUS": "AU", "DEU": "DE", "FRA": "FR", "NLD": "NL", "BEL": "BE", "ESP": "ES", "ITA": "IT", "PRT": "PT", "AUT": "AT",
                                 "CHE": "CH", "SWE": "SE", "DNK": "DK", "NOR": "NO", "FIN": "FI", "POL": "PL", "CZE": "CZ", "IRL": "IE", "NZL": "NZ", "ZAF": "ZA", "IND": "IN", "SGP": "SG",
                                 "MEX": "MX", "BRA": "BR", "JPN": "JP"]

    private static let canadian = TextPattern(#"^[A-Za-z]\d[A-Za-z] ?\d[A-Za-z]\d$"#)
    private static let british = TextPattern(#"^[A-Za-z]{1,2}\d[A-Za-z\d]? ?\d[A-Za-z]{2}$"#)
    /// The country a postcode is written for, from its shape alone.
    static func country(postal: String) -> String? {
        let trimmed = postal.trimmingCharacters(in: .whitespaces)
        if !TextRanges.matches(canadian, in: trimmed).isEmpty { return "CA" }
        if !TextRanges.matches(british, in: trimmed).isEmpty { return "GB" }
        let digits = trimmed.filter(\.isNumber)
        if trimmed.allSatisfy({ $0.isNumber || $0 == "-" || $0 == " " }) {
            if digits.count == 5 || digits.count == 9 { return "US" }
            if digits.count == 4 && digits == trimmed { return "AU" }
        }
        return nil
    }

    /// The country an address is in, from whatever parts of it are known.
    /// Nil for a country Scrub has no places in: its parts are replaced one by one.
    static func country(city: String?, region: String?, postal: String?, country: String?, coordinates: String? = nil) -> String? {
        if let country, let known = Self.country(country) { return known == "other" ? nil : known }
        // South of the equator, the nearest places Scrub knows are Australian.
        if city == nil, region == nil, postal == nil, let coordinates, coordinates.trimmingCharacters(in: .whitespaces).hasPrefix("-"), Double(coordinates.split(separator: ",").first ?? "").map({ abs($0) <= 90 }) == true { return "AU" }
        if let postal, let known = Self.country(postal: postal) { return known }
        if let region, let known = Self.region(region) { return known.country }
        if let city, let known = all.first(where: { $0.city.caseInsensitiveCompare(city.trimmingCharacters(in: .whitespaces)) == .orderedSame }) { return known.country }
        return "US"
    }

    /// A region written as the original is: a code or a name, in its case.
    static func write(_ place: Place, like original: String) -> String {
        let trimmed = original.trimmingCharacters(in: .whitespaces)
        let region = regions.first { $0.country == place.country && ($0.code == place.region || $0.name == place.region) }
        let asName = region.map { trimmed.count > 3 || byName[trimmed.lowercased()] != nil ? $0.name : $0.country == "GB" ? $0.name : $0.code } ?? place.region
        if trimmed.count > 1, trimmed == trimmed.uppercased() { return asName.uppercased() }
        if trimmed.count > 1, trimmed == trimmed.lowercased() { return asName.lowercased() }
        return asName
    }
}

/// What one address holds, as written: the parts that decide its stand-in place.
struct AddressParts: Hashable, Sendable {
    var city: String?
    var region: String?
    var postal: String?
    var country: String?
    /// A latitude, longitude or pair, which places an address with no other part.
    var coordinates: String?
    var isEmpty: Bool { city == nil && region == nil && postal == nil && coordinates == nil }
    /// Parts written as one line, "4821 Juniper Hollow Rd, Tacoma, WA 98402",
    /// "Tacoma, WA", "Toronto, ON M5V 2T6, Canada", or as a signature writes
    /// them, a street over its city ("2200 Kessler Ave, Suite 410⏎Austin, TX
    /// 78701"). The separators come back as written, so a rewrite keeps the lines.
    static func line(_ text: String) -> (parts: AddressParts, pieces: [String], separators: [String])? {
        // One address, never a sentence around one: every piece is rewritten.
        // "P.O. Box" and "Louisiana St. 808B" have full stops inside them, not between two sentences.
        let sentences = text.contains(". ") ? text.replacingOccurrences(of: #"(?i)\b(?:p\.\s?o|st|ave|rd|dr|blvd|ln|ct|pl|ste|apt|hwy|pkwy|mt|[nsew])\.\s"#, with: "_ ", options: .regularExpression) : text
        let lines = text.split(whereSeparator: \.isNewline)
        guard lines.count <= 3, lines.count == 1 || lines.allSatisfy({ $0.utf16.count <= 64 }), text.utf16.count <= 160, !sentences.contains(". "), !text.contains(";") else { return nil }
        let trailing = text.last == "." ? String(text.dropLast()) : text
        let ns = trailing as NSString
        var pieces: [String] = [], separators: [String] = [], start = 0
        for match in TextRanges.matches(pieceBreak, in: trailing) {
            pieces.append(ns.substring(with: NSRange(location: start, length: match.range.location - start)).trimmingCharacters(in: .whitespaces))
            // A comma reads as ", " as before; a line break stays where it was.
            let separator = ns.substring(with: match.range)
            separators.append(separator.contains(where: \.isNewline) ? separator : ", ")
            start = NSMaxRange(match.range)
        }
        pieces.append(ns.substring(from: start).trimmingCharacters(in: .whitespaces))
        guard pieces.count >= 2, pieces.count <= 6, pieces.allSatisfy({ !$0.isEmpty && $0.count <= 48 }) else { return nil }
        var parts = AddressParts()
        var rest = pieces[...]
        if let last = rest.last, let country = Places.country(last), country != "other", Places.country(postal: last) == nil, Places.region(last) == nil {
            parts.country = last
            rest = rest.dropLast()
        }
        guard let tail = rest.last else { return nil }
        // "WA 98402", "ON M5V 2T6", "WA", or the postcode alone after the region.
        let words = tail.split(separator: " ").map(String.init)
        if Places.region(tail) != nil {
            parts.region = tail
        } else if Places.country(postal: tail) != nil, rest.count >= 3, Places.region(rest[rest.index(rest.endIndex, offsetBy: -2)]) != nil {
            parts.postal = tail
            rest = rest.dropLast()
            parts.region = rest.last
        } else if Places.country(postal: tail) != nil {
            parts.postal = tail
        } else if let split = (1..<max(1, words.count)).first(where: { Places.region(words[..<$0].joined(separator: " ")) != nil && Places.country(postal: words[$0...].joined(separator: " ")) != nil }) {
            parts.region = words[..<split].joined(separator: " ")
            parts.postal = words[split...].joined(separator: " ")
        } else { return nil }
        rest = rest.dropLast()
        guard let city = rest.last, city.contains(where: \.isLetter), !city.contains(where: \.isNumber), city.split(separator: " ").count <= 4 else { return nil }
        // What comes before the city is a street and its unit, each with a number.
        guard rest.dropLast().allSatisfy({ $0.contains(where: \.isNumber) }) else { return nil }
        parts.city = city
        return (parts, pieces, separators)
    }
    private static let pieceBreak = TextPattern(#"[ \t]*,[ \t]*(?:\r?\n[ \t]*)?|[ \t]*\r?\n[ \t]*"#)
}
