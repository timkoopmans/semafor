import Foundation

/// Endpoint drift is a Review Focus class: providers change value types
/// (numbers ↔ strings) alongside key renames, and a hard decode failure would
/// blank the whole popover. Best-effort numeric decoding, nil on nonsense.
func lenientDouble<T: CodingKey>(_ container: KeyedDecodingContainer<T>, _ key: T) -> Double? {
    if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
        return value
    }
    if let text = try? container.decodeIfPresent(String.self, forKey: key),
       let value = Double(text)
    {
        return value
    }
    return nil
}

func lenientInt<T: CodingKey>(_ container: KeyedDecodingContainer<T>, _ key: T) -> Int? {
    if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
        return value
    }
    if let value = lenientDouble(container, key) {
        return Int(exactly: value.rounded())
    }
    return nil
}