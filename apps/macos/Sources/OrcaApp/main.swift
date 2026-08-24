import AppKit
import COrca
import MediaPlayer
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

struct TrackRow: Identifiable {
    let id: Int64
    let title: String
    let album: String
    let artist: String
    /// Nil when the library does not know, which is not the same as zero.
    let durationMilliseconds: Int64?
    /// False greys the row out without a second question per Track.
    let hasFile: Bool

    var subtitle: String {
        guard let durationMilliseconds else { return "\(artist) — \(album)" }
        let seconds = durationMilliseconds / 1000
        return String(format: "%@ — %@ · %d:%02d", artist, album, seconds / 60, seconds % 60)
    }
}

private func copyString(_ view: orca_string_view) -> String {
    let bytes = UnsafeRawPointer(view.pointer).assumingMemoryBound(to: UInt8.self)
    return String(decoding: UnsafeBufferPointer(start: bytes, count: view.length), as: UTF8.self)
}

private let receiveTrack: orca_track_callback = { context, track in
    guard let context, let track else { return }
    let controller = Unmanaged<RuntimeController>.fromOpaque(context).takeUnretainedValue()
    controller.tracks.append(TrackRow(
        id: track.pointee.id,
        title: copyString(track.pointee.title),
        album: copyString(track.pointee.album),
        artist: copyString(track.pointee.artist),
        durationMilliseconds: track.pointee.has_duration != 0 ? track.pointee.duration_ms : nil,
        hasFile: track.pointee.has_file != 0
    ))
}

@MainActor
final class RuntimeController: ObservableObject {
    @Published var tracks: [TrackRow] = []
    @Published var query = ""
    @Published var offset: UInt32 = 0
    @Published var playbackState: UInt8 = UInt8(ORCA_TRANSPORT_STOPPED.rawValue)

    private let runtime: OpaquePointer
    private var player = orca_handle(index: 0, generation: 0)
    private var library: orca_handle?
    private var timer: Timer?

    init() {
        guard let runtime = orca_runtime_create() else { fatalError("Unable to create liborca") }
        self.runtime = runtime
        guard orca_player_create(runtime, &player) == ORCA_STATUS_OK else {
            fatalError("Unable to create Player")
        }
        if let path = ProcessInfo.processInfo.environment["ORCA_LIBRARY"] {
            var handle = orca_handle(index: 0, generation: 0)
            if orca_library_open(runtime, path, &handle) == ORCA_STATUS_OK { library = handle }
        }
        configureRemoteCommands()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshSnapshot() }
        }
        loadPage()
    }

    deinit {
        timer?.invalidate()
        if let library { _ = orca_library_close(runtime, library) }
        _ = orca_player_destroy(runtime, player)
        orca_runtime_destroy(runtime)
    }

    func loadPage() {
        tracks.removeAll(keepingCapacity: true)
        guard let library else { return }
        query.withCString { pointer in
            _ = orca_library_query_tracks(
                runtime,
                library,
                pointer,
                query.utf8.count,
                256,
                offset,
                Unmanaged.passUnretained(self).toOpaque(),
                receiveTrack
            )
        }
    }

    func openLibrary(_ url: URL) {
        var next = orca_handle(index: 0, generation: 0)
        guard orca_library_open(runtime, url.path, &next) == ORCA_STATUS_OK else { return }
        if let library { _ = orca_library_close(runtime, library) }
        library = next
        offset = 0
        loadPage()
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = "Library opened"
        content.body = url.lastPathComponent
        center.add(UNNotificationRequest(identifier: "library-opened", content: content, trigger: nil))
    }

    func search() { offset = 0; loadPage() }
    func previousPage() { offset = offset >= 256 ? offset - 256 : 0; loadPage() }
    func nextPage() { offset += 256; loadPage() }

    func togglePlayback() {
        refreshSnapshot()
        if playbackState == UInt8(ORCA_TRANSPORT_PLAYING.rawValue) {
            _ = orca_player_pause(runtime, player)
        } else {
            _ = orca_player_play(runtime, player)
        }
        refreshSnapshot()
    }

    /// Authoritative transport state, read as a snapshot rather than
    /// reconstructed from events. Pumping first lets the control lane execute
    /// anything this frontend submitted since the last tick.
    private func refreshSnapshot() {
        _ = orca_runtime_pump(runtime)
        var status = orca_player_status()
        guard orca_player_status_get(runtime, player, &status) == ORCA_STATUS_OK else { return }
        playbackState = status.transport
        let playing = playbackState == UInt8(ORCA_TRANSPORT_PLAYING.rawValue)
        MPNowPlayingInfoCenter.default().playbackState = playing ? .playing : .paused
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: "Orca",
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(status.position_ms) / 1000,
        ]
        if status.duration_ms != 0 {
            info[MPMediaItemPropertyPlaybackDuration] = Double(status.duration_ms) / 1000
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func configureRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            _ = orca_player_play(self.runtime, self.player)
            self.refreshSnapshot()
            return .success
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            _ = orca_player_pause(self.runtime, self.player)
            self.refreshSnapshot()
            return .success
        }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayback()
            return self == nil ? .commandFailed : .success
        }
    }
}

struct ContentView: View {
    @ObservedObject var controller: RuntimeController
    @State private var choosingLibrary = false

    var body: some View {
        VStack {
            HStack {
                TextField("Search tracks", text: $controller.query)
                    .onSubmit { controller.search() }
                    .accessibilityLabel("Search tracks")
                Button("Search") { controller.search() }
                    .keyboardShortcut("f", modifiers: .command)
            }
            List(controller.tracks) { track in
                VStack(alignment: .leading) {
                    Text(track.title)
                    Text(track.subtitle).font(.secondary)
                }
                .opacity(track.hasFile ? 1 : 0.5)
                .accessibilityLabel(track.hasFile ? track.title : "\(track.title), file unavailable")
            }
            HStack {
                Button("Open Library…") { choosingLibrary = true }
                Button("Previous") { controller.previousPage() }
                Button("Next") { controller.nextPage() }
                Spacer()
                Button("Play / Pause") { controller.togglePlayback() }
                    .keyboardShortcut(.space, modifiers: [])
            }
        }
        .padding()
        .frame(minWidth: 800, minHeight: 560)
        .fileImporter(isPresented: $choosingLibrary, allowedContentTypes: [.data]) { result in
            if case let .success(url) = result { controller.openLibrary(url) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let first = urls.first else { return false }
            controller.openLibrary(first)
            return true
        }
    }
}

@main
struct OrcaApp: App {
    @StateObject private var controller = RuntimeController()

    var body: some Scene {
        WindowGroup("Orca") { ContentView(controller: controller) }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Play / Pause") { controller.togglePlayback() }
                    .keyboardShortcut(.space, modifiers: [])
            }
        }
    }
}
