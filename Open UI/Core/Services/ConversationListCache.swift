import Foundation
import os.log

/// Lightweight disk cache for the conversation **list** (summaries only — no message
/// content), used to render the drawer/sidebar instantly on launch while the real
/// page-1 fetch runs in the background (stale-while-revalidate).
///
/// Storage: one JSON file per server URL under `Application Support/ConversationListCache/`.
/// Application Support (not `Caches/`) is used because the list cache should survive
/// the OS's disk-pressure purges — a purged cache just means one slower launch,
/// never incorrect data. All data is cleared on logout/server switch via
/// `StorageManager.clearAllUserData()`.
///
/// The payload stores exactly the fields produced by
/// `APIClient.parseConversationSummary(_:)` — id, title, timestamps, model, pinned,
/// archived, folderId, tags — and rehydrates them into `Conversation` values with
/// empty history, so no model changes are needed. Serialization uses
/// `JSONSerialization` (matching the rest of the networking layer) rather than
/// Codable, keeping the entry type free of MainActor-isolated conformances.
final class ConversationListCache: @unchecked Sendable {
    static let shared = ConversationListCache()

    private let logger = Logger(subsystem: "com.openui", category: "ConversationListCache")
    private let queue = DispatchQueue(label: "com.openui.conversationlistcache", qos: .utility)

    private func cacheDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appending(path: "ConversationListCache", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Mirrors the `cached_user_{url}` key normalization used by AuthViewModel.
    static func filenameKey(for baseURL: String) -> String {
        let allowed = baseURL
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "://", with: "")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let trimmed = allowed.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return trimmed.isEmpty
            ? UUID().uuidString
            : String(trimmed.prefix(120))
    }

    private func fileURL(forServer baseURL: String) -> URL {
        cacheDirectory().appending(path: "\(Self.filenameKey(for: baseURL)).json")
    }

    // MARK: - Payload Conversion

    /// Serializes conversation summaries into the raw JSON payload.
    private static func payload(for conversations: [Conversation]) -> Data? {
        let entries: [[String: Any]] = conversations.map { conv in
            var dict: [String: Any] = [
                "id": conv.id,
                "title": conv.title,
                "created_at": conv.createdAt.timeIntervalSince1970,
                "updated_at": conv.updatedAt.timeIntervalSince1970,
                "pinned": conv.pinned,
                "archived": conv.archived,
                "tags": conv.tags
            ]
            if let model = conv.model { dict["model"] = model }
            if let folderId = conv.folderId { dict["folder_id"] = folderId }
            return dict
        }
        return try? JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys])
    }

    /// Rehydrates `Conversation` summaries from the raw JSON payload.
    private static func conversations(fromPayload data: Data) -> [Conversation]? {
        guard let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return nil
        }
        return array.compactMap { dict in
            guard let id = dict["id"] as? String else { return nil }
            let title = dict["title"] as? String ?? "New Chat"
            let createdAt = (dict["created_at"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? Date()
            let updatedAt = (dict["updated_at"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? Date()
            return Conversation(
                id: id,
                title: title,
                createdAt: createdAt,
                updatedAt: updatedAt,
                model: dict["model"] as? String,
                pinned: dict["pinned"] as? Bool ?? false,
                archived: dict["archived"] as? Bool ?? false,
                folderId: dict["folder_id"] as? String,
                tags: dict["tags"] as? [String] ?? []
            )
        }
    }

    // MARK: - API

    /// Returns the cached list for the given server, or `nil` if none exists.
    /// Main-actor safe: dispatches the file read + decode to a utility queue and
    /// waits, keeping the main actor free of file I/O and JSON parsing.
    func load(serverBaseURL: String) -> [Conversation]? {
        let url = fileURL(forServer: serverBaseURL)
        let result: [Conversation]? = queue.sync {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
            let decoded = Self.conversations(fromPayload: data)
            if decoded == nil {
                // Corrupt cache — remove it so the next store() rewrite is clean.
                try? FileManager.default.removeItem(at: url)
            }
            return decoded
        }
        return result
    }

    /// Persists the list for the given server. Fire-and-forget — the write happens
    /// on a background queue; failures are logged and otherwise ignored (the cache
    /// is purely an optimization).
    func store(_ conversations: [Conversation], serverBaseURL: String) {
        let url = fileURL(forServer: serverBaseURL)
        queue.async { [logger] in
            guard let data = Self.payload(for: conversations) else { return }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                logger.warning("Failed to store conversation list cache: \(error.localizedDescription)")
            }
        }
    }

    /// Removes every cached list (all servers). Called from
    /// `StorageManager.clearAllUserData()` on logout/server switch.
    func clearAll() {
        queue.async { [logger] in
            do {
                let dir = self.cacheDirectory()
                let contents = try FileManager.default.contentsOfDirectory(
                    at: dir,
                    includingPropertiesForKeys: nil
                )
                for file in contents where file.pathExtension == "json" {
                    try? FileManager.default.removeItem(at: file)
                }
            } catch {
                logger.warning("Failed to clear conversation list cache: \(error.localizedDescription)")
            }
        }
    }
}