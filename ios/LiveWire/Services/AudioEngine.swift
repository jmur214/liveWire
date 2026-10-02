import AVFoundation
import Foundation
import MediaPlayer
import Observation

/// FIFO of transmissions waiting to be played (A3). Capacity 10: when full the
/// oldest is dropped and counted as skipped.
struct ClipQueue {
    private(set) var items: [Transmission] = []
    var capacity = 10
    private(set) var skipped = 0

    var isEmpty: Bool { items.isEmpty }
    var count: Int { items.count }

    /// Appends (ignoring duplicates); returns how many clips were dropped to stay within capacity.
    @discardableResult
    mutating func enqueue(_ t: Transmission) -> Int {
        if items.contains(where: { $0.id == t.id }) { return 0 }
        items.append(t)
        var dropped = 0
        while items.count > capacity {
            items.removeFirst()
            dropped += 1
        }
        skipped += dropped
        return dropped
    }

    mutating func dequeue() -> Transmission? {
        items.isEmpty ? nil : items.removeFirst()
    }

    mutating func removeAll() { items.removeAll() }

    mutating func removeAll(where predicate: (Transmission) -> Bool) { items.removeAll(where: predicate) }

    /// Returns the skipped count since the last call and resets it.
    mutating func takeSkipped() -> Int {
        defer { skipped = 0 }
        return skipped
    }
}

/// Live scanner queue + clip replay on top of AVAudioPlayer, with background
/// audio, Now Playing / lock-screen controls, metering for the pill, and a
/// 200-clip cache in Caches/clips.
@MainActor
@Observable
final class AudioEngine: NSObject, AVAudioPlayerDelegate {
    enum Mode: Equatable { case idle, live, replay, playAll }

    /// User intent: the live scanner is on (persisted as Settings.wasPlaying).
    private(set) var isLive = false
    private(set) var mode: Mode = .idle
    /// The clip playing right now.
    private(set) var current: Transmission?
    /// Most recent transmission heard; the pill shows its transcript while paused.
    private(set) var lastTransmission: Transmission?
    /// 0…1 from AVAudioPlayer metering at 10 Hz.
    private(set) var level: Float = 0
    /// Clips dropped from the queue; the pill shows "skipped N" for a few seconds.
    private(set) var skippedNotice = 0
    private(set) var queue = ClipQueue()
    private(set) var isBuffering = false

    private let settings: Settings
    private var api: APIClient?
    private var player: AVAudioPlayer?
    /// Loops silence while the scanner is on but no clip is playing, so iOS keeps the
    /// app (and its SSE connection) alive in the background between transmissions.
    private var keepAlive: AVAudioPlayer?
    private var meterTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var playAllRemaining: [Transmission] = []
    private var playToken = 0
    private let cacheDir: URL
    static let cacheLimit = 200

    init(settings: Settings) {
        self.settings = settings
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheDir = caches.appending(path: "clips", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        super.init()
        configureSession()
        configureRemoteCommands()
        observeInterruptions()
    }

    func configure(api: APIClient?) {
        self.api = api
    }

    var isPlayingSomething: Bool { mode != .idle }

    // MARK: - Live scanner

    func toggleLive() {
        if isLive { pauseLive() } else { startLive() }
    }

    func startLive() {
        guard !isLive else { return }
        isLive = true
        settings.wasPlaying = true
        activateSession()
        startKeepAlive()
        updatePlaybackState()
        drain()
    }

    func pauseLive() {
        isLive = false
        settings.wasPlaying = false
        if mode == .live {
            stopPlayer()
            mode = .idle
            current = nil
        }
        queue.removeAll()
        stopKeepAlive()
        updatePlaybackState()
    }

    /// Called by AppModel for each new transmission that passes the agency filter
    /// (and the dispatch-only rule). Clips are only queued while the scanner is on.
    func enqueue(_ t: Transmission) {
        lastTransmission = t
        guard isLive, t.audioFile != nil else { return }
        let dropped = queue.enqueue(t)
        if dropped > 0 { showSkipped(dropped) }
        drain()
    }

    /// Drop queued clips that no longer pass the filter (a chip was turned off).
    func dropQueued(where predicate: (Transmission) -> Bool) {
        queue.removeAll(where: predicate)
    }

    private func drain() {
        guard isLive, mode == .idle, !isBuffering, let next = queue.dequeue() else { return }
        play(next, as: .live)
    }

    // MARK: - Replay / play all

    /// Play one clip now. Live playback pauses and resumes afterwards.
    func replay(_ t: Transmission) {
        guard t.audioFile != nil else { return }
        playAllRemaining = []
        stopPlayer()
        play(t, as: .replay)
    }

    /// Detail "Play all": `list` must already be oldest → newest.
    func playAll(_ list: [Transmission]) {
        let items = list.filter { $0.audioFile != nil }
        guard let first = items.first else { return }
        playAllRemaining = Array(items.dropFirst())
        stopPlayer()
        play(first, as: .playAll)
    }

    /// Stop a replay / play-all early; live resumes if it was on.
    func stopReplay() {
        guard mode == .replay || mode == .playAll else { return }
        playAllRemaining = []
        stopPlayer()
        finished()
    }

    // MARK: - Playback

    private func play(_ t: Transmission, as m: Mode) {
        playToken += 1
        let token = playToken
        mode = m
        current = t
        lastTransmission = t
        isBuffering = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await self.cachedURL(for: t)
                guard token == self.playToken else { return }
                try self.startPlayer(url: url)
                self.isBuffering = false
                self.updateNowPlaying(t)
            } catch {
                guard token == self.playToken else { return }
                self.isBuffering = false
                self.finished()   // unplayable clip: move on
            }
        }
    }

    private func startPlayer(url: URL) throws {
        activateSession()
        let p = try AVAudioPlayer(contentsOf: url)
        p.delegate = self
        p.isMeteringEnabled = true
        p.prepareToPlay()
        p.play()
        player = p
        startMetering()
    }

    private func stopPlayer() {
        playToken += 1
        player?.stop()
        player = nil
        stopMetering()
        isBuffering = false
    }

    /// A clip ended (or failed): continue play-all, else go idle and let live drain.
    private func finished() {
        player = nil
        stopMetering()
        if mode == .playAll, !playAllRemaining.isEmpty {
            let next = playAllRemaining.removeFirst()
            play(next, as: .playAll)
            return
        }
        mode = .idle
        current = nil
        if isLive {
            drain()
        }
        updatePlaybackState()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.finished() }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in self?.finished() }
    }

    // MARK: - Session, remote commands, Now Playing

    private func configureSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [])
    }

    private func activateSession() {
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    // MARK: - Background keep-alive

    private func startKeepAlive() {
        guard keepAlive == nil else { return }
        guard let url = try? silentClipURL(), let p = try? AVAudioPlayer(contentsOf: url) else { return }
        p.numberOfLoops = -1
        p.volume = 0
        p.prepareToPlay()
        p.play()
        keepAlive = p
    }

    private func stopKeepAlive() {
        keepAlive?.stop()
        keepAlive = nil
    }

    /// One second of 16 kHz mono silence, written once to Caches.
    private func silentClipURL() throws -> URL {
        let url = cacheDir.appending(path: "_silence.wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let rate: UInt32 = 16_000, frames: UInt32 = 16_000, bits: UInt16 = 16, channels: UInt16 = 1
        let dataSize = frames * UInt32(channels) * UInt32(bits / 8)
        var d = Data()
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); le32(36 + dataSize); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); le32(16); le16(1); le16(channels); le32(rate)
        le32(rate * UInt32(channels) * UInt32(bits / 8)); le16(channels * bits / 8); le16(bits)
        d.append(contentsOf: Array("data".utf8)); le32(dataSize)
        d.append(Data(count: Int(dataSize)))
        try d.write(to: url, options: .atomic)
        return url
    }

    private func configureRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        _ = c.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.startLive() }
            return .success
        }
        _ = c.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pauseLive() }
            return .success
        }
        _ = c.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.toggleLive() }
            return .success
        }
        c.nextTrackCommand.isEnabled = false
        c.previousTrackCommand.isEnabled = false
        c.skipForwardCommand.isEnabled = false
        c.skipBackwardCommand.isEnabled = false
    }

    private func observeInterruptions() {
        _ = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            let optRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch type {
                case .began:
                    self.player?.pause()
                case .ended:
                    if AVAudioSession.InterruptionOptions(rawValue: optRaw).contains(.shouldResume) {
                        self.activateSession()
                        self.player?.play()
                    }
                @unknown default:
                    break
                }
            }
        }
    }

    /// Lock screen: title = summary (else the transcript), artist = "AGENCY · UNIT".
    private func updateNowPlaying(_ t: Transmission) {
        var info: [String: Any] = [:]
        let title = t.summary ?? (t.transcript.isEmpty ? "Scanner" : t.transcript)
        info[MPMediaItemPropertyTitle] = title
        info[MPMediaItemPropertyArtist] = "\(t.agency.label) · \(t.primaryUnit.uppercased())"
        info[MPMediaItemPropertyAlbumTitle] = t.transcript
        if let d = t.duration { info[MPMediaItemPropertyPlaybackDuration] = d }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = 0.0
        info[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = .playing
    }

    private func updatePlaybackState() {
        let center = MPNowPlayingInfoCenter.default()
        if isLive || mode != .idle {
            if center.nowPlayingInfo == nil {
                center.nowPlayingInfo = [MPMediaItemPropertyTitle: "Scanner", MPMediaItemPropertyArtist: "LiveWire"]
            }
            center.playbackState = .playing
        } else {
            center.playbackState = .paused
        }
    }

    // MARK: - Metering

    private func startMetering() {
        meterTask?.cancel()
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { return }
                guard let p = self.player, p.isPlaying else { continue }
                p.updateMeters()
                let db = p.averagePower(forChannel: 0)        // -160 … 0 dBFS
                self.level = max(0, min(1, (db + 50) / 50))
            }
        }
    }

    private func stopMetering() {
        meterTask?.cancel()
        meterTask = nil
        level = 0
    }

    private func showSkipped(_ n: Int) {
        skippedNotice += n
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { self?.skippedNotice = 0 }
        }
    }

    // MARK: - Cache (last 200 clips in Caches/clips)

    private func cachedURL(for t: Transmission) async throws -> URL {
        guard let file = t.audioFile else { throw APIError.badURL }
        let url = cacheDir.appending(path: file)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        guard let api else { throw APIError.badURL }
        let data = try await api.fetchAudio(file)
        try data.write(to: url, options: .atomic)
        pruneCache()
        return url
    }

    private func pruneCache() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: [.contentModificationDateKey]),
              files.count > Self.cacheLimit else { return }
        func date(_ u: URL) -> Date {
            (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        let oldestFirst = files.sorted { date($0) < date($1) }
        for f in oldestFirst.prefix(files.count - Self.cacheLimit) {
            try? fm.removeItem(at: f)
        }
    }
}
