//
//  ScriptStore.swift
//  notchprompt
//
//  Multi-script library: persists user scripts to Application Support so they
//  survive across launches and can be loaded into the teleprompter on demand.
//

import Foundation
import Combine

struct StoredScript: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    var body: String
    var createdAt: Date
    var updatedAt: Date
    var preferredWPM: Int?

    static func newUntitled(body: String = "") -> StoredScript {
        let now = Date()
        return StoredScript(
            id: UUID(),
            title: "Untitled",
            body: body,
            createdAt: now,
            updatedAt: now,
            preferredWPM: nil
        )
    }
}

@MainActor
final class ScriptStore: ObservableObject {
    static let shared = ScriptStore()

    @Published private(set) var scripts: [StoredScript] = []
    @Published var activeId: UUID?

    private let fileManager = FileManager.default
    private let scriptsDirectoryName = "scripts"
    private let activeIdDefaultsKey = "scriptStore.activeId"

    private init() {
        loadAll()
        if let raw = UserDefaults.standard.string(forKey: activeIdDefaultsKey),
           let uuid = UUID(uuidString: raw),
           scripts.contains(where: { $0.id == uuid }) {
            activeId = uuid
        }
    }

    // MARK: - Public API

    func loadAll() {
        do {
            let dir = try scriptsDirectory()
            let files = try fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var loaded: [StoredScript] = []
            for url in files {
                if let data = try? Data(contentsOf: url),
                   let script = try? decoder.decode(StoredScript.self, from: data) {
                    loaded.append(script)
                }
            }
            scripts = loaded.sorted { $0.updatedAt > $1.updatedAt }
        } catch {
#if DEBUG
            print("[Notchprompt][ScriptStore] loadAll failed: \(error)")
#endif
            scripts = []
        }
    }

    @discardableResult
    func create(title: String = "Untitled", body: String = "") -> StoredScript {
        let script = StoredScript(
            id: UUID(),
            title: title,
            body: body,
            createdAt: Date(),
            updatedAt: Date(),
            preferredWPM: nil
        )
        save(script)
        return script
    }

    /// Inserts or updates a script in the in-memory list and writes it to disk.
    /// Bumps `updatedAt` if content changed.
    func save(_ script: StoredScript) {
        var updated = script
        if let existingIndex = scripts.firstIndex(where: { $0.id == script.id }) {
            let existing = scripts[existingIndex]
            if existing.body != script.body || existing.title != script.title || existing.preferredWPM != script.preferredWPM {
                updated.updatedAt = Date()
            }
            scripts[existingIndex] = updated
        } else {
            scripts.insert(updated, at: 0)
        }
        scripts.sort { $0.updatedAt > $1.updatedAt }
        writeToDisk(updated)
    }

    func delete(id: UUID) {
        scripts.removeAll { $0.id == id }
        if activeId == id {
            activeId = nil
            UserDefaults.standard.removeObject(forKey: activeIdDefaultsKey)
        }
        do {
            let url = try fileURL(for: id)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        } catch {
#if DEBUG
            print("[Notchprompt][ScriptStore] delete failed: \(error)")
#endif
        }
    }

    /// Marks a script as the active one and loads its body into the teleprompter.
    func setActive(id: UUID) {
        guard let script = scripts.first(where: { $0.id == id }) else { return }
        activeId = id
        UserDefaults.standard.set(id.uuidString, forKey: activeIdDefaultsKey)
        PrompterModel.shared.script = script.body
        if let wpm = script.preferredWPM {
            PrompterModel.shared.setSpeed(Double(wpm))
        }
    }

    /// Convenience: persist the current teleprompter buffer into the active script
    /// (if any). Used when the user edits the body via Script Editor and wants
    /// the change to land in the library.
    func captureCurrentBuffer() {
        guard let id = activeId, var existing = scripts.first(where: { $0.id == id }) else { return }
        existing.body = PrompterModel.shared.script
        save(existing)
    }

    // MARK: - Filesystem

    private func scriptsDirectory() throws -> URL {
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        // Inside the sandbox this resolves under
        // ~/Library/Containers/com.gabrielfranklin.notchpromptpro/Data/Library/Application Support/
        let app = support.appendingPathComponent("notchprompt", isDirectory: true)
        let dir = app.appendingPathComponent(scriptsDirectoryName, isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private func fileURL(for id: UUID) throws -> URL {
        try scriptsDirectory().appendingPathComponent("\(id.uuidString).json")
    }

    private func writeToDisk(_ script: StoredScript) {
        do {
            let url = try fileURL(for: script.id)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(script)
            try data.write(to: url, options: .atomic)
        } catch {
#if DEBUG
            print("[Notchprompt][ScriptStore] writeToDisk failed: \(error)")
#endif
        }
    }
}
