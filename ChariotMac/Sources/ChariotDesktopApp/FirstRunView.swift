import SwiftUI
import ChariotCore

/// First-run gate: Chariot cannot create an agent without the guest base image,
/// so a fresh install lands here instead of letting the first Start fail deep in
/// the VM layer with a missing-file error.
struct FirstRunView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "diamond")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.secondary)
                Text("~/chariot")
                    .font(Theme.mono(12, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("setup")
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 20)

            VStack(alignment: .leading, spacing: 14) {
                SectionHash(title: "guest base image")

                Card(title: "Debian 12 (arm64) — \(model.baseImageVersion)",
                     subtitle: "Every agent runs in its own VM cloned from this image. Chariot downloads it once.") {
                    VStack(alignment: .leading, spacing: 14) {
                        KVRow(key: "download", value: model.baseImageDownloadSize)
                        KVRow(key: "on disk", value: "~1.3 GB (sparse)")
                        KVRow(key: "location", value: model.baseImagePath)

                        switch model.setupPhase {
                        case .idle:
                            Text("Nothing is downloaded yet. This needs a network connection and a few minutes.")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.secondary)
                        case .running(let progress):
                            progressBlock(progress)
                        case .failed(let message):
                            failureBlock(message)
                        }
                    }
                }

                HStack(spacing: 10) {
                    switch model.setupPhase {
                    case .idle:
                        Button("Download and continue") { model.installBaseImage() }
                            .buttonStyle(AccentButtonStyle())
                    case .running:
                        Button("Cancel") { model.cancelBaseImageInstall() }
                            .buttonStyle(OutlineButtonStyle())
                    case .failed:
                        Button("Try again") { model.installBaseImage() }
                            .buttonStyle(AccentButtonStyle())
                    }
                    Spacer()
                }

                Text("Already have the image? Set CHARIOT_BASE_IMAGE to its path and reopen Chariot.")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.secondary)
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 20)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func progressBlock(_ progress: BaseImageProgress) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            switch progress {
            case .downloading(let received, let total):
                ProgressView(value: Double(received), total: Double(max(total, 1)))
                    .tint(Theme.accent)
                HStack {
                    Text("downloading")
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.secondary)
                    Spacer()
                    Text("\(byteString(received)) / \(byteString(total))")
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.text)
                }
            case .verifying:
                indeterminate("verifying checksum")
            case .expanding:
                indeterminate("expanding image — this takes a minute")
            case .installed:
                indeterminate("finishing")
            }
        }
    }

    @ViewBuilder
    private func indeterminate(_ label: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(label)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.secondary)
        }
    }

    @ViewBuilder
    private func failureBlock(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.amber)
                Text("Setup failed")
                    .font(Theme.mono(12, weight: .medium))
                    .foregroundStyle(Theme.text)
            }
            Text(message)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
