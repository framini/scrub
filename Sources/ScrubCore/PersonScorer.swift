import Foundation

/// Decides whether a person only a model read is someone, and how sure Scrub
/// is of it. Two models guess people the tagger and the rules missed: the
/// name model, from the letters of a word and its neighbours, and the context
/// model, from the whole sentence. Each is wrong in its own way.
///
/// A context-model guess in Latin script counts only where something
/// independent of it agrees (`agrees`): the name model, a listed name that is
/// no ordinary word, a title, a greeting or sign-off, a cue. Neither model's
/// guess counts when it is made of ordinary words with nothing around it that
/// marks a name (`NameShape.ordinaryGuess`). Those are the hand rules.
///
/// Among the guesses they let through, `probability` weighs every signal
/// with a logistic regression that Tools/PersonScorer fits on generated text
/// and permissive training text, never on the real-text evaluation sets. It
/// drops the guesses it gives less than `keepFrom`, and its probability is
/// the confidence a kept one carries into review. It judges only where the
/// context model read the whole text, since it was fitted on such text;
/// elsewhere the hand rules decide, at each model's own score.
enum PersonScorer {
    /// What is known about one guess.
    struct Signals: Equatable {
        /// The name model's surest score for a word of it, as a logit; nil where it read no word.
        var nameModel: Float?
        /// The name model alone would have called it a name.
        var nameModelFound = false
        /// How far the context model leaned to a person over it, as log-odds; nil where it read none.
        var context: Float?
        /// A word of it is a listed first name, or surname, that is no ordinary word ("Odalys", "Okafor").
        var first = false
        var surname = false
        /// A word of it is a name that is also a word ("Will", "Rose", "June").
        var wordlike = false
        /// Every word of it is an ordinary word and none a name ("Gas Day", "Later").
        var ordinary = false
        /// A word no list or dictionary has, written with a capital ("Kestrelwood").
        var unknownCapital = false
        /// A title or rank before it ("Ms", "Sergeant").
        var title = false
        /// It greets or signs a message ("Hi Ama,", "Thanks,⏎Ama").
        var greeting = false
        /// A cue NameCues counts as strong: a title, an initial, "said", a greeting or a sign-off.
        var strong = false
        /// Written as a name: a cue, the subject of a verb, a possessive, or capitalised mid-sentence.
        var position = false
        /// A lowercase word follows it, as a verb follows its subject ("Faith confirmed", "Siri misheard"): written as a name, or as a thing's.
        var subject = false
        /// An article or determiner before it ("the Jenkins build", "a Ruby gem"): a thing's name, not a person's.
        var determiner = false
        /// A version number after it ("Darwin 25.6.0", "Python 3.12"): a product's name.
        var version = false
        /// Words before it that lead to a place: "lives in", "moved to", "flying into".
        var placeCue = false
        var capitalised = false
        var lowercase = false
        var allCaps = false
        var words = 1
        /// It opens a line or a sentence, where any word is capitalised.
        var opens = false
        /// It is part of an organisation's name ("Okafor Logistics").
        var organisation = false
        /// It is a town or a region.
        var place = false

        /// The features the regression weighs, in the order of `weights`.
        var vector: [Double] {
            func flag(_ value: Bool) -> Double { value ? 1 : 0 }
            let model = Double(min(max(nameModel ?? -6, -6), 12)) / 6
            let read = Double(min(max(context ?? -2, -2), 8)) / 4
            return [model, flag(nameModelFound), context == nil ? 0 : read, flag(context != nil),
                    flag(first), flag(surname), flag(wordlike), flag(ordinary), flag(unknownCapital),
                    flag(title), flag(greeting), flag(strong), flag(position), flag(subject),
                    flag(capitalised), flag(lowercase), flag(allCaps), flag(words == 1), flag(words >= 3), flag(opens),
                    flag(organisation), flag(place), flag(determiner), flag(version), flag(placeCue)]
        }
        static let names = ["nameModel", "nameModelFound", "context", "contextFound",
                            "first", "surname", "wordlike", "ordinary", "unknownCapital",
                            "title", "greeting", "strong", "position", "subject",
                            "capitalised", "lowercase", "allCaps", "oneWord", "threeWords", "opens",
                            "organisation", "place", "determiner", "version", "placeCue"]
    }

    /// Whether the learned scorer decides, rather than the hand rules. Read
    /// once a scrub, like `AddressModel.active`; tests turn it off to compare.
    @TaskLocal static var learned = true

    // Fitted by Tools/PersonScorer/fit.py, in the order of `Signals.names`; its README has the data and the held-out check.
    static let bias = -1.7982
    static let weights: [Double] = [1.4602, -1.5538, 4.3910, -0.2474, 0.6760, -0.0205, -0.3729, -2.3842, -1.1494, 0.7932, 1.2755, -1.2560,
                                    0.0268, 0.7804, -1.5154, 0.9416, 0.0019, 3.0955, 0.0279, 0.5291, 0.0000, 0.0000, 0.0000, 0.0000, -1.3827]
    /// The least probability a guess is kept at: on the fitting part, the
    /// threshold that keeps every person the hand rules keep with the fewest other words.
    static let keepFrom = 0.08

    /// The probability that the guess names someone.
    static func probability(_ signals: Signals) -> Double {
        let sum = zip(weights, signals.vector).reduce(bias) { $0 + $1.0 * $1.1 }
        return 1 / (1 + exp(-sum))
    }

    /// The confidence a kept guess carries: its probability, no lower than
    /// the context model's own score and no higher than the tagger's 0.85.
    static func confidence(_ probability: Double) -> Double {
        min(0.85, max(ContextStage.score, probability))
    }

    /// Whether something independent of the context model marks its guess
    /// as a name: the name model calling it one, a listed first name or
    /// surname that is no ordinary word, a title, a greeting or sign-off, or a
    /// cue (`NameCues`). Never an organisation, a town or region, a lone word
    /// in capitals, a word after an article ("the Jenkins build"), before a
    /// version number ("Darwin 25.6.0") or where a place goes ("moved to Szeged").
    static func agrees(_ signals: Signals) -> Bool {
        guard !signals.organisation, !signals.place, !(signals.allCaps && signals.words == 1), !signals.determiner, !signals.version, !signals.placeCue else { return false }
        let model = signals.nameModelFound
        let listed = (signals.first || signals.surname) && !signals.ordinary
        let marked = signals.title || signals.greeting || signals.strong
        // A word opening a sentence is the subject of the verb after it whatever
        // it names ("Siri misheard", "Corvane was founded"): there the lists and
        // the cue say nothing a person's name would not, and only the name model decides.
        if signals.opens && signals.subject && signals.words == 1 && !marked { return model }
        // A lowercase word alone is a name only where a list or the name model
        // says so, or a title or greeting stands beside it: "thanks⏎fyi he was" is chat.
        if signals.lowercase && signals.words == 1 { return model || listed || signals.title || signals.greeting }
        let cue = signals.position && !(signals.opens && signals.subject && !signals.first && !signals.surname && !signals.wordlike)
        return model || listed || marked || cue
    }

    /// "in", "near" or "outside" a word, or "to" it after a verb of going: where someone is or goes, not who.
    private static let placeBefore = TextPattern(#"(?i)(?:\b(?:in|into|near|outside|around|across|throughout)|\b(?:mov(?:e|ed|es|ing)|relocat(?:e|ed|es|ing)|fl(?:y|ying|ew|ies)|dr(?:ive|ove|iving)|travel(?:led|ed|ling|ing|s)?|trip|went|go(?:ing|es)?|back|return(?:ed|ing|s)?|emigrat(?:e|ed|ing)|commut(?:e|es|ed|ing)|transferr?(?:ed|ing)?|posted)\s+to)[ \t]+$"#)
    private static let versionAfter = TextPattern(#"^[ \t]+v?\d+(?:\.\d+)+(?!\w)"#)
    private static let determiners: Set<String> = ["the", "a", "an", "this", "that", "these", "those", "our", "their", "its", "every", "each", "any", "some", "no"]

    /// Whether `word`, the word before `index`, is separated from it by more than spaces ("the end. Jenkins").
    private static func between(_ word: String, _ index: Int, _ ns: NSString) -> Bool {
        var at = index
        while at > 0, ns.character(at: at - 1) == 32 || ns.character(at: at - 1) == 9 { at -= 1 }
        guard at >= (word as NSString).length else { return true }
        return ns.substring(with: NSRange(location: at - (word as NSString).length, length: (word as NSString).length)).lowercased() != word.lowercased()
    }

    /// What is known about the person guessed at `range`.
    static func signals(_ range: Range<Int>, in text: String, reading: NameModel.Reading?, people: [ContextStage.Person]) -> Signals {
        let ns = text as NSString
        var signals = Signals()
        let words = NameShape.words(range, in: text)
        if let score = reading?.score(in: range) {
            signals.nameModel = score
            let lower = words.allSatisfy { $0.text.first?.isLowercase == true }
            signals.nameModelFound = score >= (lower ? NameModel.lowercaseThreshold : NameModel.threshold)
        }
        if let doubt = people.filter({ $0.range.overlaps(range) }).map(\.doubt).min() {
            let clamped = min(max(Double(doubt), 1e-6), 1 - 1e-6)
            signals.context = Float(log((1 - clamped) / clamped))
        }
        let bare = words.map(\.bare)
        signals.first = bare.contains { listedFirst($0) && !NameLists.isWordlike($0) && !NameLists.isOrdinary($0) }
        signals.surname = bare.contains { NameLists.isSurname($0) && !NameLists.isWordlike($0) && !NameLists.isOrdinary($0) }
        signals.wordlike = bare.contains { NameLists.isWordlike($0) }
        signals.ordinary = !bare.isEmpty && bare.allSatisfy { NameLists.isOrdinary($0) || NameShape.joining.contains($0) } && !bare.contains { NameLists.isName($0) }
        signals.unknownCapital = words.contains { word in
            word.text.first?.isUppercase == true && word.bare.count >= 3 && !NameLists.isOrdinary(word.bare)
                && !listedFirst(word.bare) && !NameLists.isSurname(word.bare)
        }
        let before = Context.words(before: range.lowerBound, in: text, limit: 1).first ?? ""
        signals.title = People.isTitle(before) || NameShape.isRole(before)
        signals.determiner = determiners.contains(before.lowercased()) && !between(before, range.lowerBound, ns)
        signals.greeting = NameCues.greeted(range, ns) || NameCues.signs(range, ns)
        signals.strong = NameCues.strong(range, in: text)
        signals.position = NameCues.position(range, in: text)
        signals.subject = NameCues.acts(range, in: text) || range.upperBound < ns.length && ns.character(at: range.upperBound) == 32
            && Context.words(after: range.upperBound, in: text, limit: 1).first?.first?.isLowercase == true
        let letters = words.map { $0.text.filter(\.isLetter) }
        signals.capitalised = !letters.isEmpty && letters.allSatisfy { $0.first?.isUppercase == true }
        signals.lowercase = !letters.isEmpty && letters.allSatisfy { $0 == $0.lowercased() }
        signals.allCaps = letters.joined().count >= 2 && letters.allSatisfy { $0 == $0.uppercased() && $0 != $0.lowercased() }
        signals.words = max(1, words.count)
        signals.opens = opens(range.lowerBound, ns)
        let after = ns.substring(with: NSRange(location: range.upperBound, length: min(24, ns.length - range.upperBound)))
        signals.version = !TextRanges.matches(versionAfter, in: after).isEmpty
        let start = max(0, range.lowerBound - 32)
        // "in Priya's absence" is about Priya.
        signals.placeCue = !TextRanges.matches(placeBefore, in: ns.substring(with: NSRange(location: start, length: range.lowerBound - start))).isEmpty
            && !after.hasPrefix("'s") && !after.hasPrefix("’s")
        signals.organisation = NameTagger.partOfOrganisation(range, in: text)
        let value = ns.substring(with: NSRange(location: range.lowerBound, length: range.count)).lowercased()
        signals.place = Names.citiesFolded.contains(value) || Places.region(value) != nil || ContextStage.nations.contains(ContextStage.normalPlace(value))
        return signals
    }

    /// A first name the lists hold: among the commonest, or one given clearly to girls or to boys ("Zofia", "Mateus").
    static func listedFirst(_ word: String) -> Bool {
        NameLists.isFirst(word) || NameLists.shared.female.contains(word) || NameLists.shared.male.contains(word)
    }

    /// Nothing but space between the start of its line, or the end of a sentence, and `index`.
    private static func opens(_ index: Int, _ ns: NSString) -> Bool {
        var at = index
        while at > 0, ns.character(at: at - 1) == 32 || ns.character(at: at - 1) == 9 { at -= 1 }
        guard at > 0 else { return true }
        return [10, 13, 46, 33, 63, 34, 0x201C, 40, 62, 45, 58].contains(ns.character(at: at - 1))
    }
}

/// Every person only a model read in the texts a detector judged, for
/// fitting and checking the scorer (Tools/PersonScorer). Nothing in a scrub sets it.
final class PersonLog {
    struct Candidate {
        let range: Range<Int>
        /// "name" for the name model's guess, "context" for the context model's.
        let source: String
        let signals: PersonScorer.Signals
        let probability: Double
        /// What the hand rules decide.
        let hand: Bool
        /// Nothing else found there, so keeping it would add a finding.
        let free: Bool
        /// Made of ordinary words with nothing around it marking a name (`NameShape.ordinaryGuess`): never kept.
        let ordinary: Bool
    }
    var candidates: [Candidate] = []
    /// People other detectors found, which need no model's guess.
    var others: [Range<Int>] = []
}
