import Foundation
import AppKit

// MARK: - File System Input Observer
// Watches ~/Downloads and ~/Desktop (Screenshots) for newly arrived files,
// such as invoices, PDFs, zip archives, and screenshot captures.
@MainActor
public final class FileSystemInputObserver: ObservableObject {
    public static let shared = FileSystemInputObserver()

    private var isWatching = false
    private var downloadSource: (any DispatchSourceFileSystemObject)?
    private var desktopSource: (any DispatchSourceFileSystemObject)?
    private var knownDownloadFiles: Set<String> = []
    private var knownDesktopFiles: Set<String> = []
    private var debounceTimer: Timer?

    private init() {}

    func start(state: AppState) {
        guard !isWatching else { return }
        isWatching = true

        let fileManager = FileManager.default
        let downloadsURL = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first
        let desktopURL = fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first

        // Initialize known files snapshot
        if let dURL = downloadsURL, let files = try? fileManager.contentsOfDirectory(atPath: dURL.path) {
            knownDownloadFiles = Set(files)
        }
        if let dtURL = desktopURL, let files = try? fileManager.contentsOfDirectory(atPath: dtURL.path) {
            knownDesktopFiles = Set(files)
        }

        logSentinel("FileSystemInputObserver started watching ~/Downloads & ~/Desktop")

        if let dURL = downloadsURL {
            downloadSource = startWatching(url: dURL) { [weak self] in
                Task { @MainActor in
                    self?.handleFolderDelta(folderURL: dURL, isDesktop: false, state: state)
                }
            }
        }

        if let dtURL = desktopURL {
            desktopSource = startWatching(url: dtURL) { [weak self] in
                Task { @MainActor in
                    self?.handleFolderDelta(folderURL: dtURL, isDesktop: true, state: state)
                }
            }
        }
    }

    public func stop() {
        downloadSource?.cancel()
        desktopSource?.cancel()
        downloadSource = nil
        desktopSource = nil
        isWatching = false
    }

    private func startWatching(url: URL, onChange: @escaping @Sendable () -> Void) -> (any DispatchSourceFileSystemObject)? {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib, .link],
            queue: DispatchQueue.global(qos: .utility)
        )

        source.setEventHandler {
            onChange()
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        return source
    }

    private func handleFolderDelta(folderURL: URL, isDesktop: Bool, state: AppState) {
        // Debounce folder scan slightly to let write finalize
        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.scanFolder(folderURL: folderURL, isDesktop: isDesktop, state: state)
            }
        }
    }

    private func scanFolder(folderURL: URL, isDesktop: Bool, state: AppState) {
        let fileManager = FileManager.default
        guard let currentFiles = try? fileManager.contentsOfDirectory(atPath: folderURL.path) else { return }

        var known = isDesktop ? knownDesktopFiles : knownDownloadFiles
        let newItems = currentFiles.filter { !known.contains($0) }

        for file in newItems {
            known.insert(file)
            let fullURL = folderURL.appendingPathComponent(file)

            // Ignore hidden files and in-progress downloads
            let low = file.lowercased()
            if file.hasPrefix(".") ||
               low.hasSuffix(".crdownload") ||
               low.hasSuffix(".download") ||
               low.hasSuffix(".tmp") ||
               low.hasSuffix(".part") {
                continue
            }

            // Only process screenshot files on Desktop to avoid desktop clutter noise
            if isDesktop {
                let isScreenshot = low.hasPrefix("screenshot") || low.hasPrefix("ảnh chụp màn hình") || low.contains("screen shot")
                guard isScreenshot else { continue }
            }

            // Extract file preview content
            let snippet = extractFileSnippet(url: fullURL)
            let ext = fullURL.pathExtension.lowercased()

            let source: InputEventSource = isDesktop ? .screenshot : .fileDownload
            let appName = isDesktop ? "Screenshot" : "Downloads"

            let event = InputEvent(
                source: source,
                appName: appName,
                title: file,
                content: snippet,
                metadata: [
                    "filePath": fullURL.path,
                    "fileExtension": ext
                ]
            )

            ProactiveEventBus.shared.ingest(event: event, state: state)
        }

        if isDesktop {
            knownDesktopFiles = known
        } else {
            knownDownloadFiles = known
        }
    }

    private func extractFileSnippet(url: URL) -> String {
        let ext = url.pathExtension.lowercased()

        // 1. Plain text / Markdown / JSON / CSV
        let textExtensions = ["txt", "md", "json", "csv", "xml", "html", "swift", "py", "js", "ts", "log"]
        if textExtensions.contains(ext) {
            if let str = try? String(contentsOf: url, encoding: .utf8) {
                return String(str.prefix(1500))
            }
        }

        // 2. File size metadata
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int64 {
            let formattedSize = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            return "File: \(url.lastPathComponent), Loại: .\(ext), Dung lượng: \(formattedSize)"
        }

        return "File: \(url.lastPathComponent)"
    }
}
