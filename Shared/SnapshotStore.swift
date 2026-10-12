import Foundation

/// The app writes the latest snapshot into the shared app group container and
/// the widget reads it from there.
enum SnapshotStore {
    static let groupID = Bundle.main.object(forInfoDictionaryKey: "PaceAppGroup") as? String ?? ""

    private static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appendingPathComponent("snapshot.json")
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    static func load() -> Snapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(Snapshot.self, from: data)
    }

    static func save(_ snapshot: Snapshot) {
        guard let url = fileURL, let data = try? encoder.encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
