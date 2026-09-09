import SwiftUI
import UIKit
import SwiftTerm
import UniformTypeIdentifiers
import QuickLook

// MARK: - SwiftTerm UIViewRepresentable

/// Wraps SwiftTerm's `TerminalView` (a real VT100/xterm emulator) as a SwiftUI view.
///
/// - User types directly into the terminal — no separate text field.
/// - `TerminalViewDelegate.send()` fires for every keypress and forwards bytes to the server.
/// - The VM feeds server output back via `terminalView.feed(byteArray:)`.
struct SwiftTermView: UIViewRepresentable {
    let viewModel: TerminalBrowserViewModel

    func makeUIView(context: Context) -> TerminalHostView {
        let tv = TerminalHostView(frame: .zero)
        tv.terminalDelegate = context.coordinator

        tv.backgroundColor = UIColor.black
        tv.nativeBackgroundColor = UIColor.black
        tv.nativeForegroundColor = UIColor(red: 0.0, green: 0.92, blue: 0.0, alpha: 1.0)

        viewModel.terminalView = tv
        return tv
    }

    func updateUIView(_ uiView: TerminalHostView, context: Context) {
        if viewModel.terminalView !== uiView {
            viewModel.terminalView = uiView
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    // MARK: - Coordinator (TerminalViewDelegate)

    final class Coordinator: NSObject, TerminalViewDelegate {
        let viewModel: TerminalBrowserViewModel

        init(viewModel: TerminalBrowserViewModel) {
            self.viewModel = viewModel
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            Task { @MainActor in
                self.viewModel.sendRawToServer(data)
            }
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            Task { @MainActor in
                self.viewModel.sendResize(cols: newCols, rows: newRows)
            }
        }
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
        func clipboardCopy(source: TerminalView, content: Data) {
            UIPasteboard.general.setData(content, forPasteboardType: "public.utf8-plain-text")
        }
        func clipboardRead(source: TerminalView) -> Data? {
            UIPasteboard.general.data(forPasteboardType: "public.utf8-plain-text")
        }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}

/// A `TerminalView` subclass that auto-resizes its terminal on layout.
final class TerminalHostView: TerminalView {
    private var lastAppliedSize: CGSize = .zero

    override func layoutSubviews() {
        super.layoutSubviews()
        updateTerminalSize()
    }

    func updateTerminalSize() {
        let newSize = bounds.size
        guard newSize.width.isFinite, newSize.width > 0,
              newSize.height.isFinite, newSize.height > 0,
              newSize != lastAppliedSize else { return }
        lastAppliedSize = newSize

        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let cellWidth = max(1.0, ("M" as NSString).size(withAttributes: attrs).width)
        let cellHeight = max(1.0, font.lineHeight * 1.2)

        let cols = max(2, Int(newSize.width / cellWidth))
        let rows = max(1, Int(newSize.height / cellHeight))

        let curCols = getTerminal().cols
        let curRows = getTerminal().rows
        if cols != curCols || rows != curRows {
            resize(cols: cols, rows: rows)
        }
    }
}

// MARK: - Terminal Browser View

struct TerminalBrowserView: View {
    @Bindable var viewModel: TerminalBrowserViewModel
    var onDismiss: () -> Void

    @Environment(\.theme) private var theme
    @State private var showFilePicker = false
    @State private var previewFileURL: URL?
    @State private var shareFileURL: URL?
    @State private var confirmDeleteItem: TerminalFileItem?
    @State private var isTerminalFullscreen = false

    var body: some View {
        // Single VStack — SwiftTermView is always in the same structural position.
        // We conditionally show/hide chrome around it to achieve fullscreen without
        // recreating the TerminalView (which would break the WebSocket connection).
        VStack(spacing: 0) {
            // ── Fullscreen header (only visible in fullscreen) ──
            if isTerminalFullscreen {
                HStack {
                    Button {
                        isTerminalFullscreen = false
                        Haptics.play(.light)
                    } label: {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .scaledFont(size: 14, weight: .semibold)
                            .foregroundStyle(theme.brandPrimary)
                            .frame(width: 32, height: 32)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Text("Terminal").scaledFont(size: 14, weight: .semibold).foregroundStyle(theme.textPrimary)
                    Spacer()
                    // Green dot when connected, nothing otherwise
                    Group {
                        if viewModel.isShellReady {
                            Circle().fill(.green).frame(width: 6, height: 6)
                        } else {
                            Color.clear.frame(width: 6, height: 6)
                        }
                    }
                    .frame(width: 32)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                Divider().foregroundStyle(theme.cardBorder.opacity(0.3))
            }

            // ── Normal file-browser chrome (hidden in fullscreen) ──
            if !isTerminalFullscreen {
                // Compact single-row header: close | breadcrumb (scrollable) | actions
                compactHeaderBar
                Divider().foregroundStyle(theme.cardBorder.opacity(0.3))
                fileListArea
            }

            // ── Terminal section — always in same structural position ──
            if isTerminalFullscreen || viewModel.isTerminalExpanded {
                if !isTerminalFullscreen {
                    Divider().foregroundStyle(theme.cardBorder.opacity(0.3))
                }
                terminalPanel(fullscreen: isTerminalFullscreen)
            }

            // ── Toggle bar (hidden in fullscreen) ──
            if !isTerminalFullscreen {
                terminalToggleBar
            }
        }
        .background(theme.background)
        .onChange(of: viewModel.isTerminalExpanded) { _, expanded in
            if expanded { viewModel.reconnectIfNeeded() }
        }
        .task { await viewModel.loadDirectory() }
        .alert("New Folder", isPresented: $viewModel.showNewFolderAlert) {
            TextField("Folder name", text: $viewModel.newFolderName)
            Button("Cancel", role: .cancel) { viewModel.newFolderName = "" }
            Button("Create") {
                let name = viewModel.newFolderName
                viewModel.newFolderName = ""
                Task { await viewModel.createFolder(name: name) }
            }
        }
        .alert(
            "Rename",
            isPresented: Binding(
                get: { viewModel.renamingFile != nil },
                set: { if !$0 { viewModel.renamingFile = nil } }
            )
        ) {
            TextField("New name", text: $viewModel.renameText)
            Button("Cancel", role: .cancel) { viewModel.renamingFile = nil }
            Button("Rename") {
                guard let item = viewModel.renamingFile else { return }
                let newName = viewModel.renameText
                viewModel.renamingFile = nil
                Task { await viewModel.renameItem(item, to: newName) }
            }
        }
        .confirmationDialog(
            "Delete \(confirmDeleteItem?.name ?? "")?",
            isPresented: Binding(get: { confirmDeleteItem != nil }, set: { if !$0 { confirmDeleteItem = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let item = confirmDeleteItem { Task { await viewModel.deleteItem(item) } }
                confirmDeleteItem = nil
            }
        } message: { Text("This action cannot be undone.") }
        .sheet(isPresented: $showFilePicker) {
            TerminalDocumentPicker { urls in
                for url in urls {
                    let ok = url.startAccessingSecurityScopedResource()
                    defer { if ok { url.stopAccessingSecurityScopedResource() } }
                    if let data = try? Data(contentsOf: url) {
                        Task { await viewModel.uploadFile(data: data, fileName: url.lastPathComponent) }
                    }
                }
            }
        }
        .quickLookPreview($previewFileURL)
        .sheet(item: $shareFileURL) { url in ShareSheetView(activityItems: [url]) }
    }

    // MARK: - Compact Header (breadcrumb + actions in one row)

    private var compactHeaderBar: some View {
        HStack(spacing: 6) {
            // Close button
            Button { onDismiss() } label: {
                Image(systemName: "xmark")
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)

            // Scrollable breadcrumb — fills available space
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(viewModel.pathSegments.enumerated()), id: \.element.path) { index, segment in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .scaledFont(size: 8, weight: .bold)
                                .foregroundStyle(theme.textTertiary)
                        }
                        Button {
                            viewModel.navigateToPath(segment.path); Haptics.play(.light)
                        } label: {
                            Text(segment.name)
                                .scaledFont(size: 12, weight: segment.path == viewModel.currentPath ? .bold : .medium)
                                .foregroundStyle(segment.path == viewModel.currentPath ? theme.brandPrimary : theme.textSecondary)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(segment.path == viewModel.currentPath ? theme.brandPrimary.opacity(0.1) : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Action icons (refresh, new folder, upload)
            Button { viewModel.refresh(); Haptics.play(.light) } label: {
                Image(systemName: "arrow.clockwise").scaledFont(size: 13, weight: .medium).foregroundStyle(theme.textSecondary)
                    .frame(width: 28, height: 28).contentShape(Circle())
            }.buttonStyle(.plain)
            Button { viewModel.showNewFolderAlert = true; Haptics.play(.light) } label: {
                Image(systemName: "folder.badge.plus").scaledFont(size: 13, weight: .medium).foregroundStyle(theme.textSecondary)
                    .frame(width: 28, height: 28).contentShape(Circle())
            }.buttonStyle(.plain)
            Button { showFilePicker = true; Haptics.play(.light) } label: {
                Image(systemName: "arrow.up.doc").scaledFont(size: 13, weight: .medium).foregroundStyle(theme.textSecondary)
                    .frame(width: 28, height: 28).contentShape(Circle())
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    // MARK: - File List

    private var fileListArea: some View {
        Group {
            if viewModel.isLoading && viewModel.items.isEmpty {
                VStack(spacing: 12) {
                    Spacer(); ProgressView(); Text("Loading...").scaledFont(size: 13).foregroundStyle(theme.textTertiary); Spacer()
                }.frame(maxWidth: .infinity)
            } else if let error = viewModel.errorMessage {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "exclamationmark.triangle").scaledFont(size: 28).foregroundStyle(theme.error)
                    Text(error).scaledFont(size: 13).foregroundStyle(theme.textSecondary).multilineTextAlignment(.center).padding(.horizontal)
                    Button("Retry") { viewModel.refresh() }.scaledFont(size: 13, weight: .semibold).foregroundStyle(theme.brandPrimary)
                    Spacer()
                }.frame(maxWidth: .infinity)
            } else if viewModel.sortedItems.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "folder").scaledFont(size: 28).foregroundStyle(theme.textTertiary)
                    Text("Empty directory").scaledFont(size: 13).foregroundStyle(theme.textTertiary)
                    Spacer()
                }.frame(maxWidth: .infinity)
            } else {
                List {
                    ForEach(viewModel.sortedItems) { item in
                        fileRow(item)
                            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                            .listRowBackground(Color.clear)
                            .listRowSeparatorTint(theme.cardBorder.opacity(0.3))
                    }
                }
                .listStyle(.plain)
                .refreshable { await viewModel.loadDirectory() }
            }
        }
    }

    private func fileRow(_ item: TerminalFileItem) -> some View {
        Button {
            if item.isDirectory { viewModel.navigateToDirectory(item.path); Haptics.play(.light) }
            else { Task { if let url = await viewModel.downloadFile(item) { previewFileURL = url } } }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.iconName)
                    .scaledFont(size: 18)
                    .foregroundStyle(item.isDirectory ? theme.brandPrimary : iconColor(for: item))
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).scaledFont(size: 14, weight: item.isDirectory ? .semibold : .regular).foregroundStyle(theme.textPrimary).lineLimit(1)
                    if let size = item.formattedSize { Text(size).scaledFont(size: 11).foregroundStyle(theme.textTertiary) }
                }
                Spacer()
                if item.isDirectory { Image(systemName: "chevron.right").scaledFont(size: 11, weight: .semibold).foregroundStyle(theme.textTertiary) }
            }
            .padding(.vertical, 4).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { confirmDeleteItem = item } label: { Label("Delete", systemImage: "trash") }
            if !item.isDirectory {
                Button { Task { if let url = await viewModel.downloadFile(item) { shareFileURL = url } } } label: { Label("Download", systemImage: "arrow.down.circle") }.tint(theme.brandPrimary)
            }
        }
        .contextMenu {
            if !item.isDirectory {
                Button { Task { if let url = await viewModel.downloadFile(item) { previewFileURL = url } } } label: { Label("Preview", systemImage: "eye") }
                Button { Task { if let url = await viewModel.downloadFile(item) { shareFileURL = url } } } label: { Label("Download", systemImage: "arrow.down.circle") }
            }
            Button {
                NotificationCenter.default.post(name: .terminalInsertPath, object: item.path)
                Haptics.notify(.success)
            } label: { Label("Insert Path into Chat", systemImage: "arrow.turn.down.left") }
            Button { UIPasteboard.general.string = item.path; Haptics.notify(.success) } label: { Label("Copy Path", systemImage: "doc.on.doc") }
            Divider()
            Button {
                viewModel.renamingFile = item
                viewModel.renameText = item.name
                Haptics.play(.light)
            } label: { Label("Rename", systemImage: "pencil") }
            Button(role: .destructive) { confirmDeleteItem = item } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private func iconColor(for item: TerminalFileItem) -> SwiftUI.Color {
        switch item.fileExtension {
        case "py", "js", "ts", "swift", "java", "cpp", "c", "go", "rs", "rb": return .orange
        case "json", "yaml", "yml", "xml", "toml": return .purple
        case "md", "txt", "log": return theme.textSecondary
        case "png", "jpg", "jpeg", "gif", "svg": return .green
        case "pdf": return .red
        case "sh", "bash", "zsh": return .green
        default: return theme.textTertiary
        }
    }

    // MARK: - Terminal Toggle Bar

    private var terminalToggleBar: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { viewModel.isTerminalExpanded.toggle() }
            Haptics.play(.light)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "terminal").scaledFont(size: 13, weight: .semibold)
                Text("Terminal").scaledFont(size: 13, weight: .semibold)

                // Only show green dot when connected — no spinner or orange dot
                if viewModel.isShellReady {
                    Circle().fill(.green).frame(width: 6, height: 6).padding(.leading, 2)
                }

                Spacer()
                Image(systemName: viewModel.isTerminalExpanded ? "chevron.down" : "chevron.up")
                    .scaledFont(size: 11, weight: .bold)
            }
            .foregroundStyle(viewModel.isTerminalExpanded ? theme.brandPrimary : theme.textSecondary)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(theme.surfaceContainer.opacity(0.5))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Terminal Panel (shared between normal and fullscreen)

    private func terminalPanel(fullscreen: Bool) -> some View {
        VStack(spacing: 0) {
            // Toolbar row
            HStack(spacing: 0) {
                Spacer()

                if !viewModel.isShellReady && !viewModel.isShellStarting {
                    Button {
                        Task { await viewModel.startShell() }; Haptics.play(.light)
                    } label: {
                        Label("Restart", systemImage: "arrow.clockwise")
                            .scaledFont(size: 11, weight: .medium).foregroundStyle(theme.brandPrimary)
                    }
                    .buttonStyle(.plain).padding(.trailing, 12).padding(.vertical, 4)
                }

                Button {
                    viewModel.clearTerminal(); Haptics.play(.light)
                } label: {
                    Label("Clear", systemImage: "trash")
                        .scaledFont(size: 11, weight: .medium).foregroundStyle(theme.textTertiary)
                }
                .buttonStyle(.plain).padding(.trailing, 12).padding(.vertical, 4)

                if !fullscreen {
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            isTerminalFullscreen = true
                        }
                        Haptics.play(.light)
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .scaledFont(size: 13, weight: .medium).foregroundStyle(theme.textSecondary)
                    }
                    .buttonStyle(.plain).padding(.trailing, 12).padding(.vertical, 4)
                    .accessibilityLabel("Expand terminal")
                }
            }
            .background(Color.black.opacity(0.15))

            // The real terminal — user types directly here
            // SwiftTerm's built-in keyboard accessory provides Tab, arrows, Ctrl keys
            SwiftTermView(viewModel: viewModel)
                .frame(
                    minHeight: fullscreen ? 0 : 200,
                    maxHeight: fullscreen ? .infinity : 350
                )
        }
    }
}

// MARK: - Slide-Over Panel Container

struct TerminalSlideOverPanel: View {
    @Binding var isOpen: Bool
    @Bindable var viewModel: TerminalBrowserViewModel

    @Environment(\.theme) private var theme
    @GestureState private var dragOffset: CGFloat = 0
    private let panelWidthRatio: CGFloat = 0.85

    var body: some View {
        GeometryReader { geometry in
            let panelWidth = geometry.size.width * panelWidthRatio
            let offsetX = isOpen ? 0 : panelWidth

            ZStack(alignment: .trailing) {
                if isOpen {
                    Color.black.opacity(0.35).ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { isOpen = false }
                        }
                        .transition(.opacity)
                }

                TerminalBrowserView(
                    viewModel: viewModel,
                    onDismiss: { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { isOpen = false } }
                )
                .frame(width: panelWidth)
                .background(theme.background)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16, bottomTrailingRadius: 0, topTrailingRadius: 0, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 20, x: -5)
                .offset(x: max(0, offsetX + dragOffset))
                .onChange(of: isOpen) { _, open in
                    // Auto-reconnect the shell whenever the panel slides open
                    if open { viewModel.reconnectIfNeeded() }
                }
                .gesture(
                    DragGesture()
                        .updating($dragOffset) { value, state, _ in if value.translation.width > 0 { state = value.translation.width } }
                        .onEnded { value in
                            if value.translation.width > panelWidth * 0.3 {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { isOpen = false }
                            }
                        }
                )
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isOpen)
        }
    }
}

// MARK: - Right Edge Swipe Gesture

struct RightEdgeSwipeGesture: UIViewRepresentable {
    var isEnabled: Bool
    var onSwipe: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSwipe: onSwipe) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = true
        let edgeGesture = UIScreenEdgePanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleEdgeSwipe(_:)))
        edgeGesture.edges = .right
        view.addGestureRecognizer(edgeGesture)
        context.coordinator.gesture = edgeGesture
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.gesture?.isEnabled = isEnabled
        context.coordinator.onSwipe = onSwipe
    }

    class Coordinator: NSObject {
        var onSwipe: () -> Void
        weak var gesture: UIScreenEdgePanGestureRecognizer?
        init(onSwipe: @escaping () -> Void) { self.onSwipe = onSwipe }
        @objc func handleEdgeSwipe(_ recognizer: UIScreenEdgePanGestureRecognizer) {
            if recognizer.state == .recognized { onSwipe() }
        }
    }
}

// MARK: - Document Picker

private struct TerminalDocumentPicker: UIViewControllerRepresentable {
    let onPick: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        init(onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { onPick(urls) }
    }
}
