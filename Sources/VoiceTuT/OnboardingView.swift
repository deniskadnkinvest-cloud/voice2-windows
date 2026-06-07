import SwiftUI

// Онбординг для нового пользователя: выбираешь модель распознавания,
// она скачивается с HuggingFace в ~/Library/Application Support/VoiceTuT/models/.
// Тот же экран используется в настройках как «Сменить модель».
//
// Не блокирует UI приложения — пользователь может закрыть окно во время
// скачивания, оно продолжится в фоне (NSPanel со ссылкой на ModelManager).

struct OnboardingView: View {
    @ObservedObject private var manager = ModelManager.shared
    @State private var selected: ModelManager.Model = .largeV3Turbo
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            Divider()

            Text("Выбери модель распознавания речи")
                .font(.system(size: 13, weight: .semibold))

            Text("Локальный Whisper.cpp работает на твоей машине, аудио никуда не уходит. Только модель надо один раз скачать.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 6) {
                ForEach(ModelManager.Model.allCases) { model in
                    modelRow(model)
                }
            }

            if manager.isDownloading {
                downloadProgressBlock
            } else if let err = manager.downloadError {
                Text("Ошибка: \(err)")
                    .font(.system(size: 11))
                    .foregroundColor(.red)
            }

            Spacer(minLength: 6)

            HStack {
                if manager.isModelAvailable(manager.currentModel) {
                    Button("Закрыть") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                Spacer()
                Button(action: startDownload) {
                    if manager.isDownloading {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Скачивается…")
                        }
                    } else if manager.isModelAvailable(selected) {
                        Text("Использовать эту модель")
                    } else {
                        Text("Скачать (\(selected.humanSize))")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(manager.isDownloading)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: "waveform")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.accentColor)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("VoiceTuT")
                    .font(.system(size: 15, weight: .bold))
                Text("Голос в текст для macOS")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }

    func modelRow(_ model: ModelManager.Model) -> some View {
        let isSelected = selected == model
        let isInstalled = manager.isModelAvailable(model)
        let isCurrent = manager.currentModel == model && isInstalled
        return Button {
            selected = model
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 14))
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(model.displayName)
                            .font(.system(size: 12, weight: .semibold))
                        if isCurrent {
                            Text("активна")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(.green)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.green.opacity(0.15), in: Capsule())
                        } else if isInstalled {
                            Text("скачана")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(.blue)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.blue.opacity(0.15), in: Capsule())
                        }
                    }
                    Text(model.summary)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: 1)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isSelected ? Color.accentColor.opacity(0.06) : Color.clear)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    var downloadProgressBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let m = manager.downloadingModel {
                Text("Скачивается \(m.displayName) (\(m.humanSize))…")
                    .font(.system(size: 11))
            }
            ProgressView(value: manager.downloadProgress)
            Text("\(Int(manager.downloadProgress * 100))% — можешь закрыть окно, продолжится в фоне")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func startDownload() {
        let target = selected
        if manager.isModelAvailable(target) {
            manager.setCurrentModel(target)
            dismiss()
            return
        }
        Task { await manager.downloadModel(target) }
    }
}
