import Foundation

/// A name written family name first, as Chinese, Japanese, Korean, Vietnamese and Hungarian
/// names are ("Park Ji-woo", "Nagy Eszter", "Nguyễn Văn An"), or as a family name in capitals
/// before the given name says ("MORITA Kenji").
enum FamilyFirstNames {
    struct Order {
        let family: String
        let given: String
        /// A Vietnamese middle name between them ("Văn", "Thị", "Minh"), as written.
        let middle: String?
        /// The sex a Vietnamese middle name says ("Văn" a man's, "Thị" a woman's).
        var gender: String? {
            switch middle.map(FamilyFirstNames.fold) {
            case "van": "male"
            case "thi": "female"
            default: nil
            }
        }
    }
    /// The parts of `words`, a name with no title, when it is written family name first; else nil.
    static func order(_ words: [String]) -> Order? {
        guard (2...4).contains(words.count), words.allSatisfy({ $0.allSatisfy { $0.isLetter || "-'’".contains($0) } && $0.first?.isLetter == true && !People.isTitle($0) && !People.isSuffix($0) }) else { return nil }
        // "森田 彩花", "モリタ アヤカ", "김 지우": Chinese, Japanese and Korean script put the family name first.
        if words.count == 2, words.allSatisfy({ $0.unicodeScalars.allSatisfy(isEastAsian) }) { return parts(words[0], [words[1]]) }
        // "MORITA Kenji", "GARCÍA LÓPEZ María": a family name in capitals, then a given name that isn't.
        let capitals = words.prefix { $0.filter(\.isLetter).count >= 2 && $0 == $0.uppercased() && $0 != $0.lowercased() }
        let rest = Array(words.dropFirst(capitals.count))
        if (1...2).contains(capitals.count), (1...2).contains(rest.count),
           rest.allSatisfy({ $0.first?.isUppercase == true && $0.dropFirst().contains(where: \.isLowercase) }) {
            return parts(capitals.joined(separator: " "), rest)
        }
        guard let lead = rank[fold(words[0])] else { return nil }
        let last = words[words.count - 1]
        // "Wei Zhang" is Wei of the Zhang family: the commoner family name of the two is the family's.
        if let other = rank[fold(last)], other <= lead { return nil }
        switch words.count {
        case 2:
            // "Kim" and "Lee" are given names too, so "Kim Novak" is no Kim family's: unless what follows
            // reads as a given name of their own ("Kim Ji-woo"), the name is in the usual order.
            if NameLists.isFirst(words[0]), !last.contains("-"), NameLists.isSurname(last) { return nil }
            return parts(words[0], [last])
        case 3 where vietnamese.contains(fold(words[0])):
            return parts(words[0], Array(words.dropFirst()))
        default: return nil
        }
    }
    private static func isEastAsian(_ scalar: Unicode.Scalar) -> Bool {
        [0x3040...0x30FF, 0x31F0...0x31FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xAC00...0xD7A3].contains { $0.contains(scalar.value) } || scalar == "々"
    }
    private static func parts(_ family: String, _ rest: [String]) -> Order {
        rest.count == 2 ? Order(family: family, given: rest[1], middle: rest[0]) : Order(family: family, given: rest[0], middle: nil)
    }
    /// The name as the stand-in writes it in the same order: the stand-in family name first, then the given
    /// name, with capitals where the original has them. A middle name is left out, as a full name's is.
    static func written(_ order: Order, first: String, last: String) -> String {
        let shouted = { (part: String) in part.filter(\.isLetter).count >= 2 && part == part.uppercased() && part != part.lowercased() }
        let family = shouted(order.family) ? last.uppercased() : last
        let given = shouted(order.given) ? first.uppercased() : first
        return family + " " + given
    }
    private static func fold(_ word: String) -> String {
        word.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX")).replacingOccurrences(of: "đ", with: "d")
    }
    /// The commonest family names of each, commonest first, so a name of two family names reads with the commoner as the family's.
    private static let korean = ["kim", "lee", "park", "choi", "jung", "jeong", "kang", "cho", "jo", "yoon", "yun", "jang", "lim", "han", "oh", "seo", "shin", "kwon",
                                 "hwang", "ahn", "song", "yoo", "jeon", "hong", "ko", "moon", "yang", "son", "bae", "baek", "heo", "nam", "noh", "kwak", "sung", "cha", "joo", "ryu", "woo", "min"]
    private static let chinese = ["wang", "li", "zhang", "liu", "chen", "yang", "huang", "zhao", "wu", "zhou", "xu", "sun", "ma", "zhu", "hu", "guo", "he", "lin", "luo", "gao",
                                  "zheng", "liang", "xie", "song", "tang", "han", "feng", "deng", "cao", "peng", "zeng", "xiao", "tian", "dong", "pan", "yuan", "cai", "jiang", "du",
                                  "ye", "cheng", "wei", "su", "lu", "ding", "ren", "shen", "yao", "zhong", "cui", "tan", "fan", "liao", "jia", "xia", "zou", "xiong", "meng", "qin",
                                  "qiu", "hou", "yin", "xue", "duan", "lei", "long", "shi", "tao", "mao", "hao", "gu", "gong", "shao", "qian", "dai", "kong", "ouyang", "situ", "zhuge"]
    private static let japanese = ["sato", "suzuki", "takahashi", "tanaka", "watanabe", "ito", "yamamoto", "nakamura", "kobayashi", "kato", "yoshida", "yamada", "sasaki",
                                   "yamaguchi", "matsumoto", "inoue", "kimura", "hayashi", "shimizu", "yamazaki", "mori", "abe", "ikeda", "hashimoto", "yamashita", "ishikawa",
                                   "nakajima", "maeda", "fujita", "ogawa", "goto", "okada", "hasegawa", "murakami", "kondo", "ishii", "saito", "sakamoto", "endo", "aoki", "fujii",
                                   "nishimura", "fukuda", "ota", "miura", "fujiwara", "okamoto", "matsuda", "nakagawa", "nakano", "harada", "ono", "tamura", "takeuchi", "kaneko",
                                   "wada", "nakayama", "ishida", "ueda", "morita", "hara", "shibata", "sakai", "kudo", "yokoyama", "miyazaki", "miyamoto", "uchida", "takagi",
                                   "ando", "taniguchi", "ohno", "maruyama", "imai", "takada", "fujimoto", "takeda", "murata", "ueno", "sugiyama", "masuda", "sugawara", "hirano",
                                   "otsuka", "kojima", "chiba", "kubo", "matsui", "iwasaki", "sakurai", "kinoshita", "noguchi", "matsuo", "nomura", "kikuchi", "sano", "onishi", "arai"]
    private static let vietnameseOrdered = ["nguyen", "tran", "le", "pham", "hoang", "huynh", "phan", "vu", "vo", "dang", "bui", "do", "ho", "ngo", "duong", "ly", "truong", "dinh", "trinh", "luong", "lam", "mai", "cao", "ta", "quach", "thai", "doan", "vuong"]
    private static let vietnamese = Set(vietnameseOrdered)
    /// Hungarian's, less those that are given names as often ("Simon", "László", "Antal").
    private static let hungarian = ["nagy", "kovacs", "toth", "szabo", "horvath", "varga", "kiss", "molnar", "nemeth", "farkas", "balogh", "papp", "takacs", "juhasz",
                                    "lakatos", "meszaros", "olah", "racz", "fekete", "szilagyi", "torok", "feher", "gal", "szucs", "kocsis", "pinter", "fodor", "szalai", "sipos",
                                    "magyar", "gulyas", "biro", "kiraly", "katona", "fazekas", "varadi", "orosz", "somogyi", "hegedus", "deak", "vass", "szoke", "voros", "lengyel",
                                    "bognar", "hajdu", "halasz", "szekely", "kozma", "pasztor", "bakos", "dudas", "virag", "soos", "nemes", "pataki", "kertesz"]
    private static let rank: [String: Int] = {
        var rank: [String: Int] = [:]
        let ordered: [[String]] = [korean, chinese, japanese, vietnameseOrdered, hungarian]
        for list in ordered { for (index, name) in list.enumerated() { rank[name] = min(rank[name] ?? .max, index) } }
        return rank
    }()
}
