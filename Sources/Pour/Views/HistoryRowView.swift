import AppKit
import DesignKit
import HistoryKit
import SwiftUI

struct HistoryRowView: View {
    let entry: HistoryEntry
    var onDelete: () -> Void
    var onRestore: () -> Void
    @State private var showCorrections = false
    @State private var showRefinement = false
    @State private var didCopy = false

    init(
        entry: HistoryEntry,
        onDelete: @escaping () -> Void,
        onRestore: @escaping () -> Void,
        showChangesByDefault: Bool = false
    ) {
        self.entry = entry
        self.onDelete = onDelete
        self.onRestore = onRestore
        _showRefinement = State(initialValue: showChangesByDefault && !entry.refinementChanges.isEmpty)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: PourSpace.xs) {
            HStack(alignment: .top, spacing: PourSpace.sm) {
                Text(entry.text)
                    .font(PourFont.body(13))
                    .foregroundStyle(PourColor.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: PourSpace.sm) {
                    Button {
                        copy()
                    } label: {
                        Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                            .foregroundStyle(didCopy ? PourColor.success : PourColor.textDim)
                    }
                    .buttonStyle(.plain)
                    .help("Copy")

                    Button {
                        onDelete()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.pourDestructive)
                    .help("Delete")
                }
            }

            HStack(spacing: PourSpace.xs) {
                Text(Self.timeFormatter.string(from: entry.date))
                if let appName = entry.appName {
                    Text("\u{2192} \(appName)")
                }
                Text("\(entry.elapsedMS)ms")
                Text(entry.strategy)

                if !entry.corrections.isEmpty {
                    Button {
                        withAnimation(PourMotion.animation(.easeOut(duration: PourMotion.fast))) {
                            showCorrections.toggle()
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "wand.and.sparkles")
                            Text("\(entry.corrections.count) corrected")
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PourColor.success)
                }
                if !entry.refinementChanges.isEmpty {
                    Button {
                        withAnimation(PourMotion.animation(.easeOut(duration: PourMotion.fast))) {
                            showRefinement.toggle()
                        }
                    } label: {
                        Label("\(entry.refinementChanges.count) refined", systemImage: "wand.and.sparkles")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(entry.isRestored ? PourColor.textDim : PourColor.violet)
                }
            }
            .font(PourFont.mono(10.5))
            .foregroundStyle(PourColor.textDim)

            if showCorrections {
                VStack(alignment: .leading, spacing: PourSpace.xxs) {
                    ForEach(entry.corrections, id: \.matchedText) { correction in
                        HStack(spacing: PourSpace.xs) {
                            Text(correction.matchedText)
                                .strikethrough()
                                .foregroundStyle(PourColor.textDim)
                            Image(systemName: "arrow.right")
                                .foregroundStyle(PourColor.textDim)
                            Text(correction.replacement)
                                .foregroundStyle(PourColor.success)
                            Spacer()
                            Text(correction.label)
                                .foregroundStyle(PourColor.textDim)
                        }
                        .font(PourFont.mono(11))
                    }
                }
                .padding(PourSpace.sm)
                .background(PourColor.surfacePanel2)
                .clipShape(RoundedRectangle(cornerRadius: PourRadius.sm, style: .continuous))
            }

            if showRefinement {
                VStack(alignment: .leading, spacing: PourSpace.sm) {
                    Text("ORIGINAL").font(PourFont.caption()).foregroundStyle(PourColor.textDim)
                    Text(entry.rawText)
                        .font(PourFont.mono(11)).foregroundStyle(PourColor.textMuted).textSelection(.enabled)

                    Divider().overlay(PourColor.borderHairline)
                    ForEach(Array(entry.refinementChanges.enumerated()), id: \.offset) { _, change in
                        HStack(alignment: .firstTextBaseline, spacing: PourSpace.xs) {
                            Text(change.original.isEmpty ? "∅" : change.original)
                                .strikethrough(!change.original.isEmpty).foregroundStyle(PourColor.warning)
                            Image(systemName: "arrow.right").foregroundStyle(PourColor.textDim)
                            Text(change.replacement.isEmpty ? "removed" : change.replacement)
                                .foregroundStyle(PourColor.success)
                            Spacer()
                            Text(change.rule).foregroundStyle(PourColor.textDim)
                        }
                        .font(PourFont.mono(10.5))
                    }

                    HStack {
                        if !entry.detectedCommands.isEmpty {
                            Text("Commands: \(entry.detectedCommands.joined(separator: ", "))")
                                .font(PourFont.callout()).foregroundStyle(PourColor.blue400)
                        }
                        Spacer()
                        Button(entry.isRestored ? "Original restored" : "Restore Original") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(entry.rawText, forType: .string)
                            onRestore()
                        }
                        .disabled(entry.isRestored)
                        .help("Copies the original transcript and records this refinement as reverted")
                    }
                }
                .padding(PourSpace.sm)
                .background(PourColor.surfacePanel2)
                .clipShape(RoundedRectangle(cornerRadius: PourRadius.sm, style: .continuous))
            }
        }
        .padding(PourSpace.md)
        .background(PourColor.surfacePanel)
        .clipShape(RoundedRectangle(cornerRadius: PourRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PourRadius.lg, style: .continuous)
                .strokeBorder(PourColor.borderHairline, lineWidth: PourBorder.hairline)
        )
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)
        didCopy = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            didCopy = false
        }
    }
}
