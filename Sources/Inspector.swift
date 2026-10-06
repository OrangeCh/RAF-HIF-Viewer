import SwiftUI

struct InspectorView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet.rectangle").foregroundStyle(.secondary)
                Text("参数对照").font(.system(size: 12, weight: .semibold))
                Spacer()
                if let p = model.currentPair {
                    Text(p.stem).font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(.ultraThinMaterial)

            if model.currentPair == nil {
                ContentUnavailableView("未选择照片", systemImage: "info.circle")
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        summaryCard
                        ForEach(model.metaSections) { sec in
                            VStack(alignment: .leading, spacing: 0) {
                                Text(sec.title)
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.secondary)
                                    .padding(.bottom, 4)
                                ForEach(sec.rows) { row in
                                    MetaRowView(row: row)
                                    if row.id != sec.rows.last?.id { Divider().opacity(0.35) }
                                }
                            }
                        }
                        if model.metaSections.isEmpty {
                            Text("正在读取参数…").font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                }
            }
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("RAF", systemImage: "circle.fill")
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(.orange)
                Spacer()
                Label("HIF", systemImage: "circle.fill")
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(.cyan)
            }
            .labelStyle(.titleAndIcon)

            let diffCount = model.metaSections.flatMap { $0.rows }.filter { $0.differs }.count
            if diffCount == 0 {
                Text("两侧参数完全一致")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                Text(L.f("有 %d 项参数不同（已高亮）", diffCount))
                    .font(.system(size: 11)).foregroundStyle(.primary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct MetaRowView: View {
    let row: MetaRow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(row.label).font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                if row.differs {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 8)).foregroundStyle(.purple)
                }
            }
            HStack(spacing: 6) {
                Text(row.left)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(row.differs ? Color.orange : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(2).textSelection(.enabled)
                Text(row.right)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(row.differs ? Color.cyan : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(2).textSelection(.enabled)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(row.differs ? Color.purple.opacity(0.10) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5))
    }
}
