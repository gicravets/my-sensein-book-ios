import SwiftUI

/// The reading surface: paged or scrolling WebView with tap zones, swipe-to-flip,
/// a selection → highlight toolbar, circular back/bookmark buttons, bottom progress
/// dots and a Содержание / Настройки / Поиск bar.
struct ReaderView: View {
    @ObservedObject var controller: ReaderController
    @Environment(\.dismiss) private var dismiss

    @State private var menuVisible = false
    @State private var miniVisible = false
    @State private var showSettings = false
    @State private var showContents = false
    @State private var showSearch = false
    @State private var bookmarkPulse = false
    @State private var seekPreview: Double? = nil
    @StateObject private var speech = SpeechReader()
    @StateObject private var mo = MediaOverlayPlayer()

    private var audioActive: Bool { mo.active || speech.active }
    private var audioPlaying: Bool { mo.isPlaying || speech.isSpeaking }

    /// One "read aloud" control: play the human narration (Media Overlays) when the book
    /// has it, otherwise fall back to on-device TTS.
    private func toggleAudio() {
        if controller.hasMediaOverlay {
            if mo.active { mo.toggle() } else { startMediaOverlay() }
        } else {
            toggleSpeech()
        }
    }

    private func stopAudio() {
        speech.stop(); mo.stop()
        mo.onFragment = nil; mo.onProgress = nil; mo.onFinished = nil  // break the callback retain cycle
    }

    private func startMediaOverlay() {
        var ch = controller.chapterIndex
        let resolve: (String) -> URL = { controller.audioURL(forHref: $0) }
        mo.onFragment = { controller.highlightFragment($0) }
        mo.onProgress = { frac in controller.applyAudioPosition(chapter: ch, fraction: frac) }
        mo.onFinished = {
            controller.highlightFragment("")
            ch += 1
            while ch < controller.chapterCount {
                let next = controller.mediaOverlayClips(forChapter: ch)
                if !next.isEmpty {
                    mo.start(clips: next, resolve: resolve, title: controller.bookTitle)
                    return
                }
                ch += 1
            }
        }
        mo.start(clips: controller.mediaOverlayClips(forChapter: ch), resolve: resolve, title: controller.bookTitle)
    }

    /// Start read-aloud from the current chapter, continuing through the book.
    private func toggleSpeech() {
        if speech.active {
            speech.toggle()
        } else {
            var ch = controller.chapterIndex
            speech.nextChapter = {
                ch += 1
                return ch < controller.chapterCount ? (controller.chapterText(ch), ch) : nil
            }
            speech.onProgress = { chapter, frac in
                controller.applyAudioPosition(chapter: chapter, fraction: frac)
            }
            speech.start(text: controller.chapterText(controller.chapterIndex),
                         chapter: controller.chapterIndex, title: controller.bookTitle)
        }
    }

    var body: some View {
        ZStack {
            controller.theme.bgColor.ignoresSafeArea()

            Group {
                if controller.readingMode == .curl {
                    CurlReaderView(controller: controller, onMenu: toggleMenu)
                } else {
                    ReaderWebView(controller: controller, onZone: handleZoneTap, onMenu: toggleMenu)
                }
            }
            .ignoresSafeArea()

            if controller.selectionActive { selectionToolbar }

            // First scrubber: vertical, right edge — shown only with the full menu.
            if menuVisible {
                HStack { Spacer(); sideScrubber }
                    .padding(.trailing, 5).padding(.top, 70).padding(.bottom, 96)
                    .transition(.opacity)
            }

            // Top-right edge handle: an extra way to open the full menu (besides swipe-up).
            // Fixed offset from the physical top so it always clears the Dynamic Island
            // (the top safe area collapses while the status bar is hidden).
            if !menuVisible && !controller.selectionActive {
                VStack {
                    HStack { Spacer(); menuHandle }
                    Spacer()
                }
                .padding(.top, 12)   // top-right corner, beside the Dynamic Island
                .ignoresSafeArea(.container, edges: .top)
                .transition(.opacity)
            }

            VStack {
                if menuVisible { topButtons.transition(.opacity) }
                Spacer()
                bottomArea
            }
            .ignoresSafeArea(.container, edges: .bottom)
        }
        .statusBarHidden(!menuVisible)
        .navigationBarHidden(true)
        .sheet(isPresented: $showSettings) {
            ReaderSettingsView(controller: controller)
                .presentationDetents([.height(430)])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showContents) {
            ContentsSheet(controller: controller) { showContents = false }
        }
        .sheet(isPresented: $showSearch) {
            SearchSheet(controller: controller) { showSearch = false }
        }
        .sheet(isPresented: Binding(
            get: { controller.noteTargetID != nil },
            set: { if !$0 { controller.noteTargetID = nil } })) {
            if let id = controller.noteTargetID {
                NoteEditor { note in controller.setNote(id: id, note: note); controller.noteTargetID = nil }
                    .presentationDetents([.height(260)])
            }
        }
        .onDisappear { if !audioActive { controller.saveProgress() }; stopAudio() }
    }

    private func handleZoneTap(_ fraction: CGFloat) {
        if controller.selectionActive { controller.clearSelection(); return }
        if menuVisible || miniVisible {
            withAnimation(.easeInOut(duration: 0.2)) { menuVisible = false; miniVisible = false }
            return
        }
        // Strict 50/50: left half = back, right half = forward. Menu opens via swipe up.
        if fraction < 0.5 { controller.prevPage() } else { controller.nextPage() }
    }

    private func toggleMini() {
        withAnimation(.easeInOut(duration: 0.2)) { menuVisible = false; miniVisible.toggle() }
    }

    private var accent: Color { Brand.accent }

    // MARK: - Side progress scrubber (drag to seek the whole book)

    private var sideScrubber: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let p = seekPreview ?? overallProgress
            let w: CGFloat = menuVisible ? 4 : 3
            ZStack(alignment: .top) {
                Capsule().fill(controller.theme.fgColor.opacity(menuVisible ? 0.18 : 0.1)).frame(width: w)
                Capsule().fill(accent).frame(width: w, height: max(4, h * p))
                    .frame(maxHeight: .infinity, alignment: .top)
                if menuVisible {
                    Circle().fill(accent)
                        .frame(width: 18, height: 18)
                        .overlay(Circle().stroke(.white.opacity(0.85), lineWidth: 1))
                        .shadow(radius: 2)
                        .offset(y: h * p - 9)
                    Text("\(Int(p * 100))%")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(Brand.surface))
                        .foregroundStyle(.white)
                        .offset(x: -44, y: h * p - 12)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in seekPreview = min(1, max(0, v.location.y / h)) }
                    .onEnded { v in
                        let f = min(1, max(0, v.location.y / h))
                        seekPreview = nil
                        controller.seek(toOverall: f)
                    }
            )
        }
        .frame(width: 30)
    }

    private func toggleMenu() {
        if controller.selectionActive { return }
        withAnimation(.easeInOut(duration: 0.2)) { miniVisible = false; menuVisible.toggle() }
    }

    /// Small tab flush to the top-right edge (eBoox-style) — taps open the full menu.
    /// An addition to swipe-up, not a replacement.
    private var menuHandle: some View {
        Button { toggleMenu() } label: {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(controller.theme.fgColor.opacity(0.55))
                .frame(width: 42, height: 38)
                .background(
                    UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12,
                                           bottomTrailingRadius: 0, topTrailingRadius: 0)
                        .fill(controller.theme.bgColor.opacity(0.85))
                        .shadow(color: .black.opacity(0.08), radius: 6, x: -1, y: 2)
                )
        }
    }

    // MARK: - Bottom area: idle counter / mini-menu / full bar

    @ViewBuilder private var bottomArea: some View {
        if menuVisible {
            bottomBar.transition(.move(edge: .bottom).combined(with: .opacity))
        } else {
            // Idle and mini-menu share ONE bottom counter row in the SAME spot — the
            // counter+dots is itself the menu button and never moves. Opening the mini
            // only (a) fades in the two side buttons (bare, on the page) at that same
            // level and (b) floats the scroll panel separately above.
            VStack(spacing: 14) {
                if speech.active && !speech.currentWord.isEmpty {
                    Text(speech.currentWord)
                        .font(.headline).foregroundStyle(controller.theme.fgColor)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(controller.theme.bgColor.opacity(0.9), in: Capsule())
                        .overlay(Capsule().stroke(controller.theme.fgColor.opacity(0.15), lineWidth: 1))
                        .transition(.opacity)
                }
                if miniVisible {
                    scrollPanel.transition(.move(edge: .bottom).combined(with: .opacity))
                }
                bottomCounterRow
            }
            .padding(.bottom, 4)
        }
    }

    /// Translucent page-coloured scroll panel: % label, seek slider, chapter title.
    /// Appears only with the mini-menu, floating above the counter row.
    private var scrollPanel: some View {
        VStack(spacing: 6) {
            Button { controller.cycleCounterFormat() } label: {
                Text(seekLabel(seekPreview ?? controller.overallProgress))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(controller.theme.fgColor)
            }
            Slider(value: Binding(
                get: { seekPreview ?? controller.overallProgress },
                set: { seekPreview = $0 }),
                in: 0...1) { editing in
                    if !editing, let p = seekPreview { controller.seek(toOverall: p); seekPreview = nil }
                }
                .tint(accent)
            Text(controller.currentChapterTitle)
                .font(.footnote).foregroundStyle(controller.theme.fgColor.opacity(0.5))
                .lineLimit(1)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(controller.theme.bgColor.opacity(0.86))
                .shadow(color: .black.opacity(0.10), radius: 12, y: 2)
        )
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .onTapGesture { }   // tapping the panel never dismisses
    }

    /// Always-on counter + chapter dots, centred at the very bottom. It IS the menu
    /// button (tap → open mini, or cycle format while open). The bookmark/contents
    /// buttons occupy fixed side slots that only become visible+tappable in the mini.
    private var bottomCounterRow: some View {
        HStack(spacing: 0) {
            miniIcon(controller.hasBookmarkHere ? "bookmark.fill" : "bookmark") {
                controller.toggleBookmarkHere()
            }
            .opacity(miniVisible ? 1 : 0)
            .allowsHitTesting(miniVisible)

            Spacer()

            Button { miniVisible ? controller.cycleCounterFormat() : toggleMini() } label: {
                VStack(spacing: 5) {
                    Text(centerCounterText.isEmpty ? " " : centerCounterText)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(controller.theme.fgColor.opacity(miniVisible ? 0.7 : 0.55))
                    chapterDots
                }
                .padding(.horizontal, 28).padding(.vertical, 6)
                .contentShape(Rectangle())
            }

            Spacer()

            miniIcon("list.bullet") { showContents = true }
                .opacity(miniVisible ? 1 : 0)
                .allowsHitTesting(miniVisible)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 6)
        .animation(.easeInOut(duration: 0.2), value: miniVisible)
    }

    /// Counter label for the shared row: "Выкл" while the mini is open, blank when idle.
    private var centerCounterText: String {
        miniVisible ? miniCounterText : (idleCounterText ?? "")
    }

    private func miniIcon(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 20))
                .foregroundStyle(controller.theme.fgColor)
                .frame(width: 44, height: 36)
        }
    }

    private var chapterDots: some View {
        HStack(spacing: 5) {
            ForEach(0..<dotCount, id: \.self) { i in
                Circle()
                    .fill(i == currentDot ? controller.theme.fgColor.opacity(0.8) : controller.theme.fgColor.opacity(0.25))
                    .frame(width: 5, height: 5)
            }
        }
    }

    private var dotCount: Int { min(max(controller.pageCount, 1), 5) }
    private var currentDot: Int {
        guard controller.pageCount > 1 else { return 0 }
        return Int((controller.fraction * Double(dotCount - 1)).rounded())
    }

    private var idleCounterText: String? {
        switch controller.counterFormat {
        case .percent: return "\(Int(controller.overallProgress * 100))%"
        case .pages:   return "\(controller.estCurrentPage) / \(controller.estTotalPages)"
        case .off:     return nil
        }
    }

    /// Mini-menu counter always shows a tappable label (off → "Выкл").
    private var miniCounterText: String { idleCounterText ?? "Выкл" }

    /// Seek label honours the chosen format (off → last numeric format).
    private func seekLabel(_ frac: Double) -> String {
        let fmt = controller.counterFormat == .off ? controller.lastNumberFormat : controller.counterFormat
        switch fmt {
        case .pages:
            let total = controller.estTotalPages
            let page = min(total, max(1, Int((frac * Double(total)).rounded()) + 1))
            return "\(page) / \(total)"
        default:
            return "\(Int(frac * 100))%"
        }
    }

    // MARK: - Selection toolbar

    private var selectionToolbar: some View {
        VStack {
            HStack(spacing: 14) {
                ForEach(HighlightPalette.colors, id: \.self) { hex in
                    Button { controller.addHighlight(colorHex: hex) } label: {
                        Circle().fill(Color(hex: hex))
                            .frame(width: 26, height: 26)
                            .overlay(Circle().stroke(.white.opacity(0.6), lineWidth: 1))
                    }
                }
                Divider().frame(height: 22).overlay(.white.opacity(0.25))
                ShareLink(item: controller.selectionText) {
                    Image(systemName: "square.and.arrow.up").font(.subheadline).foregroundStyle(.white)
                }
                Button { controller.addHighlightWithNote() } label: {
                    Image(systemName: "note.text").font(.subheadline).foregroundStyle(.white)
                }
                Button { controller.clearSelection() } label: {
                    Image(systemName: "xmark").font(.subheadline.bold()).foregroundStyle(.white.opacity(0.7))
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .glassBackground(in: Capsule())
            .shadow(radius: 8)
            .padding(.top, max(60, controller.selectionTopY - 54))
            Spacer()
        }
    }

    // MARK: - Chrome

    private var topButtons: some View {
        HStack {
            circleButton("chevron.left") { controller.saveProgress(); dismiss() }
            Spacer()
            circleButton("bookmark.fill", tint: Brand.accent) {
                controller.addBookmark()
                withAnimation(.spring(response: 0.3)) { bookmarkPulse = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { bookmarkPulse = false }
            }
            .scaleEffect(bookmarkPulse ? 1.25 : 1)
        }
        .padding(.horizontal, 16).padding(.top, 8)
    }

    private func circleButton(_ icon: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint ?? controller.theme.fgColor)
                .frame(width: 42, height: 42)
                .glassBackground(in: Circle())
        }
    }

    private var bottomBar: some View {
        HStack {
            barButton("list.bullet", "Содержание") { showContents = true }
            barButton("slider.horizontal.3", "Настройки") { showSettings = true }
            barButton("magnifyingglass", "Поиск") { showSearch = true }
            barButton(audioPlaying ? "pause.fill" : "headphones",
                      audioActive ? (audioPlaying ? "Пауза" : "Дальше")
                                  : (controller.hasMediaOverlay ? "Слушать" : "Вслух")) { toggleAudio() }
            if audioActive {
                barButton("stop.fill", "Стоп") { stopAudio() }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .glassBackground(in: Capsule())
        .overlay(Capsule().stroke(.primary.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
    }

    private func barButton(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 18))
                Text(label).font(.caption2)
            }
            .foregroundStyle(controller.theme.fgColor)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Progress math

    private var overallProgress: Double { controller.overallProgress }
}

// MARK: - Note editor

struct NoteEditor: View {
    let onDone: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .focused($focused)
                .padding(10)
                .navigationTitle("Заметка")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Отменить") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Готово") { onDone(text); dismiss() }.bold()
                    }
                }
                .onAppear { focused = true }
        }
    }
}

// MARK: - Settings sheet

struct ReaderSettingsView: View {
    @ObservedObject var controller: ReaderController
    @State private var brightness = Double(UIScreen.main.brightness)

    var body: some View {
        VStack(spacing: 20) {
            Text("НАСТРОЙКИ").font(.subheadline.weight(.bold))
                .foregroundStyle(Brand.accent)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 14) {
                ForEach(ReaderTheme.allCases) { theme in
                    Button { controller.theme = theme } label: {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.bgColor)
                            .frame(height: 46)
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .stroke(controller.theme == theme ? Brand.accent : .gray.opacity(0.4),
                                        lineWidth: controller.theme == theme ? 3 : 1))
                            .overlay {
                                if controller.theme == theme {
                                    Image(systemName: "checkmark").foregroundStyle(theme.fgColor).font(.subheadline.bold())
                                }
                            }
                    }
                }
            }

            slider("Размер", "textformat.size",
                   value: Binding(get: { Double(controller.fontScale) },
                                  set: { controller.fontScale = Int($0); controller.applySettings() }),
                   range: 70...220, step: 10)
            slider("Поля", "rectangle.portrait.and.arrow.right",
                   value: Binding(get: { Double(controller.margins) },
                                  set: { controller.margins = Int($0); controller.applySettings() }),
                   range: 8...56, step: 4)
            slider("Строки", "line.3.horizontal",
                   value: Binding(get: { controller.lineSpacing },
                                  set: { controller.lineSpacing = $0; controller.applySettings() }),
                   range: 1.1...2.2, step: 0.05)
            slider("Яркость", "sun.max",
                   value: Binding(get: { brightness },
                                  set: { brightness = $0; UIScreen.main.brightness = CGFloat($0) }),
                   range: 0...1, step: 0.02)

            HStack(spacing: 12) {
                Image(systemName: "book.pages").frame(width: 24).foregroundStyle(.secondary)
                Text("Листание").frame(width: 80, alignment: .leading).font(.subheadline)
                Picker("", selection: $controller.readingMode) {
                    ForEach(ReadingMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
    }

    private func slider(_ label: String, _ icon: String,
                        value: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).frame(width: 24).foregroundStyle(.secondary)
            Text(label).frame(width: 64, alignment: .leading).font(.subheadline)
            Slider(value: value, in: range, step: step).tint(Brand.purple)
        }
    }
}
