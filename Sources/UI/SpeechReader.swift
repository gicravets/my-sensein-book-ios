import AVFoundation
import MediaPlayer

/// Read-aloud engine (Wave 5 A1/A2): speaks chapter text with AVSpeechSynthesizer,
/// keeps playing in the background, and shows transport controls on the Lock Screen
/// (Now Playing). Publishes the currently spoken word for a caption.
@MainActor
final class SpeechReader: NSObject, ObservableObject {
    @Published var active = false       // a session is running (playing or paused)
    @Published var isSpeaking = false   // currently playing (vs paused)
    @Published var currentWord = ""

    private let synth = AVSpeechSynthesizer()
    private var title = ""
    private(set) var currentChapter = 0
    /// Provides the next chapter (text + index) when the current finishes; nil ends the session.
    var nextChapter: (() -> (text: String, chapter: Int)?)?
    /// Reports the read-aloud position (chapter, fraction 0…1) so it shares one reading position.
    var onProgress: ((Int, Double) -> Void)?

    override init() {
        super.init()
        synth.delegate = self
        setupRemoteCommands()
    }

    func start(text: String, chapter: Int, title: String) {
        self.title = title
        self.currentChapter = chapter
        configureSession()
        synth.stopSpeaking(at: .immediate)
        active = true
        speak(text)
    }

    func toggle() {
        if synth.isPaused {
            synth.continueSpeaking()
            isSpeaking = true
        } else if synth.isSpeaking {
            synth.pauseSpeaking(at: .word)
            isSpeaking = false
        }
        updateNowPlaying()
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
        active = false
        isSpeaking = false
        currentWord = ""
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            if let n = nextChapter?() { currentChapter = n.chapter; speak(n.text) } else { stop() }
            return
        }
        let u = AVSpeechUtterance(string: trimmed)
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        synth.speak(u)
        isSpeaking = true
        updateNowPlaying()
    }

    // MARK: audio session + lock screen
    private func configureSession() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .spokenAudio)
        try? s.setActive(true)
    }

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.toggle() }; return .success }
        c.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.toggle() }; return .success }
    }

    private func updateNowPlaying() {
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = title
        info[MPMediaItemPropertyArtist] = "Чтение вслух"
        info[MPNowPlayingInfoPropertyPlaybackRate] = isSpeaking ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

extension SpeechReader: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       willSpeakRangeOfSpeechString characterRange: NSRange,
                                       utterance: AVSpeechUtterance) {
        let str = utterance.speechString as NSString
        let word = str.substring(with: characterRange)
        let frac = str.length > 0 ? Double(characterRange.location + characterRange.length) / Double(str.length) : 0
        Task { @MainActor in
            self.currentWord = word
            self.onProgress?(self.currentChapter, frac)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            if let n = self.nextChapter?(), !n.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.currentChapter = n.chapter
                self.speak(n.text)
            } else {
                self.stop()
            }
        }
    }
}
