import Foundation
import os.log

/// Disk cache for full conversation payloads — the **raw server JSON bytes**
/// returned by `GET /api/v1/chats/{id}`.
///
/// Caching raw bytes (instead of `Conversation` values) means the cached payload
/// round-trips losslessly through the existing `APIClient.parseFullConversation`
/// pipeline on rehydrate — including history-tree nodes with untyped
/// `output`/`usage` payloads that Codable would mangle. Inline base64 images are
/// preserved exactly as the server sent them.
///
/// Used for instant cold-start restore of the last-active chat: the view model
/// parses and displays the cached copy immediately while the network fetch runs
/// (stale-while-revalidate, mirroring the conversation-list cache).
///
/// Storage lives under `Library/Caches/Conversations/{serverKey}/` so iOS may
/// purge it under disk pressure with no correctness impact — the network fetch
/// is always authoritative. An LRU access-order (by file modification date)
/// caps the number of cached conversations.
final class ConversationContentCache: @unchecked Sendable {
    static let shared = ConversationContentCache()

    private let logger = Logger(subsystem: "com.openui", category: "ConversationContentCache")
    private let queue = DispatchQueue(label: "com.openui.conversationcontentcache", qos: .utility)

    /// Maximum number of conversations cached per server.
    private let maxCachedConversations = 10

    private func serverDirectory(forServer baseURL: String) -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let key = ConversationListCache.filenameKey(for: baseURL)
        let dir = base
            .appending(path: "Conversations", directoryHint: .isDirectory)
            .appending(path: key, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func fileURL(forConversation id: String, server baseURL: String) -> URL {
        let safeId = id.replacingOccurrences(of: "/", with: "_")
        return serverDirectory(forServer: baseURL).appending(path: "\(safeId).json")
    }

    // MARK: - API

    /// Returns the cached raw JSON payload for a conversation, or `nil`.
    /// Parsing is the caller's job (reuses the normal `parseFullConversation` path).
    func loadRaw(conversationId: String, serverBaseURL: String) -> Data? {
        let url = fileURL(forConversation: conversationId, server: serverBaseURL)
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        // Touch modification date so LRU eviction keeps recently-used conversations.
        queue.async {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        }
        return data
    }

    /// Persists a raw server payload. Fire-and-forget on a background queue;
    /// enforces the per-server LRU cap after the write.
    ///
    /// IMPORTANT: only call with a **complete, settled** payload — never
    /// mid-stream state. All call sites store either the server's own response
    /// bytes or a fully re-serialized post-sync snapshot.
    func storeRaw(_ data: Data, conversationId: String, serverBaseURL: String) {
        let url = fileURL(forConversation: conversationId, server: serverBaseURL)
        queue.async { [logger, maxCachedConversations] in
            do {
                try data.write(to: url, options: .atomic)
                self.evictIfNeeded(directory: url.deletingLastPathComponent(), cap: maxCachedConversations)
            } catch {
                logger.warning("Failed to store conversation content cache: \(error.localizedDescription)")
            }
        }
    }

    /// Removes a single conversation's cached payload (e.g. after deleting the chat).
    func remove(conversationId: String, serverBaseURL: String) {
        let url = fileURL(forConversation: conversationId, server: serverBaseURL)
        queue.async {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Removes all cached conversations across all servers.
    /// Called from `StorageManager.clearAllUserData()` on logout/server switch.
    func clearAll() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let root = base.appending(path: "Conversations", directoryHint: .isDirectory)
        queue.async { [logger] in
            do {
                if FileManager.default.fileExists(atPath: root.path) {
                    try FileManager.default.removeItem(at: root)
                }
            } catch {
                logger.warning("Failed to clear conversation content cache: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - LRU

    /// Evicts least-recently-used cache files until the directory holds ≤ cap items.
    private func evictIfNeeded(directory: URL, cap: Int) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]
        ) else { return }

        let jsonFiles = files.filter { $0.pathExtension == "json" }
        guard jsonFiles.count > cap else { return }

        let sortedByOldest = jsonFiles.sorted { a, b in
            let aDate = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let bDate = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return aDate < bDate
        }

        for file in sortedByOldest.prefix(jsonFiles.count - cap) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}