import SwiftUI

struct SettingsView: View {
    @StateObject private var downloadManager = ModelDownloadManager()

    private var modelsByModality: [(ModelModality, [DownloadableModel])] {
        ModelModality.allCases.map { modality in
            (modality, DownloadableModel.embedded.filter { $0.modality == modality })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(modelsByModality, id: \.0.id) { modality, models in
                        modelSection(modality: modality, models: models)
                    }
                }
                .padding(.bottom, 12)
            }
        }
        .padding(24)
        .frame(width: 720, height: 560)
        .onAppear {
            downloadManager.refreshStatuses()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Models")
                .font(.largeTitle.weight(.semibold))

            Text("Download Hugging Face models to the default cache when possible. ACE-Step uses MLXHub checkpoints.")
                .foregroundStyle(.secondary)
        }
    }

    private func modelSection(modality: ModelModality, models: [DownloadableModel]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(modality.rawValue, systemImage: modality.icon)
                .font(.headline)

            VStack(spacing: 0) {
                ForEach(models) { model in
                    ModelDownloadRow(model: model, downloadManager: downloadManager)

                    if model.id != models.last?.id {
                        Divider()
                    }
                }
            }
            .background(.quaternary.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct ModelDownloadRow: View {
    let model: DownloadableModel
    @ObservedObject var downloadManager: ModelDownloadManager

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.name)
                    .font(.body.weight(.medium))

                Text(model.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Text(model.modelId)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 16)

            VStack(alignment: .trailing, spacing: 8) {
                Text("\(String(format: "%.1f", model.downloadSizeGB)) GB")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                statusView
            }
            .frame(minWidth: 150, alignment: .trailing)
        }
        .padding(14)
    }

    @ViewBuilder
    private var statusView: some View {
        switch downloadManager.state(for: model) {
        case .notDownloaded:
            Button("Download") {
                downloadManager.download(model)
            }
            .buttonStyle(.borderedProminent)

        case .downloading(let progress):
            VStack(alignment: .trailing, spacing: 5) {
                if let fractionCompleted = progress?.fractionCompleted {
                    ProgressView(value: fractionCompleted)
                        .frame(width: 140)
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(progress?.displayText ?? "Downloading")
                    }
                }

                Text(progress?.displayText ?? "Downloading")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let detailText = progress?.detailText {
                    Text(detailText)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

        case .downloaded:
            Label("Downloaded", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)

        case .failed(let message):
            VStack(alignment: .trailing, spacing: 6) {
                Label("Failed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)

                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Button("Retry") {
                    downloadManager.download(model)
                }
            }
        }
    }
}

#Preview {
    SettingsView()
}
