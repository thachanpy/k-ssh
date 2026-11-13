import SSHCore
import SwiftUI

/// Bottom panel listing transfers with progress, speed, cancel and errors.
struct TransferPanelView: View {
    let model: SFTPBrowserViewModel

    var body: some View {
        if model.transfers.isEmpty {
            Text("No transfers. Drag files between the panes, or use the context menu.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        } else {
            VStack(spacing: 0) {
                HStack {
                    Text("Transfers").font(.caption.bold())
                    Spacer()
                    Button(String(localized: "Clear Finished")) { model.clearFinishedTransfers() }
                        .buttonStyle(.link).font(.caption)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                Divider()
                List(model.transfers) { item in
                    TransferRow(item: item, onCancel: { model.cancelTransfer(item.id) })
                }
                .listStyle(.plain)
                .frame(height: min(CGFloat(model.transfers.count) * 34 + 8, 150))
            }
        }
    }
}

private struct TransferRow: View {
    let item: TransferItem
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.job.kind == .upload ? "arrow.up.circle" : "arrow.down.circle")
                .accessibilityHidden(true)
            Text(item.job.name).lineLimit(1).frame(width: 160, alignment: .leading)
            switch item.state {
            case .queued:
                Text("Queued").foregroundStyle(.secondary)
            case .running:
                if let fraction = item.progress?.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(speedText).font(.caption).foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
            case .finished:
                Label(String(localized: "Done"), systemImage: "checkmark.circle").foregroundStyle(.green)
            case .cancelled:
                Label(String(localized: "Cancelled"), systemImage: "xmark.circle").foregroundStyle(.secondary)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red).lineLimit(1)
            }
            Spacer(minLength: 0)
            if !item.isDone {
                Button(action: onCancel) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(String(localized: "Cancel transfer"))
            }
        }
        .font(.callout)
    }

    private var speedText: String {
        guard let speed = item.bytesPerSecond else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file) + "/s"
    }
}
