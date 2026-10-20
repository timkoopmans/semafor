import Foundation

/// Loads files from `Tests/SemaforCoreTests/Fixtures/` without bundle resources.
func fixtureData(_ name: String) throws -> Data {
    let url = URL(fileURLWithPath: #filePath)
        .appendingPathComponent("../../Fixtures/\(name)")
        .standardizedFileURL
    return try Data(contentsOf: url)
}
