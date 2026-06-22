import SwiftUI
import VisionKit

/// Device-linking screen: scan the server QR (or enter URL+token manually),
/// claim a device key, store it. Shows linked status + connectivity check.
struct PairingView: View {
    @EnvironmentObject var config: ServerConfig
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @State private var deviceName = UIDevice.current.name
    @State private var urlInput = "http://localhost:8090"
    @State private var tokenInput = ""
    @State private var busy = false
    @State private var error: String?
    @State private var booksCount: Int?
    @State private var showScanner = false
    @State private var syncInfo: String?
    @State private var serverVersion: String?
    @State private var serverDemo = false
    @State private var updateNote: String?

    var body: some View {
        NavigationStack {
            Form {
                if config.isLinked {
                    Section("Подключено") {
                        LabeledContent("Сервер", value: config.serverURL ?? "—")
                        LabeledContent("Устройство", value: config.deviceName ?? "—")
                        if let serverVersion { LabeledContent("Версия сервера", value: serverVersion) }
                        if serverDemo {
                            Label("Демо · только чтение", systemImage: "eye")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        if let updateNote {
                            Label(updateNote, systemImage: "arrow.up.circle")
                                .font(.footnote).foregroundStyle(.green)
                        }
                        if let n = booksCount { LabeledContent("Книг на сервере", value: "\(n)") }
                        Button("Синхронизировать") { Task { await runSync() } }
                        if let syncInfo { Text(syncInfo).font(.footnote).foregroundStyle(.secondary) }
                        Button("Проверить связь") { Task { await checkConnection() } }
                        Button("Отвязать", role: .destructive) { config.unlink(); booksCount = nil; syncInfo = nil }
                    }
                } else {
                    Section("Привязать к серверу") {
                        if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                            Button {
                                showScanner = true
                            } label: { Label("Сканировать QR-код", systemImage: "qrcode.viewfinder") }
                        }
                        TextField("Имя устройства", text: $deviceName)
                    }
                    Section("Вручную (для теста)") {
                        TextField("Адрес сервера", text: $urlInput)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("Токен (t из QR)", text: $tokenInput)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Привязать") {
                            Task { await claim(PairPayload(url: urlInput, t: tokenInput)) }
                        }
                        .disabled(busy || tokenInput.isEmpty || urlInput.isEmpty)
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red).font(.footnote) } }
            }
            .navigationTitle("Синхронизация")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Готово") { dismiss() } } }
            .overlay { if busy { ProgressView().controlSize(.large) } }
            .task { if config.isLinked { await checkConnection() } }
            .sheet(isPresented: $showScanner) {
                QRScannerView { code in
                    showScanner = false
                    if let payload = parse(code) { Task { await claim(payload) } }
                    else { error = "QR не распознан" }
                }
            }
        }
    }

    private func parse(_ code: String) -> PairPayload? {
        try? JSONDecoder().decode(PairPayload.self, from: Data(code.utf8))
    }

    private func claim(_ payload: PairPayload) async {
        busy = true; error = nil
        defer { busy = false }
        do {
            let (base, resp) = try await APIClient.claim(payload: payload, deviceName: deviceName)
            config.link(url: base, key: resp.key, deviceName: resp.deviceName)
            await checkConnection()
        } catch { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
    }

    private func runSync() async {
        busy = true; error = nil; syncInfo = nil
        defer { busy = false }
        do {
            let r = try await SyncService.sync(store: store, config: config)
            syncInfo = "Совпало: \(r.matched) · ↑\(r.pushed) ↓\(r.pulled) · аннотаций: \(r.annotations)"
        } catch { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
    }

    private func checkConnection() async {
        guard let url = config.serverURL else { return }
        let client = APIClient(baseURL: url, apiKey: config.deviceKey)
        do { booksCount = try await client.booksCount() }
        catch { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        if let setup = try? await client.getSetup() {
            serverVersion = setup.version
            serverDemo = setup.demo ?? false
        }
        if let upd = try? await client.getUpdate(), upd.updateAvailable == true {
            updateNote = "Доступно обновление " + (upd.latest ?? "")
        }
    }
}

/// VisionKit QR scanner (real devices; simulator falls back to manual entry).
struct QRScannerView: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                          qualityLevel: .balanced, isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        try? vc.startScanning()
        return vc
    }
    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScan: (String) -> Void
        init(onScan: @escaping (String) -> Void) { self.onScan = onScan }
        func dataScanner(_ s: DataScannerViewController, didAdd added: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in added {
                if case let .barcode(b) = item, let v = b.payloadStringValue { onScan(v); break }
            }
        }
    }
}
