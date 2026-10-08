#if !APPSTORE
import Foundation
import AppKit
import Combine

// MARK: - Music Controller

enum MusicSource: String {
    case appleMusic = "Apple Music"
    case spotify = "Spotify"
}

/// Observes Apple Music and Spotify state via distributed notifications, provides periodic sync,
/// and provides playback controls.
/// Singleton, @MainActor, GitHub build only.
@MainActor
final class MusicController: ObservableObject {
    static let shared = MusicController()

    @Published var trackTitle: String?
    @Published var artist: String?
    @Published var album: String?
    @Published var currentSource: MusicSource = .appleMusic

    private var notifTokens: [Any] = []
    private var cancellables = Set<AnyCancellable>()
    private let queue = DispatchQueue(label: "fr.louisraille.coucou.music")
    private var isFetching = false

    private var isPillActive: Bool {
        AppState.shared.activeIntegrations.contains("integration_music")
    }

    private init() {
        // 1. Apple Music playerInfo observer
        let tok1 = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.Music.playerInfo"),
            object: nil,
            queue: .main
        ) { [weak self] notif in
            let info        = notif.userInfo
            let playerState = info?["Player State"] as? String
            let name        = info?["Name"]          as? String
            let artist      = info?["Artist"]        as? String
            let album       = info?["Album"]         as? String
            Task { @MainActor [weak self] in
                self?.handlePlayerInfo(source: .appleMusic, playerState: playerState, name: name, artist: artist, album: album)
            }
        }
        notifTokens.append(tok1)

        // 2. Spotify PlaybackStateChanged observer
        let tok2 = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil,
            queue: .main
        ) { [weak self] notif in
            let info        = notif.userInfo
            let playerState = info?["Player State"] as? String
            let name        = info?["Name"]          as? String
            let artist      = info?["Artist"]        as? String
            let album       = info?["Album"]         as? String
            Task { @MainActor [weak self] in
                self?.handlePlayerInfo(source: .spotify, playerState: playerState, name: name, artist: artist, album: album)
            }
        }
        notifTokens.append(tok2)

        // 3. Track launch of Music or Spotify
        let tok3 = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notif in
            let bundleId = (notif.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication)?.bundleIdentifier
            if bundleId == "com.apple.Music" || bundleId == "com.spotify.client" {
                Task { @MainActor [weak self] in
                    self?.fetchAndApply()
                }
            }
        }
        notifTokens.append(tok3)

        // 4. Clear state when Music/Spotify terminates
        let tok4 = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notif in
            let bundleId = (notif.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication)?.bundleIdentifier
            if bundleId == "com.apple.Music" || bundleId == "com.spotify.client" {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if !self.isMusicRunning() && !self.isSpotifyRunning() {
                        self.clearState()
                    } else {
                        self.fetchAndApply()
                    }
                }
            }
        }
        notifTokens.append(tok4)

        // 5. Observe activeIntegrations — only sync pill task name, do not clear global state
        AppState.shared.$activeIntegrations
            .sink { [weak self] _ in
                guard let self else { return }
                self.syncTaskName()
            }
            .store(in: &cancellables)

        // 6. Periodic sync timer (every 3s when player app is running)
        Timer.publish(every: 3.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                if self.isMusicRunning() || self.isSpotifyRunning() {
                    self.fetchAndApply()
                }
            }
            .store(in: &cancellables)

        // 7. Initial query immediately upon launch
        fetchAndApply()
    }

    // MARK: - Private helpers

    func isMusicRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.Music" }
    }

    func isSpotifyRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.spotify.client" }
    }

    // MARK: - Metadata cleaners

    private static func shortTitle(_ raw: String) -> String {
        guard !raw.isEmpty else { return raw }
        var s = raw
        // Cut at first " - "
        if let r = s.range(of: " - ") {
            s = String(s[..<r.lowerBound])
        }
        // Strip trailing (...) or [...] groups repeatedly
        var changed = true
        while changed {
            changed = false
            let t = s.trimmingCharacters(in: .whitespaces)
            guard let last = t.last, (last == ")" || last == "]") else { break }
            let open: Character = last == ")" ? "(" : "["
            if let idx = t.lastIndex(of: open) {
                let candidate = String(t[..<idx]).trimmingCharacters(in: .whitespaces)
                if !candidate.isEmpty { s = candidate; changed = true }
            } else { break }
        }
        let result = s.trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? raw : result
    }

    private static func shortArtist(_ raw: String) -> String {
        guard !raw.isEmpty else { return raw }
        let lower = raw.lowercased()
        for tag in [" feat.", " ft."] {
            if let r = lower.range(of: tag) {
                let result = String(raw[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                return result.isEmpty ? raw : result
            }
        }
        return raw
    }

    private func handlePlayerInfo(source: MusicSource, playerState: String?, name: String?, artist inputArtist: String?, album inputAlbum: String?) {
        currentSource = source
        let playing = (playerState?.lowercased() == "playing")
        let wasPlaying = AppState.shared.musicPlaying

        trackTitle = name.map { Self.shortTitle($0) }.flatMap { $0.isEmpty ? nil : $0 }
        artist     = inputArtist.map { Self.shortArtist($0) }.flatMap { $0.isEmpty ? nil : $0 }
        album      = inputAlbum

        AppState.shared.musicPlaying = playing
        syncTaskName()

        // Reveal only on transition from not-playing → playing
        if playing && !wasPlaying {
            NotificationCenter.default.post(name: .musicReveal, object: nil)
        }
    }

    func fetchAndApply() {
        guard !isFetching else { return }
        isFetching = true

        Task { [weak self] in
            defer { self?.isFetching = false }
            guard let self else { return }

            if self.isMusicRunning() {
                let result = await self.runAppleScript("""
                    tell application id "com.apple.Music"
                        set ps to player state as string
                        if ps is "stopped" then return {ps, "", "", ""}
                        try
                            set tr to current track
                            set n to name of tr
                        on error
                            return {ps, "", "", ""}
                        end try
                        set ar to ""
                        set al to ""
                        try
                            set ar to artist of tr
                        end try
                        try
                            set al to album of tr
                        end try
                        return {ps, n, ar, al}
                    end tell
                """)
                if case .success(let values) = result, values.count >= 4 {
                    let playing    = values[0].lowercased() == "playing"
                    let wasPlaying = AppState.shared.musicPlaying
                    self.currentSource = .appleMusic
                    self.trackTitle = values[1].isEmpty ? nil : Self.shortTitle(values[1])
                    self.artist     = values[2].isEmpty ? nil : Self.shortArtist(values[2])
                    self.album      = values[3].isEmpty ? nil : values[3]
                    AppState.shared.musicPlaying = playing
                    self.syncTaskName()
                    if playing && !wasPlaying {
                        NotificationCenter.default.post(name: .musicReveal, object: nil)
                    }
                    return
                }
            }

            if self.isSpotifyRunning() {
                let result = await self.runAppleScript("""
                    tell application id "com.spotify.client"
                        set ps to player state as string
                        if ps is "stopped" then return {ps, "", "", ""}
                        try
                            set n to name of current track
                            set ar to artist of current track
                            set al to album of current track
                            return {ps, n, ar, al}
                        on error
                            return {ps, "", "", ""}
                        end try
                    end tell
                """)
                if case .success(let values) = result, values.count >= 4 {
                    let playing    = values[0].lowercased() == "playing"
                    let wasPlaying = AppState.shared.musicPlaying
                    self.currentSource = .spotify
                    self.trackTitle = values[1].isEmpty ? nil : Self.shortTitle(values[1])
                    self.artist     = values[2].isEmpty ? nil : Self.shortArtist(values[2])
                    self.album      = values[3].isEmpty ? nil : values[3]
                    AppState.shared.musicPlaying = playing
                    self.syncTaskName()
                    if playing && !wasPlaying {
                        NotificationCenter.default.post(name: .musicReveal, object: nil)
                    }
                    return
                }
            }

            if !self.isMusicRunning() && !self.isSpotifyRunning() {
                self.clearState()
            }
        }
    }

    private func clearState() {
        trackTitle = nil
        artist = nil
        album = nil
        AppState.shared.musicPlaying = false
        syncTaskName()
    }

    private func syncTaskName() {
        guard let idx = AppState.shared.tasks.firstIndex(where: { $0.id == "integration_music" }) else { return }
        let title = trackTitle ?? ""
        AppState.shared.tasks[idx].name = title.isEmpty
            ? (PillCatalog.definition(for: "integration_music")?.name ?? (currentSource == .spotify ? "Spotify" : "Apple Music"))
            : title
    }

    // MARK: - Playback controls

    func playPause() {
        if currentSource == .spotify && isSpotifyRunning() {
            Task { await runAppleScript(#"tell application id "com.spotify.client" to playpause"#) }
        } else if isMusicRunning() {
            Task { await runAppleScript(#"tell application id "com.apple.Music" to playpause"#) }
        } else if isSpotifyRunning() {
            Task { await runAppleScript(#"tell application id "com.spotify.client" to playpause"#) }
        }
    }

    func nextTrack() {
        if currentSource == .spotify && isSpotifyRunning() {
            Task { await runAppleScript(#"tell application id "com.spotify.client" to next track"#) }
        } else if isMusicRunning() {
            Task { await runAppleScript(#"tell application id "com.apple.Music" to next track"#) }
        } else if isSpotifyRunning() {
            Task { await runAppleScript(#"tell application id "com.spotify.client" to next track"#) }
        }
    }

    func previousTrack() {
        if currentSource == .spotify && isSpotifyRunning() {
            Task { await runAppleScript(#"tell application id "com.spotify.client" to previous track"#) }
        } else if isMusicRunning() {
            Task { await runAppleScript(#"tell application id "com.apple.Music" to back track"#) }
        } else if isSpotifyRunning() {
            Task { await runAppleScript(#"tell application id "com.spotify.client" to previous track"#) }
        }
    }

    func openMusic() {
        if currentSource == .spotify && isSpotifyRunning(),
           let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.spotify.client" }) {
            app.activate(options: .activateIgnoringOtherApps)
        } else if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.Music" }) {
            app.activate(options: .activateIgnoringOtherApps)
        } else if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.spotify.client" }) {
            app.activate(options: .activateIgnoringOtherApps)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Music.app"))
        }
    }

    func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - AppleScript runner

    enum ScriptResult { case success([String]), denied, error }

    @discardableResult
    private func runAppleScript(_ source: String) async -> ScriptResult {
        await withCheckedContinuation { cont in
            queue.async {
                let script = NSAppleScript(source: source)!
                var errDict: NSDictionary?
                let desc = script.executeAndReturnError(&errDict)
                if let errDict {
                    let code = (errDict[NSAppleScript.errorNumber] as? Int) ?? 0
                    if code == -1743 {
                        Task { @MainActor in
                            AppState.shared.musicAutomationDenied = true
                            UserDefaults.standard.set(false, forKey: "coucou.musicAutomationGranted")
                        }
                        cont.resume(returning: .denied)
                    } else {
                        cont.resume(returning: .error)
                    }
                    return
                }
                Task { @MainActor in
                    UserDefaults.standard.set(true, forKey: "coucou.musicAutomationGranted")
                    AppState.shared.musicAutomationDenied = false
                }
                // Extract values on this queue before resuming (avoids NSAppleEventDescriptor Sendable issues)
                var values: [String] = []
                let count = desc.numberOfItems
                if count > 0 {
                    for i in 1...count {
                        values.append(desc.atIndex(i)?.stringValue ?? "")
                    }
                } else {
                    values = [desc.stringValue ?? ""]
                }
                cont.resume(returning: .success(values))
            }
        }
    }
}
#endif
