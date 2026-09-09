import Foundation
import UIKit
import SwiftTerm
import os.log

/// Manages state for the terminal file browser panel.
///
/// Shell sessions use a **WebSocket** connection that mirrors exactly what the web
/// UI does. No HTTP polling — characters appear instantly.
///
/// Protocol (matches web UI's inspector traffic):
///   1. POST  /api/v1/terminals/{serverId}/api/terminals            → `{"id": "xxxx"}`
///   2. WS    wss(s)://{server}/api/v1/terminals/{serverId}/api/terminals/{id}
///   3. Send  text  `{"type":"auth","token":"<jwt>"}`
///   4. Send  text  `{"type":"resize","cols":N,"rows":M}`
///   5. Recv  binary frames  → feed to SwiftTerm
///   6. Send  binary frames  ← from SwiftTerm keystrokes
///   7. Send  text  `{"type":"ping"}`  every 25 s (keepalive)
///
/// Lifecycle:
/// - Call `handlePanelOpened()` whenever the terminal panel becomes visible.
/// - Call `handlePanelClosed()` whenever the panel is hidden/dismissed.
/// - Call `handleAppBackground()` when the app goes to background (scenePhase).
/// - Call `handleAppForeground()` when the app returns to foreground (scenePhase).
/// - Call `reset()` when switching chats (full teardown).
///
/// Auto-reconnect: on unexpected disconnect the VM waits 1 s, 2 s, 4 s… before giving up.
/// Intentional disconnects (panel closed, app backgrounded) suppress auto-reconnect.
@MainActor @Observable
final class TerminalBrowserViewModel {
    // MARK: - File Browser State

    var currentPath: String = "/home/user"
    var items: [TerminalFileItem] = []
    var isLoading: Bool = false
    var errorMessage: String?
    var pathHistory: [String] = []

    // MARK: - Shell Session State

    var isShellStarting: Bool = false
    var isShellReady: Bool = false
    var isTerminalExpanded: Bool = false

    // MARK: - Action State

    var showNewFolderAlert: Bool = false
    var newFolderName: String = ""
    var renamingFile: TerminalFileItem?
    var renameText: String = ""

    // MARK: - SwiftTerm Bridge

    weak var terminalView: TerminalView?

    // MARK: - Private

    private var apiClient: APIClient?
    private var serverId: String = ""
    private let logger = Logger(subsystem: "com.openui", category: "TerminalBrowser")

    // WebSocket state
    private var wsTask: URLSessionWebSocketTask?
    private var wsSession: URLSession?
    private var wsReceiveTask: Task<Void, Never>?
    private var wsPingTask: Task<Void, Never>?
    private var terminalSessionId: String?

    // Set to true when WE initiated the disconnect (panel closed, app backgrounded).
    // Prevents the receive-loop error path from triggering auto-reconnect.
    private var intentionalDisconnect: Bool = false

    // Set to true the first time any data arrives on the current WS connection.
    // If the receive loop errors before this is set, the server-side PTY session
    // is likely dead and we should fall back to a brand-new session instead of
    // retrying the same stale session ID.
    private var wsSessionReceivedData: Bool = false

    // True while the terminal panel is visible — used to gate auto-reconnect
    // so we don't reconnect when the panel is closed.
    private var isPanelOpen: Bool = false

    // Auto-reconnect
    private var autoReconnectTask: Task<Void, Never>?
    private var reconnectAttempt: Int = 0
    private static let maxReconnectAttempts = 5
    private static let reconnectDelays: [UInt64] = [
        1_000_000_000,   // 1 s
        2_000_000_000,   // 2 s
        4_000_000_000,   // 4 s
        8_000_000_000,   // 8 s
        15_000_000_000,  // 15 s
    ]

    // Terminal dimensions (updated by TerminalHostView on layout)
    var terminalCols: Int = 120
    var terminalRows: Int = 24

    // MARK: - Computed

    var pathSegments: [(name: String, path: String)] {
        let components = currentPath.split(separator: "/").map(String.init)
        var segments: [(name: String, path: String)] = [("/", "/")]
        var accumulated = ""
        for component in components {
            accumulated += "/\(component)"
            segments.append((component, accumulated))
        }
        return segments
    }

    var sortedItems: [TerminalFileItem] {
        let dirs = items.filter(\.isDirectory).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let files = items.filter { !$0.isDirectory }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return dirs + files
    }

    // MARK: - Setup

    func configure(apiClient: APIClient, serverId: String) {
        if self.serverId == serverId, isShellReady { return }
        self.apiClient = apiClient
        self.serverId = serverId
    }

    func reset() {
        cancelAutoReconnect()
        intentionalDisconnect = true
        disconnectWebSocket()
        currentPath = "/home/user"
        items = []
        isLoading = false
        errorMessage = nil
        pathHistory = []
        isShellStarting = false
        isShellReady = false
        isTerminalExpanded = false
        isPanelOpen = false
        showNewFolderAlert = false
        newFolderName = ""
        renamingFile = nil
        renameText = ""
        terminalView = nil
        reconnectAttempt = 0
        terminalSessionId = nil
        intentionalDisconnect = false
    }

    // MARK: - Panel Lifecycle

    /// Call when the terminal panel becomes visible (panel slides open, terminal section expands).
    func handlePanelOpened() {
        isPanelOpen = true
        intentionalDisconnect = false
        reconnectIfNeeded()
    }

    /// Call when the terminal panel is hidden/dismissed (panel slides closed, file browser closed).
    /// Cleanly disconnects the WebSocket without a full reset so the session can be resumed.
    func handlePanelClosed() {
        isPanelOpen = false
        guard isShellReady || isShellStarting else { return }
        logger.info("Terminal panel closed — disconnecting WebSocket cleanly")
        intentionalDisconnect = true
        cancelAutoReconnect()
        tearDownWebSocket()
        isShellReady = false
        isShellStarting = false
        // Keep terminalSessionId so we can attempt to reconnect to the same session later
    }

    /// Call when the app goes to background (scenePhase == .background/.inactive).
    /// Stops the ping loop to save battery but leaves the WebSocket open so the
    /// PTY session keeps running on the server (e.g. a script waiting for input).
    /// iOS will drop the socket naturally when the process is suspended — we'll
    /// detect that via the receive loop error and reconnect to the same session
    /// when we return to the foreground.
    func handleAppBackground() {
        // Cancel the ping loop so we're not burning battery/network in the background.
        wsPingTask?.cancel()
        wsPingTask = nil
        // Cancel any pending auto-reconnect timers.
        cancelAutoReconnect()
        logger.info("App backgrounded — ping loop stopped, WebSocket left open")
        // NOTE: intentionalDisconnect stays false so if iOS kills the socket
        // the receive-loop will still flag it as an unexpected disconnect.
        // We just won't auto-reconnect until foreground is restored.
    }

    /// Call when the app returns to foreground (scenePhase == .active).
    /// Restarts the ping loop if the shell is still alive, or reconnects to
    /// the existing PTY session if iOS dropped the socket while suspended.
    func handleAppForeground() {
        guard isPanelOpen, isTerminalExpanded else { return }
        intentionalDisconnect = false

        if isShellReady, let wsTask, wsTask.state == .running {
            // Socket is still alive — just restart the ping loop.
            logger.info("App foregrounded — shell alive, restarting ping loop")
            wsPingTask = Task { await pingLoop() }
        } else {
            // Socket was dropped — reconnect to the existing PTY session.
            logger.info("App foregrounded — socket dropped, reconnecting to existing session")
            isShellReady = false
            isShellStarting = false
            reconnectAttempt = 0
            reconnectIfNeeded()
        }
    }

    // MARK: - Navigation

    func loadDirectory() async {
        guard let apiClient, !serverId.isEmpty else { return }
        isLoading = true
        errorMessage = nil
        do {
            items = try await apiClient.terminalListFiles(serverId: serverId, path: currentPath)
        } catch {
            logger.error("Failed to list files at \(self.currentPath): \(error.localizedDescription)")
            errorMessage = error.localizedDescription
            items = []
        }
        isLoading = false
    }

    func navigateToDirectory(_ path: String) {
        pathHistory.append(currentPath)
        currentPath = path
        Task { await loadDirectory() }
    }

    func navigateToPath(_ path: String) {
        guard path != currentPath else { return }
        pathHistory.append(currentPath)
        currentPath = path
        Task { await loadDirectory() }
    }

    func navigateBack() {
        guard let previous = pathHistory.popLast() else { return }
        currentPath = previous
        Task { await loadDirectory() }
    }

    func refresh() {
        Task { await loadDirectory() }
    }

    // MARK: - File Operations

    func createFolder(name: String) async {
        guard let apiClient, !serverId.isEmpty else { return }
        let folderPath = currentPath.hasSuffix("/") ? "\(currentPath)\(name)" : "\(currentPath)/\(name)"
        do {
            try await apiClient.terminalMkdir(serverId: serverId, path: folderPath)
            await loadDirectory()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteItem(_ item: TerminalFileItem) async {
        guard let apiClient, !serverId.isEmpty else { return }
        do {
            try await apiClient.terminalDeleteFile(serverId: serverId, path: item.path)
            items.removeAll { $0.path == item.path }
        } catch {
            errorMessage = error.localizedDescription
            await loadDirectory()
        }
    }

    func renameItem(_ item: TerminalFileItem, to newName: String) async {
        guard let apiClient, !serverId.isEmpty else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != item.name else { return }
        let parentPath = (item.path as NSString).deletingLastPathComponent
        let newPath = parentPath.hasSuffix("/")
            ? "\(parentPath)\(trimmed)"
            : "\(parentPath)/\(trimmed)"
        do {
            try await apiClient.terminalMoveFile(serverId: serverId, sourcePath: item.path, destinationPath: newPath)
            await loadDirectory()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func downloadFile(_ item: TerminalFileItem) async -> URL? {
        guard let apiClient, !serverId.isEmpty else { return nil }
        do {
            let (data, _) = try await apiClient.terminalDownloadFile(serverId: serverId, path: item.path)
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("terminal_downloads", isDirectory: true)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let fileURL = tempDir.appendingPathComponent(item.name)
            try data.write(to: fileURL)
            return fileURL
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func uploadFile(data: Data, fileName: String) async {
        guard let apiClient, !serverId.isEmpty else { return }
        do {
            try await apiClient.terminalUploadFile(
                serverId: serverId, fileData: data, fileName: fileName, destinationPath: currentPath
            )
            await loadDirectory()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - WebSocket Shell Session

    /// Connects to an existing PTY session (no new POST). Used when returning
    /// from background or after an unexpected WebSocket drop.
    func reconnectToExistingSession() async {
        guard let apiClient, !serverId.isEmpty else { return }
        guard let sessionId = terminalSessionId else {
            // No existing session — fall through to creating a fresh one.
            await startShell()
            return
        }
        guard !isShellReady, !isShellStarting else { return }

        isShellStarting = true
        intentionalDisconnect = false

        do {
            let wsURL = try buildWebSocketURL(sessionId: sessionId)
            logger.info("Reconnecting to existing PTY session \(sessionId)")
            connectWebSocket(url: wsURL, token: apiClient.network.authToken ?? "")
            reconnectAttempt = 0
        } catch {
            isShellStarting = false
            isShellReady = false
            logger.error("Failed to reconnect to existing session: \(error.localizedDescription)")
            // Existing session may be gone — create a fresh one
            terminalSessionId = nil
            scheduleAutoReconnect()
        }
    }

    /// Start a brand-new shell session (POSTs to create a new PTY on the server).
    func startShell() async {
        guard let apiClient, !serverId.isEmpty else { return }
        guard !isShellReady, !isShellStarting else { return }

        isShellStarting = true
        intentionalDisconnect = false

        do {
            // Step 1: Create terminal session on the server
            let sessionId = try await apiClient.terminalCreateSession(serverId: serverId)
            terminalSessionId = sessionId
            logger.info("Terminal session created: \(sessionId)")

            // Step 2: Build WebSocket URL
            let wsURL = try buildWebSocketURL(sessionId: sessionId)
            logger.info("Connecting WS to: \(wsURL)")

            // Step 3: Connect WebSocket
            connectWebSocket(url: wsURL, token: apiClient.network.authToken ?? "")

            // Reset reconnect counter on successful connect
            reconnectAttempt = 0

        } catch {
            isShellStarting = false
            isShellReady = false
            let errMsg = "\r\n\u{001B}[31m[Failed to start terminal: \(error.localizedDescription)]\u{001B}[0m\r\n"
            feedToTerminal(errMsg)
            logger.error("Failed to start shell: \(error.localizedDescription)")
            // Schedule a retry if we haven't exhausted attempts
            scheduleAutoReconnect()
        }
    }

    /// Call this whenever the terminal section becomes visible (panel opens,
    /// terminal section expands, fullscreen toggled). If the shell is not
    /// running it will reconnect to the existing session or start a new one.
    func reconnectIfNeeded() {
        guard !isShellReady, !isShellStarting else { return }
        guard apiClient != nil, !serverId.isEmpty else { return }
        // Cancel any pending backoff reconnect — we want to reconnect NOW
        cancelAutoReconnect()
        reconnectAttempt = 0
        intentionalDisconnect = false
        if terminalSessionId != nil {
            // Reconnect to the existing PTY — don't spin up a new session
            Task { await reconnectToExistingSession() }
        } else {
            Task { await startShell() }
        }
    }

    private func buildWebSocketURL(sessionId: String) throws -> URL {
        guard let apiClient else { throw URLError(.badURL) }
        var serverURL = apiClient.baseURL
        // Trim trailing slash
        if serverURL.hasSuffix("/") { serverURL = String(serverURL.dropLast()) }

        // Convert http(s) → ws(s)
        var wsURLString = serverURL
        if wsURLString.hasPrefix("https://") {
            wsURLString = "wss://" + wsURLString.dropFirst("https://".count)
        } else if wsURLString.hasPrefix("http://") {
            wsURLString = "ws://" + wsURLString.dropFirst("http://".count)
        }

        let path = "/api/v1/terminals/\(serverId)/api/terminals/\(sessionId)"
        guard let url = URL(string: wsURLString + path) else {
            throw URLError(.badURL)
        }
        return url
    }

    private func connectWebSocket(url: URL, token: String) {
        // Tear down any existing connection first
        tearDownWebSocket()

        // Create a new URLSession with no timeouts for the WS
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = .infinity
        config.timeoutIntervalForResource = .infinity
        config.waitsForConnectivity = true
        config.httpCookieStorage = HTTPCookieStorage.shared

        let session = URLSession(configuration: config)
        wsSession = session

        var request = URLRequest(url: url)
        request.timeoutInterval = .infinity
        let task = session.webSocketTask(with: request)
        wsTask = task
        task.resume()

        // Auth handshake — use a small delay so the TCP handshake completes
        // before we send frames. URLSessionWebSocketTask buffers sends, so
        // this is safe even if the connection isn't open yet.
        sendTextFrame(["type": "auth", "token": token])

        // Resize to current terminal dimensions
        sendTextFrame(["type": "resize", "cols": terminalCols, "rows": terminalRows])

        // Start receive loop and ping timer
        // Reset the "data received" sentinel for this new connection.
        wsSessionReceivedData = false

        wsReceiveTask = Task { await receiveLoop() }
        wsPingTask = Task { await pingLoop() }

        isShellReady = true
        isShellStarting = false
        logger.info("WebSocket connected and authenticated")
    }

    /// Tears down the WS tasks without touching isShellReady/isShellStarting.
    private func tearDownWebSocket() {
        wsReceiveTask?.cancel()
        wsReceiveTask = nil
        wsPingTask?.cancel()
        wsPingTask = nil
        wsTask?.cancel(with: .normalClosure, reason: nil)
        wsTask = nil
        wsSession?.invalidateAndCancel()
        wsSession = nil
    }

    private func sendTextFrame(_ dict: [String: Any]) {
        guard let wsTask else { return }
        // URLSessionWebSocketTask buffers messages until the connection is open,
        // so we don't gate on `.running` here — the task may be in `.suspended`
        // briefly right after creation.
        guard wsTask.state != .canceling, wsTask.state != .completed else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let str = String(data: data, encoding: .utf8) else { return }
        wsTask.send(.string(str)) { [weak self] error in
            if let error {
                self?.logger.error("WS send text error: \(error.localizedDescription)")
            }
        }
    }

    /// Called by `TerminalViewDelegate.send()` — user typed something in SwiftTerm.
    /// Sends the raw bytes as a binary WebSocket frame — exactly what the web UI does.
    func sendRawToServer(_ data: ArraySlice<UInt8>) {
        guard let wsTask, wsTask.state == .running else { return }
        let bytes = Data(data)
        wsTask.send(.data(bytes)) { [weak self] error in
            if let error {
                self?.logger.error("WS send binary error: \(error.localizedDescription)")
            }
        }
    }

    /// Sends a raw control sequence to the shell (Tab, arrows, Ctrl+C, etc.)
    func sendControlSequence(_ bytes: String) {
        guard let data = bytes.data(using: .utf8) else { return }
        guard let wsTask, wsTask.state == .running else { return }
        wsTask.send(.data(data)) { [weak self] error in
            if let error {
                self?.logger.error("WS send ctrl error: \(error.localizedDescription)")
            }
        }
    }

    /// Notifies the server of a terminal resize event.
    func sendResize(cols: Int, rows: Int) {
        terminalCols = cols
        terminalRows = rows
        guard isShellReady else { return }
        sendTextFrame(["type": "resize", "cols": cols, "rows": rows])
    }

    /// Clears the SwiftTerm screen and scrollback.
    func clearTerminal() {
        terminalView?.getTerminal().resetToInitialState()
        sendControlSequence("\u{0C}") // Ctrl+L
    }

    // MARK: - WebSocket Receive Loop

    private func receiveLoop() async {
        while !Task.isCancelled {
            guard let wsTask else { break }

            do {
                let message = try await wsTask.receive()
                // Mark that the server has acknowledged this session and sent real data.
                wsSessionReceivedData = true
                switch message {
                case .data(let data):
                    // Raw PTY output — feed directly to SwiftTerm
                    let slice = ArraySlice(data)
                    feedBytesToTerminal(slice)

                case .string(let str):
                    // Control messages from server (rare)
                    logger.debug("WS text frame: \(str)")

                @unknown default:
                    break
                }
            } catch {
                if Task.isCancelled { break }
                // Only treat as unexpected if we didn't intentionally close things
                if intentionalDisconnect { break }
                logger.error("WS receive error: \(error.localizedDescription)")
                await handleUnexpectedDisconnect(sessionWasAlive: wsSessionReceivedData)
                break
            }
        }
    }

    private func pingLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 25_000_000_000) // 25 seconds
            if Task.isCancelled { break }
            guard isShellReady, !intentionalDisconnect else { break }
            guard let wsTask, wsTask.state == .running else {
                // Task is no longer running — handleUnexpectedDisconnect will be called
                // by the receive loop error, so just exit ping loop
                break
            }
            sendTextFrame(["type": "ping"])
        }
    }

    @MainActor
    private func handleUnexpectedDisconnect(sessionWasAlive: Bool = true) async {
        guard isShellReady, !intentionalDisconnect else { return }
        isShellReady = false
        tearDownWebSocket()

        if sessionWasAlive {
            // Session was alive (we received data) — keep the session ID so we
            // reconnect to the same PTY and preserve running processes.
            logger.info("Terminal WebSocket disconnected unexpectedly (session was alive)")
        } else {
            // The server closed the connection before sending any data — the
            // server-side PTY session is dead (e.g. server restarted, idle timeout).
            // Clear the stale ID so the reconnect path creates a fresh session.
            logger.info("Terminal WebSocket closed before receiving data — PTY session likely dead, will create fresh session")
            terminalSessionId = nil
        }

        // Auto-reconnect whenever the panel is open, regardless of whether the
        // terminal section is currently expanded. This prevents a race where the
        // panel opens (triggering a connect attempt that discovers the session is
        // dead) before the user has expanded the terminal row — the old guard
        // `isPanelOpen && isTerminalExpanded` would skip the retry, leaving a
        // blank terminal until the user tapped inside.
        if isPanelOpen {
            if isTerminalExpanded {
                feedToTerminal("\r\n\u{001B}[33m[Connection lost — reconnecting…]\u{001B}[0m\r\n")
            }
            reconnectAttempt = 0
            scheduleAutoReconnect()
        }
    }

    // MARK: - Auto-reconnect

    private func scheduleAutoReconnect() {
        guard reconnectAttempt < Self.maxReconnectAttempts else {
            // Exhausted retries against the existing session — the PTY is likely
            // gone. Clear the stale session ID and spin up a brand-new one
            // automatically instead of asking the user to tap ↺.
            logger.info("Auto-reconnect exhausted existing-session attempts — falling back to fresh session")
            terminalSessionId = nil
            reconnectAttempt = 0
            cancelAutoReconnect()
            autoReconnectTask = Task { [weak self] in
                // Brief pause before the final fresh-session attempt
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.startShell()
            }
            return
        }

        let delay = Self.reconnectDelays[min(reconnectAttempt, Self.reconnectDelays.count - 1)]
        let attempt = reconnectAttempt
        reconnectAttempt += 1

        logger.info("Auto-reconnect in \(delay / 1_000_000_000)s (attempt \(attempt + 1)/\(Self.maxReconnectAttempts))")

        cancelAutoReconnect()
        autoReconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            // Reconnect to the existing PTY session if we have one
            if let self, self.terminalSessionId != nil {
                await self.reconnectToExistingSession()
            } else {
                await self?.startShell()
            }
        }
    }

    private func cancelAutoReconnect() {
        autoReconnectTask?.cancel()
        autoReconnectTask = nil
    }

    // MARK: - Cleanup

    func disconnectWebSocket() {
        intentionalDisconnect = true
        cancelAutoReconnect()
        tearDownWebSocket()
        terminalSessionId = nil
        isShellReady = false
        isShellStarting = false
        reconnectAttempt = 0
    }

    // MARK: - Terminal Output Helpers

    /// Feeds raw bytes directly into SwiftTerm (no UTF-8 conversion needed).
    private func feedBytesToTerminal(_ bytes: ArraySlice<UInt8>) {
        terminalView?.feed(byteArray: bytes)
    }

    /// Feeds a string as raw bytes into SwiftTerm (for status messages).
    func feedToTerminal(_ text: String) {
        guard let filteredBytes = text.data(using: .utf8) else { return }
        let slice = ArraySlice(filteredBytes)
        terminalView?.feed(byteArray: slice)
    }
}
