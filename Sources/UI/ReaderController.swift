import SwiftUI
import WebKit

enum HighlightPalette {
    static let colors = ["#FFE066", "#A6E3A1", "#F5B5C8"]   // yellow, green, pink
}

/// Drives the reader WKWebView: loads chapters, applies typography/theme, paginates
/// (paged columns) or scrolls (scroll mode), and exposes search / bookmark / highlight
/// navigation. Locators are reflow-safe: position = chapter + fraction; search and
/// highlights = chapter + text + occurrence index.
@MainActor
final class ReaderController: NSObject, ObservableObject {
    let epub: ParsedEpub
    let bookID: UUID
    private let store: LibraryStore
    private lazy var index = SearchIndex(epub: epub)

    // Read-aloud (TTS) helpers: plain text per chapter + chapter count.
    var chapterCount: Int { epub.spine.count }
    func chapterText(_ i: Int) -> String { index.text(for: i) }
    var bookTitle: String { store.book(id: bookID)?.title ?? "Книга" }

    // EPUB3 Media Overlays (human-narrated audio synced to text).
    var hasMediaOverlay: Bool { epub.hasMediaOverlay(spine: chapterIndex) }
    func mediaOverlayClips(forChapter i: Int) -> [MOClip] { epub.mediaOverlayClips(forSpine: i) }
    func audioURL(forHref href: String) -> URL { epub.fileURL(forHref: href) }
    func highlightFragment(_ id: String) {
        webView?.evaluateJavaScript("window.__moHighlight&&window.__moHighlight(\(jsString(id)))")
    }

    @Published var chapterIndex: Int
    @Published var page: Int = 0
    @Published var pageCount: Int = 1
    @Published var fraction: Double = 0          // within current chapter
    @Published var fontScale: Int {
        didSet { UserDefaults.standard.set(fontScale, forKey: PreferencesSync.kFont); PreferencesSync.stamp() }
    }
    @Published var margins: Int = 24
    @Published var lineSpacing: Double = 1.5
    @Published var readingMode: ReadingMode = .slide {
        didSet {
            UserDefaults.standard.set(readingMode.rawValue, forKey: "readingMode")
            PreferencesSync.stamp()
            // slide<->scroll reuse the same web view; to/from curl the SwiftUI surface swaps.
            if oldValue != .curl, readingMode != .curl { reloadPreservingPosition() }
        }
    }
    var scrollMode: Bool { readingMode == .scroll }
    @Published var theme: ReaderTheme {
        didSet {
            UserDefaults.standard.set(theme.rawValue, forKey: PreferencesSync.kTheme)
            PreferencesSync.stamp()
            applySettings()
        }
    }

    // Text-selection state for the highlight toolbar.
    @Published var selectionActive = false
    @Published var selectionTopY: CGFloat = 0
    @Published var selectionText = ""
    @Published var noteTargetID: UUID?      // set when a fresh highlight wants a note

    // Bottom counter (percent / pages / off) + estimated page numbers.
    @Published var counterFormat: CounterFormat = .percent {
        didSet {
            UserDefaults.standard.set(counterFormat.rawValue, forKey: "counterFormat")
            if counterFormat != .off { lastNumberFormat = counterFormat }
        }
    }
    private(set) var lastNumberFormat: CounterFormat = .percent
    @Published var estCurrentPage = 1
    @Published var estTotalPages = 1

    /// Byte size of each spine file — a cheap length proxy for page estimation.
    private lazy var spineBytes: [Int] = epub.spine.map {
        let url = epub.fileURL(forHref: $0.href)
        return max(1, (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 1)
    }
    private lazy var prefixBytes: [Int] = {
        var p = [Int](); var s = 0
        for b in spineBytes { p.append(s); s += b }
        return p
    }()
    private lazy var totalBytes: Int = max(1, spineBytes.reduce(0, +))

    func cycleCounterFormat() { counterFormat = counterFormat.next() }

    /// Title of the section the current chapter belongs to (for the mini-menu).
    var currentChapterTitle: String {
        let curFile = epub.spine.indices.contains(chapterIndex)
            ? (epub.spine[chapterIndex].href.components(separatedBy: "#").first ?? "")
            : ""
        // Last TOC entry whose target spine index is <= the current chapter.
        var best: String?
        for entry in epub.toc {
            let target = entry.href.components(separatedBy: "#").first ?? entry.href
            if let idx = epub.spine.firstIndex(where: { $0.href.hasSuffix(target) || target.hasSuffix($0.href) }),
               idx <= chapterIndex {
                best = entry.title
            }
        }
        if let best, !best.isEmpty { return best }
        if !curFile.isEmpty, let e = epub.toc.first(where: { $0.href.hasSuffix(curFile) }) { return e.title }
        return "Глава \(chapterIndex + 1)"
    }

    /// Byte-weighted reading progress (0…1) — consistent with the page estimate.
    var overallProgress: Double {
        guard spineBytes.indices.contains(chapterIndex) else { return 0 }
        let before = Double(prefixBytes[chapterIndex]) + fraction * Double(spineBytes[chapterIndex])
        return min(1, before / Double(totalBytes))
    }

    /// Read-aloud writes its position into the shared reading progress (text↔audio sync).
    func applyAudioPosition(chapter: Int, fraction: Double) {
        store.updateProgress(bookID: bookID, chapter: chapter, fraction: fraction,
                             progress: overallFor(chapter: chapter, fraction: fraction))
    }

    /// Byte-weighted overall progress for an arbitrary chapter+fraction (used by read-aloud).
    func overallFor(chapter: Int, fraction: Double) -> Double {
        guard spineBytes.indices.contains(chapter) else { return fraction }
        let before = Double(prefixBytes[chapter]) + fraction * Double(spineBytes[chapter])
        return min(1, before / Double(totalBytes))
    }

    private var lastTypoSig = ""

    /// Estimated page numbers. Total is computed once per typography setting (stable
    /// across chapters) from the current chapter's measured pages-per-byte.
    private func updatePageEstimate() {
        guard spineBytes.indices.contains(chapterIndex), pageCount > 0 else { return }
        let sig = "\(fontScale)/\(margins)/\(lineSpacing)"
        if sig != lastTypoSig || estTotalPages <= 1 {
            let ppb = Double(pageCount) / Double(spineBytes[chapterIndex])
            estTotalPages = max(1, Int((Double(totalBytes) * ppb).rounded()))
            lastTypoSig = sig
        }
        estCurrentPage = min(estTotalPages, max(1, Int((overallProgress * Double(estTotalPages)).rounded()) + 1))
    }

    weak var webView: WKWebView?

    private enum Landing { case fraction(Double), match(String, Int) }
    private var pendingLanding: Landing
    private var lastQuery = ""

    init(epub: ParsedEpub, book: Book, store: LibraryStore) {
        self.epub = epub
        self.bookID = book.id
        self.store = store
        if book.lastReadAt == nil {
            self.chapterIndex = epub.startIndex
            self.pendingLanding = .fraction(0)
        } else {
            self.chapterIndex = min(max(0, book.chapterIndex), max(0, epub.spine.count - 1))
            self.pendingLanding = .fraction(book.chapterFraction)
        }
        // load synced reader prefs (persisted + cross-device); fall back to defaults
        self.fontScale = UserDefaults.standard.object(forKey: PreferencesSync.kFont) as? Int ?? 100
        if let raw = UserDefaults.standard.string(forKey: PreferencesSync.kTheme),
           let t = ReaderTheme(rawValue: raw) {
            self.theme = t
        } else {
            self.theme = .light
        }
        if let raw = UserDefaults.standard.string(forKey: "readingMode"),
           let m = ReadingMode(rawValue: raw) {
            self.readingMode = m
        }
        if let raw = UserDefaults.standard.string(forKey: "counterFormat"),
           let f = CounterFormat(rawValue: raw) {
            self.counterFormat = f
            self.lastNumberFormat = f == .off ? .percent : f
        }
        super.init()
    }

    private var currentHighlights: [Highlight] {
        store.book(id: bookID)?.highlights.filter { $0.chapterIndex == chapterIndex } ?? []
    }

    var bookmarks: [Bookmark] {
        (store.book(id: bookID)?.bookmarks ?? []).sorted { $0.createdAt > $1.createdAt }
    }
    var allHighlights: [Highlight] {
        (store.book(id: bookID)?.highlights ?? []).sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - Loading

    func loadCurrentChapter() { load(chapterIndex, landing: pendingLanding) }

    private func load(_ index: Int, landing: Landing) {
        guard let wv = webView, epub.spine.indices.contains(index) else { return }
        pendingLanding = landing
        let url = epub.fileURL(forHref: epub.spine[index].href)
        wv.loadFileURL(url, allowingReadAccessTo: epub.rootDir)
    }

    private func reloadPreservingPosition() {
        webView?.scrollView.isScrollEnabled = scrollMode
        load(chapterIndex, landing: .fraction(fraction))
    }

    // MARK: - Navigation

    func nextPage() {
        webView?.evaluateJavaScript("window.__next ? window.__next() : null") { [weak self] res, _ in
            guard let self else { return }
            if (res as? Bool) == false, self.chapterIndex < self.epub.spine.count - 1 {
                self.chapterIndex += 1
                self.load(self.chapterIndex, landing: .fraction(0))
            }
        }
    }

    func prevPage() {
        webView?.evaluateJavaScript("window.__prev ? window.__prev() : null") { [weak self] res, _ in
            guard let self else { return }
            if (res as? Bool) == false, self.chapterIndex > 0 {
                self.chapterIndex -= 1
                self.load(self.chapterIndex, landing: .fraction(1))
            }
        }
    }

    /// Seek to a byte-weighted book fraction (0…1) — used by the scrubbers.
    func seek(toOverall f: Double) {
        let target = max(0, min(1, f)) * Double(totalBytes)
        var ch = 0
        for c in epub.spine.indices {
            if Double(prefixBytes[c]) <= target { ch = c } else { break }
        }
        let chBytes = Double(spineBytes[ch])
        let frac = chBytes > 0 ? (target - Double(prefixBytes[ch])) / chBytes : 0
        chapterIndex = ch
        load(ch, landing: .fraction(min(1, max(0, frac))))
    }

    func jump(toHref href: String) {
        let target = href.components(separatedBy: "#").first ?? href
        if let idx = epub.spine.firstIndex(where: { $0.href.hasSuffix(target) || target.hasSuffix($0.href) }) {
            chapterIndex = idx
            load(idx, landing: .fraction(0))
        }
    }

    // MARK: - Settings

    /// Set by the page-curl surface; re-renders snapshots after a settings change.
    var requestResnapshot: (() -> Void)?
    private var resnapWork: DispatchWorkItem?

    func applySettings() {
        webView?.evaluateJavaScript(setupJS(target: "window.__curFrac?window.__curFrac():0"))
        // Curl mode shows static snapshots, so re-snapshot after the new layout settles
        // (debounced so dragging a slider doesn't re-capture on every tick).
        guard readingMode == .curl else { return }
        resnapWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.requestResnapshot?() }
        resnapWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    func saveProgress() { persist(fraction: fraction) }

    /// Called by the page-curl surface as it flips pages.
    func reportCurlPosition(fraction f: Double) {
        fraction = f
        persist(fraction: f)
        updatePageEstimate()
    }

    private func persist(fraction f: Double) {
        let denom = Double(max(1, epub.spine.count))
        let overall = (Double(chapterIndex) + f) / denom
        store.updateProgress(bookID: bookID, chapter: chapterIndex, fraction: f, progress: min(1, overall))
    }

    // MARK: - Search

    func search(_ query: String) -> [SearchResult] {
        lastQuery = query
        return index.search(query)
    }

    func open(_ result: SearchResult) {
        lastQuery = lastQuery.isEmpty ? "" : lastQuery
        chapterIndex = result.chapterIndex
        load(result.chapterIndex, landing: .match(jsString(lastQuery), result.occurrence))
    }

    // MARK: - Bookmarks

    func addBookmark() {
        let frac = fraction
        let bm = Bookmark(chapterIndex: chapterIndex, fraction: frac,
                          label: bookmarkLabel(chapter: chapterIndex, fraction: frac))
        store.addBookmark(bookID: bookID, bm)
        objectWillChange.send()
    }

    /// Snippet shown in the bookmarks list — taken from the chapter text near `fraction`.
    private func bookmarkLabel(chapter: Int, fraction: Double) -> String {
        let chars = Array(index.text(for: chapter))
        guard !chars.isEmpty else { return "Закладка" }
        var i = max(0, min(chars.count - 1, Int(Double(chars.count) * fraction)))
        while i < chars.count, chars[i].isWhitespace { i += 1 }
        let raw = String(chars[i..<min(chars.count, i + 90)])
        let snippet = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return snippet.isEmpty ? "Закладка" : String(snippet.prefix(70))
    }

    func go(to bookmark: Bookmark) {
        chapterIndex = bookmark.chapterIndex
        load(bookmark.chapterIndex, landing: .fraction(bookmark.fraction))
    }

    func removeBookmark(_ bm: Bookmark) {
        store.removeBookmark(bookID: bookID, id: bm.id)
        objectWillChange.send()
    }

    /// Bookmark near the current position (same chapter, close fraction).
    private var bookmarkHere: Bookmark? {
        bookmarks.first { $0.chapterIndex == chapterIndex && abs($0.fraction - fraction) < 0.03 }
    }
    var hasBookmarkHere: Bool { bookmarkHere != nil }
    func toggleBookmarkHere() {
        if let bm = bookmarkHere { removeBookmark(bm) } else { addBookmark() }
    }

    func go(to highlight: Highlight) {
        chapterIndex = highlight.chapterIndex
        load(highlight.chapterIndex, landing: .match(jsString(highlight.text), highlight.occurrence))
    }

    // MARK: - Highlights

    func addHighlight(colorHex: String) {
        let id = UUID()
        let js = "window.__addHighlight?window.__addHighlight(\(jsString(colorHex)),\(jsString(id.uuidString))):null"
        webView?.evaluateJavaScript(js) { [weak self] res, _ in
            guard let self,
                  let dict = self.decode(res),
                  let text = dict["text"] as? String, !text.isEmpty else { return }
            let occ = dict["occ"] as? Int ?? 0
            let hl = Highlight(id: id, chapterIndex: self.chapterIndex,
                               text: text, occurrence: occ, colorHex: colorHex)
            self.store.addHighlight(bookID: self.bookID, hl)
            self.selectionActive = false
            self.objectWillChange.send()
        }
    }

    func removeHighlight(_ hl: Highlight) {
        store.removeHighlight(bookID: bookID, id: hl.id)
        webView?.evaluateJavaScript("window.__removeHighlight&&window.__removeHighlight(\(jsString(hl.id.uuidString)))")
        objectWillChange.send()
    }

    /// Highlight the current selection (default color) and open a note editor for it.
    func addHighlightWithNote() {
        let id = UUID()
        let color = HighlightPalette.colors[0]
        let js = "window.__addHighlight?window.__addHighlight(\(jsString(color)),\(jsString(id.uuidString))):null"
        webView?.evaluateJavaScript(js) { [weak self] res, _ in
            guard let self, let dict = self.decode(res),
                  let text = dict["text"] as? String, !text.isEmpty else { return }
            let occ = dict["occ"] as? Int ?? 0
            self.store.addHighlight(bookID: self.bookID,
                Highlight(id: id, chapterIndex: self.chapterIndex, text: text, occurrence: occ, colorHex: color))
            self.selectionActive = false
            self.noteTargetID = id           // triggers the note editor in the view
            self.objectWillChange.send()
        }
    }

    func setNote(id: UUID, note: String) {
        store.setHighlightNote(bookID: bookID, id: id, note: note)
        objectWillChange.send()
    }

    func clearSelection() {
        selectionActive = false
        webView?.evaluateJavaScript("window.getSelection&&window.getSelection().removeAllRanges()")
    }

    private func decode(_ res: Any?) -> [String: Any]? {
        if let d = res as? [String: Any] { return d }
        if let s = res as? String, let data = s.data(using: .utf8) {
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        return nil
    }

    private func jsString(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return "'\(escaped)'"
    }

    // MARK: - Injected JavaScript

    private func setupJS(target: String) -> String {
        let t = theme
        let mode = scrollMode ? "scroll" : "paged"
        let hls = currentHighlights.map { "{text:\(jsString($0.text)),occ:\($0.occurrence),color:\(jsString($0.colorHex)),id:\(jsString($0.id.uuidString))}" }
        let hlsJSON = "[\(hls.joined(separator: ","))]"
        return """
        (function(){
          var d=document, pad=\(margins), XH='http://www.w3.org/1999/xhtml', MODE='\(mode)';
          var SEARCH='#FFD54A';
          var vp=d.querySelector('meta[name=viewport]');
          if(!vp){ try{ vp=d.createElementNS(XH,'meta'); vp.setAttribute('name','viewport'); (d.head||d.documentElement).appendChild(vp);}catch(e){} }
          if(vp){ vp.setAttribute('content','width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no'); }

          var col=window.__colEl;
          if(!col || !col.parentNode){
            col=d.createElementNS(XH,'div'); col.setAttribute('id','__col');
            var b=d.body; while(b.firstChild){ col.appendChild(b.firstChild); }
            b.appendChild(col); window.__colEl=col;
          }
          var st=window.__styleEl;
          if(!st || !st.parentNode){ st=d.createElementNS(XH,'style'); window.__styleEl=st; (d.head||d.documentElement).appendChild(st); }

          function nz(s){ return s.toLowerCase().replace(/ё/g,'е'); }
          function nodeMap(){
            var w=d.createTreeWalker(col, NodeFilter.SHOW_TEXT, null), arr=[], off=0, n;
            while(n=w.nextNode()){ arr.push({node:n,start:off,len:n.nodeValue.length}); off+=n.nodeValue.length; }
            return arr;
          }
          function fullText(){ var m=nodeMap(), s=''; for(var k=0;k<m.length;k++) s+=m[k].node.nodeValue; return s; }
          function wrapRange(gs, ge, color, id){
            var m=nodeMap();
            for(var k=0;k<m.length;k++){
              var ns=m[k].start, ne=ns+m[k].len, s=Math.max(gs,ns), e=Math.min(ge,ne);
              if(s>=e) continue;
              var node=m[k].node, ls=s-ns, le=e-ns, seg=node;
              if(ls>0){ seg=node.splitText(ls); le-=ls; }
              if(le<seg.nodeValue.length){ seg.splitText(le); }
              var mk=d.createElementNS(XH,'mark'); mk.setAttribute('data-hl', id);
              mk.setAttribute('style','background:'+color+' !important;color:inherit !important;border-radius:2px;-webkit-text-fill-color:inherit;');
              seg.parentNode.insertBefore(mk, seg); mk.appendChild(seg);
            }
          }
          function findOcc(text, occ){
            var full=nz(fullText()), nd=nz(text), from=0, c=0;
            while(true){ var p=full.indexOf(nd, from); if(p<0) return null; if(c===occ) return [p, p+text.length]; c++; from=p+nd.length; }
          }
          window.__applyHighlights=function(list){
            for(var i=0;i<list.length;i++){ var r=findOcc(list[i].text, list[i].occ); if(r) wrapRange(r[0], r[1], list[i].color, list[i].id); }
          };
          window.__removeHighlight=function(id){
            var ms=col.querySelectorAll('[data-hl="'+id+'"]');
            for(var i=0;i<ms.length;i++){ var m=ms[i]; while(m.firstChild) m.parentNode.insertBefore(m.firstChild, m); m.parentNode.removeChild(m); }
          };
          // Media Overlays: highlight the spoken sentence (<span id>) and scroll it into view.
          window.__moHighlight=function(id){
            if(window.__moEl){ window.__moEl.style.backgroundColor=''; window.__moEl.style.borderRadius=''; }
            var el=id?d.getElementById(id):null;
            if(el){ el.style.backgroundColor='rgba(177,78,224,0.28)'; el.style.borderRadius='3px';
                    try{ el.scrollIntoView({block:'center'}); }catch(e){ el.scrollIntoView(); } }
            window.__moEl=el;
          };
          window.__addHighlight=function(color, id){
            var sel=window.getSelection(); if(!sel.rangeCount || sel.isCollapsed) return null;
            var r=sel.getRangeAt(0), text=r.toString(); if(!text.trim()) return null;
            var m=nodeMap(), gstart=0, found=false;
            for(var k=0;k<m.length;k++){ if(m[k].node===r.startContainer){ gstart=m[k].start+r.startOffset; found=true; break; } }
            var full=nz(fullText()), nd=nz(text), occ=0, from=0;
            if(found){ while(true){ var p=full.indexOf(nd, from); if(p<0||p>=gstart) break; occ++; from=p+nd.length; } }
            wrapRange(gstart, gstart+text.length, color, id); sel.removeAllRanges();
            return JSON.stringify({text:text, occ:occ});
          };

          function layout(){
            var W=window.innerWidth, H=window.innerHeight; window.__W=W; window.__H=H;
            var padTop=8, padBot=22;   // top: safe-area inset clears the island; bottom: reserve the counter zone
            st.textContent=
              'html{-webkit-text-size-adjust:\(fontScale)% !important;}'+
              'html,body{margin:0 !important;padding:0 !important;background:\(t.bgHex) !important;}'+
              'body{color:\(t.fgHex) !important;font-family:-apple-system,Georgia,serif !important;}'+
              '[id=__col],[id=__col] p,[id=__col] div,[id=__col] li{line-height:\(String(format: "%.2f", lineSpacing)) !important;text-align:justify !important;-webkit-hyphens:auto !important;hyphens:auto !important;orphans:1 !important;widows:1 !important;}'+
              // Let paragraphs break freely so columns fill to the bottom (no big gaps).
              '[id=__col] p{margin-top:0 !important;break-inside:auto !important;-webkit-column-break-inside:auto !important;}'+
              'a{color:\(t.linkHex) !important;}'+
              'mark{color:inherit !important;}'+
              'img,svg,video{max-width:100% !important;height:auto !important;}'+
              '[id=__col] *{max-width:100% !important;box-sizing:border-box;}'+
              '[id=__col] table,[id=__col] pre{width:auto !important;white-space:normal !important;}';
            var s=col.style;
            if(MODE==='scroll'){
              d.documentElement.style.height='auto'; d.body.style.height='auto'; d.body.style.overflow='visible';
              s.display='block'; s.boxSizing='border-box'; s.height='auto';
              s.padding=padTop+'px '+pad+'px '+(H*0.5)+'px';
              s.columnWidth='auto'; s.webkitColumnWidth='auto'; s.columnGap='normal';
              s.overflow='visible'; s.transform='none'; s.transition='none'; s.color='\(t.fgHex)';
            } else {
              d.documentElement.style.height='100%'; d.body.style.height='100%'; d.body.style.overflow='hidden';
              s.display='block'; s.boxSizing='border-box'; s.height=(H-padTop-padBot)+'px';
              s.padding=padTop+'px '+pad+'px '+padBot+'px';
              s.columnWidth=(W-pad*2)+'px'; s.webkitColumnWidth=(W-pad*2)+'px';
              s.columnGap=(pad*2)+'px'; s.webkitColumnGap=(pad*2)+'px';
              s.columnFill='auto'; s.webkitColumnFill='auto';
              s.overflow='visible'; s.color='\(t.fgHex)'; s.transition='transform .22s ease';
            }
          }
          function pages(){ var W=window.__W||window.innerWidth; return Math.max(1, Math.round(col.scrollWidth / W)); }
          function maxScroll(){ return Math.max(0, d.body.scrollHeight - (window.__H||window.innerHeight)); }
          window.__curFrac=function(){
            if(MODE==='scroll'){ var ms=maxScroll(); return ms>0?(window.pageYOffset/ms):0; }
            var n=pages(); return n>1?(window.__page/(n-1)):0;
          };
          window.__page=window.__page||0;
          window.__goto=function(p){ var W=window.__W||window.innerWidth, n=pages(); p=Math.max(0,Math.min(n-1,p));
            window.__page=p; col.style.transform='translateX('+(-p*W)+'px)'; notify(); };
          window.__gotoFraction=function(f){
            if(MODE==='scroll'){ window.scrollTo(0, f*maxScroll()); notify(); }
            else { window.__goto(Math.round(f*(pages()-1))); }
          };
          window.__next=function(){
            if(MODE==='scroll'){ var H=window.__H||innerHeight; if(window.pageYOffset>=maxScroll()-2) return false; window.scrollBy(0, H*0.92); notify(); return true; }
            if(window.__page<pages()-1){ window.__goto(window.__page+1); return true; } return false;
          };
          window.__prev=function(){
            if(MODE==='scroll'){ var H=window.__H||innerHeight; if(window.pageYOffset<=2) return false; window.scrollBy(0, -H*0.92); notify(); return true; }
            if(window.__page>0){ window.__goto(window.__page-1); return true; } return false;
          };
          window.__gotoMatch=function(query, occ){
            window.__removeHighlight('__search');
            var r=findOcc(query, occ); if(!r) return false;
            wrapRange(r[0], r[1], SEARCH, '__search');
            var mk=col.querySelector('[data-hl="__search"]'); if(!mk) return false;
            if(MODE==='scroll'){ var y=mk.getBoundingClientRect().top+window.pageYOffset; window.scrollTo(0, Math.max(0,y-(window.__H||innerHeight)*0.3)); }
            else { var save=col.style.transform; col.style.transition='none'; col.style.transform='none';
              var left=mk.getBoundingClientRect().left-col.getBoundingClientRect().left;
              var p=Math.floor(left/(window.__W||innerWidth)); col.style.transition='transform .22s ease'; window.__goto(p); }
            notify(); return true;
          };

          function notify(){ try{ webkit.messageHandlers.reader.postMessage({type:'state',page:window.__page,pages:pages(),frac:window.__curFrac(),mode:MODE}); }catch(e){} }
          window.__notify=notify;
          // Helpers for the native page-curl surface: page count + silent instant jump (for snapshots).
          window.__pageCount=function(){ return pages(); };
          window.__snapTo=function(i){ var W=window.__W||innerWidth, n=pages(); i=Math.max(0,Math.min(n-1,i));
            col.style.transition='none'; col.style.transform='translateX('+(-i*W)+'px)'; };

          // Selection → highlight toolbar
          function reportSelection(){
            var sel=window.getSelection();
            if(!sel.rangeCount||sel.isCollapsed||!sel.toString().trim()){
              try{ webkit.messageHandlers.reader.postMessage({type:'sel',active:false,top:0,text:''}); }catch(e){} return;
            }
            var rc=sel.getRangeAt(0).getBoundingClientRect();
            try{ webkit.messageHandlers.reader.postMessage({type:'sel',active:true,top:rc.top,text:sel.toString().slice(0,800)}); }catch(e){}
          }
          d.addEventListener('selectionchange', function(){ clearTimeout(window.__selT); window.__selT=setTimeout(reportSelection,150); });

          if(MODE==='scroll'){ window.addEventListener('scroll', function(){ clearTimeout(window.__scT); window.__scT=setTimeout(notify,80); }); }

          // Finger-following page slide (paged mode). The page tracks the finger; on
          // release it completes the flip past ~38% / a fast flick, else snaps back.
          // Same technique works in a browser, so it ports to the future web reader.
          if(MODE!=='scroll' && !window.__dragInit){
            window.__dragInit=true;
            var dg={x:0,y:0,base:0,last:0,t:0,drag:false,active:false};
            function pOff(p){ return -p*(window.__W||innerWidth); }
            d.addEventListener('touchstart',function(e){
              if(e.touches.length!==1){ dg.active=false; return; }
              var t=e.touches[0]; dg.active=true; dg.drag=false;
              dg.x=t.clientX; dg.y=t.clientY; dg.last=t.clientX; dg.t=Date.now(); dg.base=pOff(window.__page);
            },{passive:false});
            d.addEventListener('touchmove',function(e){
              if(!dg.active) return; var t=e.touches[0], dx=t.clientX-dg.x, dy=t.clientY-dg.y; dg.last=t.clientX;
              if(!dg.drag){
                if(Math.abs(dy)>16 && Math.abs(dy)>=Math.abs(dx)){ dg.active=false; return; }   // vertical → menu/scroll
                if(Math.abs(dx)>12 && Math.abs(dx)>Math.abs(dy)*1.2 && window.getSelection().isCollapsed){
                  dg.drag=true; col.style.transition='none';
                }
              }
              if(dg.drag){
                e.preventDefault();
                var off=dg.base+dx, maxOff=0, minOff=pOff(pages()-1);
                if(off>maxOff) off=maxOff+(off-maxOff)*0.35;       // rubber-band at first page
                if(off<minOff) off=minOff+(off-minOff)*0.35;       // rubber-band at last page
                col.style.transform='translateX('+off+'px)';
              }
            },{passive:false});
            function endDrag(){
              if(!dg.drag){ dg.active=false; return; }
              dg.drag=false; dg.active=false;
              col.style.transition='transform .26s cubic-bezier(.2,.7,.2,1)';
              var dx=dg.last-dg.x, W=window.__W||innerWidth, th=W*0.38, dt=Date.now()-dg.t;
              var fast=Math.abs(dx)>40 && dt<260;
              if(dx<=-th || (fast&&dx<0)){
                if(window.__page<pages()-1){ window.__goto(window.__page+1); }
                else { window.__goto(window.__page); flipChapter('next'); }
              } else if(dx>=th || (fast&&dx>0)){
                if(window.__page>0){ window.__goto(window.__page-1); }
                else { window.__goto(window.__page); flipChapter('prev'); }
              } else { window.__goto(window.__page); }   // not far enough → snap back
            }
            function flipChapter(dir){ try{ webkit.messageHandlers.reader.postMessage({type:'flip',dir:dir}); }catch(e){} }
            d.addEventListener('touchend',endDrag,{passive:false});
            d.addEventListener('touchcancel',function(){ if(dg.drag){ dg.drag=false; col.style.transition='transform .26s ease'; window.__goto(window.__page);} dg.active=false; },{passive:false});
          }

          var target=\(target);
          var matchQ=null, matchOcc=0;
          function applyTarget(){
            if(matchQ!==null){ if(!window.__gotoMatch(matchQ, matchOcc)) window.__gotoFraction(0); }
            else { window.__gotoFraction(typeof target==='number'?target:0); }
          }
          function full(){ layout(); window.__applyHighlights(\(hlsJSON)); applyTarget(); }
          \(matchSetup())
          full();
          window.addEventListener('load', full);
          window.addEventListener('resize', function(){ var f=window.__curFrac(); layout(); window.__gotoFraction(f); });
          setTimeout(full, 70); setTimeout(applyTarget, 260);
        })();
        """
    }

    /// Emits JS that sets matchQ/matchOcc when the pending landing is a search match.
    private func matchSetup() -> String {
        if case .match(let q, let occ) = pendingLanding {
            return "matchQ=\(q); matchOcc=\(occ);"
        }
        return ""
    }

    func runSetup() {
        let target: String
        switch pendingLanding {
        case .fraction(let f): target = String(format: "%.4f", f)
        case .match:           target = "0"
        }
        webView?.evaluateJavaScript(setupJS(target: target))
    }

    /// Page index the current pending landing resolves to, given a page count.
    func targetPageIndex(pageCount n: Int) -> Int {
        switch pendingLanding {
        case .fraction(let f): return min(max(0, n - 1), Int(round(f * Double(max(1, n - 1)))))
        case .match:           return 0
        }
    }

    func loadNextChapter() {
        guard chapterIndex < epub.spine.count - 1 else { return }
        chapterIndex += 1
        load(chapterIndex, landing: .fraction(0))
    }
    func loadPrevChapter() {
        guard chapterIndex > 0 else { return }
        chapterIndex -= 1
        load(chapterIndex, landing: .fraction(1))
    }
}

// MARK: - WKWebView delegates

extension ReaderController: WKNavigationDelegate, WKScriptMessageHandler {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.runSetup() }
    }

    nonisolated func webView(_ webView: WKWebView,
                             decidePolicyFor navigationAction: WKNavigationAction,
                             preferences: WKWebpagePreferences,
                             decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        preferences.preferredContentMode = .mobile
        decisionHandler(.allow, preferences)
    }

    nonisolated func userContentController(_ controller: WKUserContentController,
                                           didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        Task { @MainActor in
            switch type {
            case "state":
                if let p = body["page"] as? Int { self.page = p }
                if let n = body["pages"] as? Int { self.pageCount = n }
                if let f = body["frac"] as? Double { self.fraction = f; self.persist(fraction: f) }
                self.updatePageEstimate()
            case "sel":
                self.selectionActive = (body["active"] as? Bool) ?? false
                self.selectionTopY = CGFloat((body["top"] as? Double) ?? 0)
                self.selectionText = (body["text"] as? String) ?? ""
            case "flip":
                // Drag crossed a chapter boundary — roll to the next/previous chapter.
                let dir = body["dir"] as? String
                if dir == "next", self.chapterIndex < self.epub.spine.count - 1 {
                    self.chapterIndex += 1
                    self.load(self.chapterIndex, landing: .fraction(0))
                } else if dir == "prev", self.chapterIndex > 0 {
                    self.chapterIndex -= 1
                    self.load(self.chapterIndex, landing: .fraction(1))
                }
            default: break
            }
        }
    }
}
