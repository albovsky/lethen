/// The lowest confidence a result needs to be reported, set by `--min-confidence`. The cases mirror
/// `Confidence` in `SourceGraph`, which this module cannot import.
public enum MinimumConfidence: String, CaseIterable, Equatable {
    /// Reports only results Lethen is certain about.
    case certain
    /// Reports every result, `certain` and `likely`.
    case likely

    public static let `default` = MinimumConfidence.likely

    init?(anyValue: Any) {
        if let option = anyValue as? MinimumConfidence {
            self = option
            return
        }
        guard let stringValue = anyValue as? String else { return nil }

        self.init(rawValue: stringValue)
    }
}
