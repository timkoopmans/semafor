import Foundation

/// Percent-scale ambiguity (spec §6.1 spike note, shared by both providers):
/// payloads reporting only values in (0, 1] are treated as fractions of 100;
/// any value above 1 means the payload already speaks percent.
enum PercentScale {
    static func scale(values: [Double]) -> Double {
        (!values.isEmpty && values.allSatisfy { $0 <= 1.0 }) ? 100 : 1
    }
}
