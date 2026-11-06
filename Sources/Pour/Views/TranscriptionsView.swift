import DesignKit
import FlowCore
import HistoryKit
import SwiftUI

struct TranscriptionsView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""

    private var isCapturing: Bool { model.dictationState == .capturing }
    private var isBusy: Bool { model.dictationState.isBusy }

    private var filtered: [HistoryEntry] {
        model.history.search(query)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(PourSpace.lg)
                .background(PourColor.bgAlt)

            Divider().overlay(PourColor.borderHairline)

            if filtered.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: PourSpace.sm) {
                        ForEach(filtered) { entry in
                            HistoryRowView(
                                entry: entry,
                                onDelete: { model.history.delete(entry) },
                                onRestore: { _ = model.history.markRestored(id: entry.id) },
                                showChangesByDefault: model.settings.showChangesBeforeInsertion
                            )
                        }
                    }
                    .padding(PourSpace.lg)
                }
            }
        }
        .navigationTitle("Transcriptions")
        .searchable(text: $query, placement: .toolbar, prompt: "Search transcriptions")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: PourSpace.sm) {
            HStack(spacing: PourSpace.md) {
                Button {
                    toggleCapture()
                } label: {
                    Label(isCapturing ? "Stop" : "Start", systemImage: isCapturing ? "stop.fill" : "mic.fill")
                        .frame(minWidth: 68)
                }
                .buttonStyle(.pourPrimary)
                .disabled(isBusy && !isCapturing)

                LevelMeterView(level: model.level, isActive: isCapturing)
                    .frame(maxWidth: 260)

                Spacer()

                statusBadge
            }

            Text(hint)
                .font(PourFont.callout())
                .foregroundStyle(PourColor.textMuted)
        }
    }

    private var idleHotkeyHint: String {
        switch model.settings.interactionMode {
        case .holdToTalk: "Hold your dictation key anywhere, or press Start here."
        case .toggle: "Press your dictation key anywhere, or press Start here."
        }
    }

    private var hint: String {
        switch model.dictationState {
        case .starting: "Starting Pour\u{2026}"
        case .idle: idleHotkeyHint
        case .capturing: model.preview.isEmpty ? "Listening\u{2026}" : model.preview
        case .finishing: "Transcribing\u{2026}"
        case .refining: "Refining locally\u{2026}"
        case .injecting: "Delivering\u{2026}"
        case .blocked(let reason): reason
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        let (label, color): (String, Color) = switch model.dictationState {
        case .starting: ("Starting", PourColor.textDim)
        case .idle: ("Ready", PourColor.success)
        case .capturing: ("Listening", PourColor.amber)
        case .finishing: ("Transcribing", PourColor.blue500)
        case .refining: ("Refining", PourColor.violet)
        case .injecting: ("Inserted", PourColor.success)
        case .blocked: ("Blocked", PourColor.error)
        }
        HStack(spacing: PourSpace.xxs) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(PourFont.caption())
        }
        .foregroundStyle(color)
    }

    private var emptyState: some View {
        VStack(spacing: PourSpace.sm) {
            Spacer()
            Text("Nothing dictated yet")
                .font(PourFont.display(24))
                .foregroundStyle(PourColor.text)
            Text("Hold your dictation key, or press Start above.")
                .font(PourFont.body())
                .foregroundStyle(PourColor.textMuted)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func toggleCapture() {
        if isCapturing {
            model.controller.endCaptureFromUI()
        } else if model.dictationState == .idle {
            model.controller.beginCaptureFromUI()
        }
    }
}
