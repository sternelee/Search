import Foundation

/// A separate store from browser tabs. Writes and removals share one queue;
/// deleting a conversation cannot be undone by an older pending save.
final class BotPersistence: @unchecked Sendable {
    let folder: URL
    private let queue = DispatchQueue(label: "search.bots.disk", qos: .utility)
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(folder: URL = Store.file("Bots")) { self.folder = folder }

    func read<T: Decodable>(_ type: T.Type, name: String) throws -> T? {
        try queue.sync {
            let file = folder.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            let data = try Data(contentsOf: file)
            do { return try decoder.decode(type, from: data) }
            catch {
                let aside = file.deletingPathExtension()
                    .appendingPathExtension("unreadable-\(UUID().uuidString).json")
                try FileManager.default.moveItem(at: file, to: aside)
                throw error
            }
        }
    }

    func write<T: Encodable>(_ value: T, name: String) throws {
        // Encode a value snapshot, never an ObservableObject on the disk queue.
        let data = try encoder.encode(value)
        try queue.sync { try put(data, name: name) }
    }

    func writeLater<T: Encodable, U: Encodable>(_ value: T, name: String, index: U,
                                              done: @escaping @Sendable (Error?) -> Void) throws {
        let data = try encoder.encode(value)
        let indexData = try encoder.encode(index)
        queue.async {
            do {
                try self.put(data, name: name)
                try self.put(indexData, name: "index.json")
                done(nil)
            } catch { done(error) }
        }
    }

    private func put(_ data: Data, name: String) throws {
        let files = FileManager.default
        try files.createDirectory(at: folder, withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let file = folder.appendingPathComponent(name)
        let temporary = folder.appendingPathComponent(".\(UUID().uuidString).tmp")
        guard files.createFile(atPath: temporary.path, contents: data,
                               attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? files.removeItem(at: temporary) }
        if files.fileExists(atPath: file.path) {
            _ = try files.replaceItemAt(file, withItemAt: temporary)
        } else {
            try files.moveItem(at: temporary, to: file)
        }
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    func remove(name: String) throws {
        try queue.sync {
            let file = folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
        }
    }
}
