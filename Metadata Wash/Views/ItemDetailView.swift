//
//  ItemDetailView.swift
//  Metadata Wash
//

import SwiftUI

struct ItemDetailView: View {
    @Environment(CleaningQueue.self) private var queue
    let item: MediaItem
    @State private var showing: ReportSide = .original

    enum ReportSide: String, CaseIterable, Identifiable {
        case original = "Original"
        case cleaned = "Cleaned Copy"
        var id: String { rawValue }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if case .failed(let message) = item.phase {
                    MessageBox(symbol: "xmark.octagon.fill", tint: .red, title: "Could not process this file", message: message)
                }
                if item.phase == .cleaning {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Cleaning and verifying…").foregroundStyle(.secondary)
                    }
                }
                if let result = item.result {
                    ResultCard(result: result, item: item)
                }
                if let report = displayedReport {
                    if case .present(let summary) = report.c2pa {
                        C2PACard(summary: summary)
                    }
                    metadataSection(report)
                } else if item.phase == .inspecting {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Inspecting metadata…").foregroundStyle(.secondary)
                    }
                }
                WatermarkNotice()
            }
            .padding(20)
            .frame(maxWidth: 820, alignment: .leading)
        }
        .onChange(of: item.result?.verification != nil) { _, hasVerification in
            showing = hasVerification ? .cleaned : .original
        }
    }

    private var displayedReport: MetadataReport? {
        showing == .cleaned ? (item.result?.verification ?? item.report) : item.report
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Group {
                if let image = item.thumbnail {
                    Image(nsImage: image).resizable().scaledToFit()
                } else {
                    Image(systemName: item.format?.kind == .video ? "film" : "photo")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.title3.weight(.semibold))
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    if let format = item.format { Text(format.displayName) }
                    if let size = item.report?.fileSize {
                        Text("·")
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    }
                }
                .foregroundStyle(.secondary)
                if let report = item.report { FindingBadges(report: report) }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                if item.result?.outputURL != nil {
                    Button("Show in Finder") { queue.reveal(item) }
                    Button("Open") { queue.open(item) }
                        .buttonStyle(.link)
                } else {
                    Button("Clean") { queue.clean([item]) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!item.canClean || queue.isCleaning)
                }
            }
        }
    }

    @ViewBuilder
    private func metadataSection(_ report: MetadataReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(showing == .cleaned ? "Metadata in the cleaned copy" : "Metadata found")
                    .font(.headline)
                Spacer()
                if item.result?.verification != nil {
                    Picker("Show", selection: $showing) {
                        ForEach(ReportSide.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            let removable = report.categories.filter(\.isRemovable)
            if removable.isEmpty {
                Label(showing == .cleaned ? "No removable metadata was found in the cleaned copy." : "No removable metadata was found.",
                      systemImage: "checkmark.seal")
                    .foregroundStyle(.secondary)
            }
            ForEach(report.categories, id: \.self) { category in
                CategorySection(category: category, items: report.items(in: category))
            }
            if !report.engineNotes.isEmpty {
                MessageBox(symbol: "info.circle", tint: .secondary, title: "Some checks could not run",
                           message: report.engineNotes.joined(separator: "\n"))
            }
        }
    }
}

/// One category of findings.
struct CategorySection: View {
    let category: MetadataCategory
    let items: [MetadataItem]
    @State private var isExpanded: Bool

    init(category: MetadataCategory, items: [MetadataItem]) {
        self.category = category
        self.items = items
        _isExpanded = State(initialValue: category == .aiGeneration || category == .contentCredentials || category == .location)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(items.prefix(400)) { item in
                    MetadataRow(item: item)
                    Divider()
                }
                if items.count > 400 {
                    Text("\(items.count - 400) more not shown").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                }
            }
            .padding(.leading, 4)
        } label: {
            HStack {
                Label(category.title, systemImage: category.systemImage)
                    .foregroundStyle(tint)
                Text("\(items.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .background(.quaternary, in: Capsule())
                if category.isPreserved {
                    Text("kept for correct display").font(.caption).foregroundStyle(.secondary)
                } else if category.isStructural {
                    Text("not metadata · always kept").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var tint: Color {
        switch category {
        case .aiGeneration: .purple
        case .contentCredentials: .blue
        case .location: .red
        case .rendering, .technical: .secondary
        default: .primary
        }
    }
}

struct MetadataRow: View {
    let item: MetadataItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.name).font(.callout.weight(.medium))
                Spacer()
                Text("\(item.group) · \(item.source.rawValue)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text(item.displayValue)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(4)
            if let reason = item.reason {
                Text(reason).font(.caption).foregroundStyle(.purple)
            }
            if item.removability == .requiresReencoding {
                Text("Stored in the encoded media; cannot be removed without re-encoding.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 6)
    }
}

/// Outcome of cleaning, from the independent verification pass.
struct ResultCard: View {
    let result: CleaningResult
    let item: MediaItem
    @State private var showSteps = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                StatusSymbol(status: result.status).font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.status.title).font(.headline)
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
            }
            if !result.removedCategories.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Removed").font(.subheadline.weight(.semibold))
                    FlowLayout(spacing: 6) {
                        ForEach(result.removedCategories) { category in
                            Label(category.title, systemImage: "checkmark")
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(.green.opacity(0.12), in: Capsule())
                        }
                    }
                }
            }
            if !result.remainingItems.isEmpty {
                itemList(title: "Still present", items: result.remainingItems, tint: .orange)
            }
            if !result.residualItems.isEmpty {
                itemList(title: "Not removable without re-encoding", items: result.residualItems, tint: .secondary)
            }
            if !result.preservedItems.isEmpty {
                Text("Kept for correct display: " + preservedSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(result.warnings, id: \.self) { warning in
                Label(warning, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !result.steps.isEmpty {
                DisclosureGroup("Processing details", isExpanded: $showSteps) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(result.steps, id: \.self) { Text("• " + $0).font(.caption).textSelection(.enabled) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    private var subtitle: String {
        switch result.status {
        case .cleaned: "The cleaned copy was re-inspected and no recognized removable metadata remains."
        case .partiallyCleaned: "The cleaned copy still contains some recognized metadata (listed below)."
        case .unverified: "A cleaned copy was saved, but not every verification engine could run."
        case .failed(let message): message
        case .unsupported(let message): message
        case .cancelled: "Cleaning was stopped."
        }
    }

    private var preservedSummary: String {
        let names = result.preservedItems.map { item -> String in
            item.group.hasPrefix("ICC_Profile") ? "ICC color profile" : item.name
        }
        return names.uniqued().prefix(8).joined(separator: ", ")
    }

    private func itemList(title: String, items: [MetadataItem], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(tint)
            ForEach(items.prefix(30)) { item in
                Text("\(item.group) · \(item.name): \(item.displayValue)")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(2)
            }
        }
    }
}

/// Summary of Content Credentials read with the C2PA SDK.
struct C2PACard: View {
    let summary: C2PASummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Content Credentials", systemImage: "checkmark.seal.fill")
                .font(.headline)
                .foregroundStyle(.blue)
            if summary.indicatesAIGeneration {
                Text("The manifest declares this media as generated by AI.")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.purple)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                row("Generator", summary.claimGenerators.joined(separator: ", "))
                row("Signed by", summary.issuer)
                row("Signed at", summary.signedAt)
                row("Title", summary.title)
                row("Actions", summary.actions.joined(separator: ", "))
                row("Source type", summary.digitalSourceTypes.map { $0.components(separatedBy: "/").last ?? $0 }.joined(separator: ", "))
                row("Manifests", "\(summary.manifestCount)" + (summary.isEmbedded ? " embedded" : " (remote)"))
                row("Validation", summary.validationState)
            }
            .font(.callout)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            GridRow {
                Text(label).foregroundStyle(.secondary)
                Text(value).textSelection(.enabled)
            }
        }
    }
}

struct MessageBox: View {
    let symbol: String
    let tint: Color
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct WatermarkNotice: View {
    var body: some View {
        Label {
            Text("Metadata Wash removes file metadata only. Invisible watermarks embedded in the pixels or video frames (such as Google SynthID) are part of the content and are not detected or removed, and visible watermarks are left untouched.")
        } icon: {
            Image(systemName: "eye.slash")
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
}

/// Summary when several or no files are selected.
struct BatchSummaryView: View {
    @Environment(CleaningQueue.self) private var queue

    var body: some View {
        let items = queue.items
        let cleaned = items.filter { $0.result?.status == .cleaned }.count
        let partial = items.filter { $0.result?.status == .partiallyCleaned || $0.result?.status == .unverified }.count
        let failed = items.filter { if case .failed = $0.phase { return true }; if case .failed = $0.result?.status { return true }; return false }.count
        let ai = items.filter { $0.report?.hasAIMetadata == true }.count
        let c2pa = items.filter { $0.report?.hasContentCredentials == true }.count
        let gps = items.filter { $0.report?.removableCategories.contains(.location) == true }.count

        VStack(spacing: 16) {
            Text("\(items.count) files").font(.title2.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow { Text("With AI-generation metadata").foregroundStyle(.secondary); Text("\(ai)") }
                GridRow { Text("With Content Credentials").foregroundStyle(.secondary); Text("\(c2pa)") }
                GridRow { Text("With location data").foregroundStyle(.secondary); Text("\(gps)") }
                Divider().gridCellUnsizedAxes(.horizontal)
                GridRow { Text("Cleaned and verified").foregroundStyle(.secondary); Text("\(cleaned)") }
                GridRow { Text("Partially cleaned / unverified").foregroundStyle(.secondary); Text("\(partial)") }
                GridRow { Text("Failed").foregroundStyle(.secondary); Text("\(failed)") }
            }
            .font(.callout.monospacedDigit())
            HStack {
                Button("Clean Selected") { queue.cleanSelection() }
                    .disabled(queue.selectedItems.filter(\.canClean).isEmpty || queue.isCleaning)
                Button("Show Cleaned Files") { queue.revealAllOutputs() }
                    .disabled(!items.contains { $0.result?.outputURL != nil })
            }
            WatermarkNotice().frame(maxWidth: 420)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Wrapping horizontal layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
