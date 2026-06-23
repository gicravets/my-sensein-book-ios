import AVFoundation
import MediaPlayer

/// Plays an EPUB3 Media Overlay (Wave 5 A4): narrated audio clips for a chapter, publishing
/// the spoken fragment id (for highlighting) and supporting seek (slider + prev/next sentence
/// + start-from-a-given-fragment). Background + lock screen.
@MainActor
final class MediaOverlayPlayer: NSObject, ObservableObject {
    @Published var active = false
    @Published var isPlaying = false
    @Published var currentFragment = ""
    @Published var progress: Double = 0   // 0…1 across the chapter's clips (for the slider)

    private let player = AVPlayer()
    private var observer: Any?
    private var clips: [MOClip] = []       // chapter clips, in order
    private var idx = 0                     // current clip index
    private var curHref = ""                // currently loaded audio file
    private var resolve: (String) -> URL = { URL(fileURLWithPath: $0) }
    private var title = ""

    var onFragment: ((String) -> Void)?
    var onProgress: ((Double) -> Void)?    // chapter fraction → shared reading position (text↔audio)
    var onFinished: (() -> Void)?          // chapter audio ended

    override init() {
        super.init()
        setupRemote()
    }

    /// Begin a chapter's narration, optionally from a specific sentence (else the start).
    func start(clips: [MOClip], resolve: @escaping (String) -> URL, title: String, fromFragment: String? = nil) {
        stop()
        guard !clips.isEmpty else { onFinished?(); return }
        self.clips = clips
        self.resolve = resolve
        self.title = title
        configureSession()
        active = true
        let start = fromFragment.flatMap { f in clips.firstIndex { $0.fragmentID == f } } ?? 0
        playFrom(start)
    }

    func toggle() {
        guard active else { return }
        if isPlaying { player.pause(); isPlaying = false } else { player.play(); isPlaying = true }
        updateNowPlaying()
    }

    func next() { if active { playFrom(idx + 1) } }
    func prev() { if active { playFrom(idx - 1) } }

    /// Seek to a chapter fraction (0…1) — the slider.
    func seek(toFraction f: Double) {
        guard active, !clips.isEmpty else { return }
        playFrom(Int((f * Double(clips.count - 1)).rounded()))
    }

    func stop() {
        if let o = observer { player.removeTimeObserver(o); observer = nil }
        player.pause()
        player.replaceCurrentItem(with: nil)
        active = false
        isPlaying = false
        currentFragment = ""
        progress = 0
        curHref = ""
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func playFrom(_ i: Int) {
        guard !clips.isEmpty else { return }
        if i >= clips.count { onFinished?(); stop(); return }
        idx = max(0, i)
        let clip = clips[idx]
        if clip.audioHref != curHref {
            curHref = clip.audioHref
            if let o = observer { player.removeTimeObserver(o); observer = nil }
            player.replaceCurrentItem(with: AVPlayerItem(url: resolve(clip.audioHref)))
            addObserver()
        }
        player.seek(to: CMTime(seconds: clip.begin, preferredTimescale: 600))
        player.play()
        isPlaying = true
        emit()
        updateNowPlaying()
    }

    private func addObserver() {
        observer = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            let t = time.seconds
            Task { @MainActor in self?.tick(t) }
        }
    }

    private func tick(_ t: Double) {
        guard active, idx < clips.count else { return }
        // advance within the same audio file as time passes
        while idx + 1 < clips.count, clips[idx].audioHref == curHref, t >= clips[idx].end - 0.01 {
            idx += 1
            if clips[idx].audioHref != curHref { playFrom(idx); return }  // crossed a track boundary
            emit()
        }
        if idx == clips.count - 1, t >= clips[idx].end - 0.01 {
            onFinished?(); stop(); return
        }
    }

    private func emit() {
        let f = clips[idx].fragmentID
        if f != currentFragment {
            currentFragment = f
            onFragment?(f)
        }
        progress = clips.count > 1 ? Double(idx) / Double(clips.count - 1) : 0
        onProgress?(clips.count > 1 ? Double(idx) / Double(clips.count) : 0)
    }

    private func configureSession() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .spokenAudio)
        try? s.setActive(true)
    }

    private func setupRemote() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.toggle() }; return .success }
        c.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.toggle() }; return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.next() }; return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.prev() }; return .success }
    }

    private func updateNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: "Аудиокнига",
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
    }
}
