import Foundation
import AppKit
import Combine
import SwiftUI
import WebKit

// MARK: - Item de Download
// Representa um único download da sessão. É um ObservableObject para que a
// linha correspondente na janela de Downloads atualize o progresso em tempo real.

public final class DownloadItem: ObservableObject, Identifiable {

    public enum State: Equatable {
        case inProgress
        case finished
        case failed
        case cancelled
    }

    public let id       = UUID()
    public let filename: String
    public let startedAt = Date()

    @Published public var destinationURL: URL?
    @Published public var receivedBytes:  Int64  = 0
    @Published public var totalBytes:     Int64  = 0
    @Published public var state:          State  = .inProgress
    @Published public var errorMessage:   String?

    /// Referência fraca ao WKDownload — usada apenas para cancelar.
    weak var download: WKDownload?

    init(filename: String, download: WKDownload?) {
        self.filename = filename
        self.download = download
    }

    public var isActive: Bool { state == .inProgress }

    public var progressFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1.0, Double(receivedBytes) / Double(totalBytes))
    }

    public var statusText: String {
        switch state {
        case .inProgress:
            if totalBytes > 0 {
                let done  = ByteCountFormatter.string(fromByteCount: receivedBytes, countStyle: .file)
                let total = ByteCountFormatter.string(fromByteCount: totalBytes,    countStyle: .file)
                return "\(done) de \(total)"
            }
            return "Baixando…"
        case .finished:
            let size = ByteCountFormatter.string(fromByteCount: max(receivedBytes, totalBytes), countStyle: .file)
            return totalBytes > 0 ? "Concluído · \(size)" : "Concluído"
        case .failed:    return errorMessage ?? "Falha no download"
        case .cancelled: return "Cancelado"
        }
    }
}

// MARK: - Gerenciador de Downloads
// Singleton que mantém o histórico da sessão e observa o progresso via KVO no
// Progress de cada WKDownload. Substitui os NSAlert modais bloqueantes que
// interrompiam o fluxo a cada download concluído/falho.

public final class DownloadsManager: ObservableObject {

    public static let shared = DownloadsManager()

    @Published public private(set) var items: [DownloadItem] = []

    /// Observadores KVO mantidos vivos enquanto o download existir.
    private var progressObservers: [UUID: NSKeyValueObservation] = [:]

    private init() {}

    public var activeCount: Int { items.lazy.filter { $0.isActive }.count }
    public var hasFinished: Bool { items.contains { !$0.isActive } }

    // MARK: Ciclo de vida

    @discardableResult
    func register(_ download: WKDownload, suggestedFilename: String) -> DownloadItem {
        if let existing = item(for: download) { return existing }
        let item = DownloadItem(filename: suggestedFilename, download: download)
        items.insert(item, at: 0)
        observeProgress(of: download, item: item)
        return item
    }

    func item(for download: WKDownload) -> DownloadItem? {
        items.first { $0.download === download }
    }

    func setDestination(_ url: URL, for download: WKDownload) {
        item(for: download)?.destinationURL = url
    }

    func markFinished(_ download: WKDownload) {
        guard let item = item(for: download) else { return }
        item.state         = .finished
        item.receivedBytes = max(item.receivedBytes, item.totalBytes)
        progressObservers[item.id] = nil
        NSApp.requestUserAttention(.informationalRequest)
    }

    func markFailed(_ download: WKDownload, error: Error) {
        guard let item = item(for: download) else { return }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled {
            item.state = .cancelled
        } else {
            item.state        = .failed
            item.errorMessage = error.localizedDescription
        }
        progressObservers[item.id] = nil
    }

    func cancel(_ item: DownloadItem) {
        item.download?.cancel()
        item.state = .cancelled
        progressObservers[item.id] = nil
    }

    public func clearFinished() {
        items.removeAll { !$0.isActive }
    }

    // MARK: Progresso

    private func observeProgress(of download: WKDownload, item: DownloadItem) {
        let obs = download.progress.observe(\.fractionCompleted, options: [.initial, .new]) { [weak item] progress, _ in
            guard let item else { return }
            DispatchQueue.main.async {
                item.totalBytes    = progress.totalUnitCount
                item.receivedBytes = progress.completedUnitCount
            }
        }
        progressObservers[item.id] = obs
    }

    // MARK: Utilitário — destino sem sobrescrever

    static func uniqueDestination(in folder: URL, filename: String) -> URL {
        let fm   = FileManager.default
        let safe = filename.isEmpty ? "download" : filename
        var candidate = folder.appendingPathComponent(safe)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }

        let ext  = candidate.pathExtension
        let base = candidate.deletingPathExtension().lastPathComponent
        var i = 1
        repeat {
            let name = ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)"
            candidate = folder.appendingPathComponent(name)
            i += 1
        } while fm.fileExists(atPath: candidate.path)
        return candidate
    }
}

// MARK: - Janela de Downloads

struct DownloadsWindow: View {
    @ObservedObject private var manager = DownloadsManager.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Downloads").font(.headline)
                Spacer()
                Button("Limpar concluídos") { manager.clearFinished() }
                    .disabled(!manager.hasFinished)
            }
            .padding(12)

            Divider()

            if manager.items.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 34))
                        .foregroundColor(.secondary)
                    Text("Nenhum download nesta sessão")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(manager.items) { item in
                            DownloadRow(item: item)
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(minWidth: 440, minHeight: 320)
    }
}

private struct DownloadRow: View {
    @ObservedObject var item: DownloadItem
    private let manager = DownloadsManager.shared

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundColor(iconColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.filename)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if item.isActive {
                    ProgressView(value: item.progressFraction)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 220)
                }

                Text(item.statusText)
                    .font(.caption)
                    .foregroundColor(item.state == .failed ? .red : .secondary)
                    .lineLimit(1)
            }

            Spacer()

            actionButtons
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch item.state {
        case .inProgress:
            Button("Cancelar") { manager.cancel(item) }
                .buttonStyle(.bordered)

        case .finished:
            HStack(spacing: 6) {
                Button {
                    if let url = item.destinationURL { NSWorkspace.shared.open(url) }
                } label: { Image(systemName: "arrow.up.forward.app") }
                    .help("Abrir arquivo")

                Button {
                    if let url = item.destinationURL {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                } label: { Image(systemName: "magnifyingglass") }
                    .help("Mostrar no Finder")
            }
            .buttonStyle(.bordered)
            .disabled(item.destinationURL == nil)

        case .failed, .cancelled:
            EmptyView()
        }
    }

    private var icon: String {
        switch item.state {
        case .inProgress: return "arrow.down.circle"
        case .finished:   return "doc.fill"
        case .failed:     return "exclamationmark.triangle.fill"
        case .cancelled:  return "xmark.circle"
        }
    }

    private var iconColor: Color {
        switch item.state {
        case .inProgress: return .accentColor
        case .finished:   return .accentColor
        case .failed:     return .red
        case .cancelled:  return .secondary
        }
    }
}
