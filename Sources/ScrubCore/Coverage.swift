import Foundation

/// Which of Scrub's own detectors ran. Each model and the name lists are
/// checked against a SHA-256 before they load; one that is missing or
/// altered is left out, and Scrub runs on with the rules and Apple's
/// detectors. That is weaker detection, so a result says so rather than
/// looking the same as a full one.
public struct Coverage: Sendable, Equatable {
    public enum Part: String, Sendable, CaseIterable {
        case nameModel, addressModel, contextModel, nameLists
    }
    /// What did not load, in the order of `Part.allCases`.
    public let missing: [Part]
    public var isReduced: Bool { !missing.isEmpty }
    public static let full = Coverage(missing: [])

    /// Parts a test withholds, as if their files had failed to load. Read in
    /// the scrub's own task when it starts (worker threads see no task-local
    /// values), so a scrub started in a `withValue` scope runs without them
    /// throughout. Nothing in the app sets it.
    @TaskLocal static var withheld: Set<Part> = []

    /// What this scrub can use, read once as it starts.
    static func current() -> Coverage {
        let withheld = withheld
        func absent(_ part: Part) -> Bool {
            if withheld.contains(part) { return true }
            switch part {
            case .nameModel: return NameModel.shared == nil
            case .addressModel: return AddressModel.shared == nil || AddressModel.wide == nil
            case .contextModel: return ContextModel.shared == nil
            case .nameLists: return NameLists.shared.first.isEmpty
            }
        }
        return Coverage(missing: Part.allCases.filter(absent))
    }

    func has(_ part: Part) -> Bool { !missing.contains(part) }
}
