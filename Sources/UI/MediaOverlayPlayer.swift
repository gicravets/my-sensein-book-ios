import AVFoundation
import MediaPlayer

/// Plays an EPUB3 Media Overlay (Wave 5 A4): the human-narrated audio clips for a chapter,
/// publishing the spoken fragment id so the reader can highlight it. Background + lock screen.
@MainActor
final class MediaOverlayPlayer: NSObject, ObservableObject {
    @Published var active = false
    @Published var isPlaying = false
    @Published var currentFragment = ""

    private let player = AVPlayer()
    private var observer: Any?
    private var segments: [(url: URL, clips: [MOClip])] = []  // consecutive clips grouped by audio file
    private var segIndex = 0
    private var clipsBefore = 0
    private var totalClips = 0
    private var title = ""

    var onFragment: ((String) -> Void)?
    var onProgress: ((Double) -> Void)?    // 0…1 within the chapter (for text↔audio position sync)
    var onFinished: (() -> Void)?          // chapter audio ended

    override init() {
        super.init()
        setupRemote()
    }

    func start(clips: [MOClip], resolve: (String) -> URL, title: String) {
        stop()
        guard !clips.isEmpty else { onFinished?(); return }
        self.title = title
        self.totalClips = clips.count
        segments = []
        var cur: [MOClip] = [clips[0]]
        var href = clips[0].audioHref
        for c in clips.dropFirst() {
            if c.audioHref != href {
                segments.append((resolve(href), cur)); cur = []; href = c.audioHref
            }
            cur.append(c)
        }
        if !cur.isEmpty { segments.append((resolve(href), cur)) }
        configureSession()
        active = true
        segIndex = 0
        clipsBefore = 0
        playSegment()
    }

    func toggle() {
        guard active else { return }
        if isPlaying { player.pause(); isPlaying = false }
        else { player.play(); isPlaying = true }
        updateNowPlaying()
    }

    func stop() {
        if let o = observer { player.removeTimeObserver(o); observer = nil }
        player.pause()
        player.replaceCurrentItem(with: nil)
        active = false
        isPlaying = false
        currentFragment = ""
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func playSegment() {
        guard segIndex < segments.count else { onFinished?(); stop(); return }
        let seg = segments[segIndex]
        if let o = observer { player.removeTimeObserver(o); observer = nil }
        player.replaceCurrentItem(with: AVPlayerItem(url: seg.url))
        player.seek(to: CMTime(seconds: seg.clips.first!.begin, preferredTimescale: 600))
        observer = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            let t = time.seconds
            Task { @MainActor in self?.tick(t) }
        }
        player.play()
        isPlaying = true
        updateNowPlaying()
    }

    private func tick(_ t: Double) {
        guard active, segIndex < segments.count else { return }
        let seg = segments[segIndex]
        if t >= seg.clips.last!.end - 0.01 {
            clipsBefore += seg.clips.count
            segIndex += 1
            playSegment()
            return
        }
        guard let c = seg.clips.last(where: { $0.begin <= t }) else { return }
        if c.fragmentID != currentFragment {
            currentFragment = c.fragmentID
            onFragment?(c.fragmentID)
            let i = seg.clips.firstIndex { $0.fragmentID == c.fragmentID } ?? 0
            onProgress?(Double(clipsBefore + i) / Double(max(1, totalClips)))
        }
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
    }

    private func updateNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: "Аудиокнига",
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
    }
}
