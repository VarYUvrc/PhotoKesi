import SwiftUI

struct SettingsView: View {
    @ObservedObject var libraryViewModel: PhotoLibraryViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var isRetentionResetAlertPresented = false
    @State private var isResettingRetentionFlags = false

    private let stepMinutes = 15
    private let minMinutes = PhotoLibraryViewModel.minGroupingMinutes
    private let maxMinutes = PhotoLibraryViewModel.maxGroupingMinutes

    var body: some View {
        let swipeGesture = DragGesture(minimumDistance: 60)
            .onEnded { value in
                let horizontal = value.translation.width
                let vertical = value.translation.height
                guard abs(horizontal) > abs(vertical) else { return }
                if horizontal < -80 {
                    dismiss()
                }
            }

        ScrollView {
            VStack(spacing: 20) {
                settingsGroup(title: "一般", containerColor: Color(uiColor: .tertiarySystemGroupedBackground)) {
                    Group {
                        Text("使用状況")
                            .font(.footnote.weight(.semibold))
                        usageCard
                    }

                    Group {
                        Text("プラン比較（ダミー）")
                            .font(.footnote.weight(.semibold))
                        planComparisonCard
                    }
                }

                settingsGroup(title: "ユーザー設定", containerColor: Color(uiColor: .tertiarySystemGroupedBackground)) {
                    Group {
                        Text("整理設定")
                            .font(.footnote.weight(.semibold))
                        groupingCard
                    }

                    Group {
                        Text("カラーパレット設定（ダミー）")
                            .font(.footnote.weight(.semibold))
                        paletteCard
                    }
                }
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 16)
        }
        .navigationTitle("設定")
        .navigationBarTitleDisplayMode(.inline)
        .simultaneousGesture(swipeGesture)
        .onAppear {
            libraryViewModel.refreshAdvanceQuotaIfNeeded()
        }
        .alert("「残す」フラグをリセット", isPresented: $isRetentionResetAlertPresented) {
            Button("キャンセル", role: .cancel) {}
            Button("リセット", role: .destructive) {
                isResettingRetentionFlags = true
                Task {
                    await libraryViewModel.resetRetainedFlags()
                    await MainActor.run {
                        isResettingRetentionFlags = false
                    }
                }
            }
        } message: {
            Text("これまでに仕分けで「残す」にした写真を再び探索対象に戻します。バケツの内容は変わりません。")
        }
    }

    private var usageCard: some View {
        let limit = Double(PhotoLibraryViewModel.dailyAdvanceLimit)
        let used = Double(min(PhotoLibraryViewModel.dailyAdvanceLimit, libraryViewModel.advancesPerformedToday))

        return settingsInnerBackground(Color(uiColor: .secondarySystemGroupedBackground)) {
            LabeledContent("仕分けできる残り回数") {
                Text("\(libraryViewModel.remainingAdvanceQuota) / \(PhotoLibraryViewModel.dailyAdvanceLimit) 回")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(libraryViewModel.remainingAdvanceQuota > 0 ? Color.primary : Color.red)
            }
            .font(.footnote)

            LabeledContent("本日仕分けした回数") {
                Text("\(libraryViewModel.advancesPerformedToday) 回")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .font(.footnote)

            LabeledContent("本日削除した写真のデータ量") {
                Text("- MB（ダミー）")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .font(.footnote)

            LabeledContent("これまでに削除した写真のデータ量") {
                Text("- MB（ダミー）")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .font(.footnote)

            ProgressView(value: used, total: max(limit, 1))
                .tint(.red)

            Text("無料プランは1日に最大 \(PhotoLibraryViewModel.dailyAdvanceLimit) 回まで仕分けできます。0:00に自動でリセットされます。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Button {
                isRetentionResetAlertPresented = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.counterclockwise.circle")
                        .font(.title3)
                        .foregroundStyle(.blue)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("「残す」フラグをリセット")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(isResettingRetentionFlags ? Color.secondary : Color.primary)

                        Text("確定済みの写真が再び探索対象になります。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if isResettingRetentionFlags {
                        ProgressView()
                            .progressViewStyle(.circular)
                    }
                }
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .disabled(isResettingRetentionFlags)
        }
    }

    private var planComparisonCard: some View {
        settingsInnerBackground(Color(uiColor: .secondarySystemGroupedBackground)) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Text("機能")
                        .font(.footnote.weight(.semibold))
                    Text("Free")
                        .font(.footnote.weight(.semibold))
                    Text("Max")
                        .font(.footnote.weight(.semibold))
                }

                GridRow {
                    Divider()
                        .gridCellColumns(3)
                }

                featureRow(title: "1日の仕分け確定", free: "3回まで", paid: "無制限")
                featureRow(title: "スクリーンショット整理", free: "×", paid: "◯")
                featureRow(title: "理由バッジ表示", free: "×", paid: "◯")
                featureRow(title: "アプリのテーマカラー選択", free: "3色のみ", paid: "カスタム")
            }

            Text("※表示はダミーです。サブスクリプション決済はまだ提供していません。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var groupingCard: some View {
        settingsInnerBackground(Color(uiColor: .secondarySystemGroupedBackground)) {
            Stepper(value: bindingForGroupingWindow(), in: minMinutes...maxMinutes, step: stepMinutes) {
                Text("時間幅: \(formattedWindow(minutes: libraryViewModel.groupingWindowMinutes))")
                    .font(.footnote)
            }

            Slider(value: bindingForSlider(), in: Double(minMinutes)...Double(maxMinutes), step: Double(stepMinutes))
                .accessibilityLabel("グループの対象時間幅")

            Text("撮影時刻が指定した時間幅内に収まる写真を同じグループとして扱います。幅を広げるとグループは少なく、狭めると細かく分割されます。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var paletteCard: some View {
        settingsInnerBackground(Color(uiColor: .secondarySystemGroupedBackground)) {
            colorPaletteSection()
        }
    }

    private func settingsGroup<Content: View>(title: String,
                                              containerColor: Color,
                                              @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.subheadline.weight(.semibold))

            settingsInnerBackground(containerColor, spacing: 20) {
                content()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color(uiColor: .systemGroupedBackground))
        )
    }

    private func bindingForGroupingWindow() -> Binding<Int> {
        Binding {
            libraryViewModel.groupingWindowMinutes
        } set: { newValue in
            libraryViewModel.groupingWindowMinutes = newValue
        }
    }

    private func bindingForSlider() -> Binding<Double> {
        Binding {
            Double(libraryViewModel.groupingWindowMinutes)
        } set: { newValue in
            let stepped = Int((newValue / Double(stepMinutes)).rounded()) * stepMinutes
            let clamped = max(minMinutes, min(maxMinutes, stepped))
            libraryViewModel.groupingWindowMinutes = clamped
        }
    }

    private func formattedWindow(minutes: Int) -> String {
        if minutes < 60 {
            return "約\(minutes)分"
        }

        let hours = minutes / 60
        let remainingMinutes = minutes % 60

        if remainingMinutes == 0 {
            return "約\(hours)時間"
        }

        return "約\(hours)時間\(remainingMinutes)分"
    }

    @ViewBuilder
    private func featureRow(title: String, free: String, paid: String) -> some View {
        GridRow {
            Text(title)
                .font(.footnote)

            Text(free)
                .font(.footnote)
                .foregroundStyle(.secondary)

            Text(paid)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.accentColor)
        }
    }

    private func settingsInnerBackground<Content: View>(_ color: Color,
                                                        spacing: CGFloat = 12,
                                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: spacing) {
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(color)
        )
    }

    @ViewBuilder
    private func colorPaletteSection() -> some View {
        let freePalettes: [(String, Color)] = [
            ("ホワイト", Color.white),
            ("ダークブルー", Color(red: 0.1, green: 0.19, blue: 0.36)),
            ("ダークグレー", Color(red: 0.18, green: 0.18, blue: 0.2))
        ]

        let premiumPalettes: [(String, Color)] = [
            ("パステルブルー", Color(red: 0.73, green: 0.84, blue: 0.97)),
            ("パステルイエロー", Color(red: 0.99, green: 0.92, blue: 0.7)),
            ("パステルグリーン", Color(red: 0.76, green: 0.9, blue: 0.75))
        ]

        VStack(alignment: .leading, spacing: 16) {
            Text("無料プランで選択可能")
                .font(.footnote.weight(.semibold))

            paletteGrid(items: freePalettes, isLocked: false)

            Divider()

            Text("MAXプランで追加")
                .font(.footnote.weight(.semibold))

            paletteGrid(items: premiumPalettes, isLocked: true)

            Text("※ MAXプランに加入すると追加カラーが解放されます（現在はダミー表示です）。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func paletteGrid(items: [(String, Color)], isLocked: Bool) -> some View {
        let columns = [GridItem(.adaptive(minimum: 86), spacing: 12)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            ForEach(items, id: \.0) { item in
                paletteSwatch(name: item.0, color: item.1, isLocked: isLocked)
            }
        }
    }

    private func paletteSwatch(name: String, color: Color, isLocked: Bool) -> some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(color)
                    .frame(height: 48)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                    )
                    .overlay(
                        Group {
                            if isLocked {
                                ZStack {
                                    Rectangle()
                                        .fill(Color.primary.opacity(0.35))
                                        .frame(height: 2)
                                        .rotationEffect(.degrees(45))
                                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    Image(systemName: "lock.fill")
                                        .font(.caption)
                                        .foregroundStyle(Color.primary.opacity(0.85))
                                }
                            }
                        }
                    )
            }

            Text(name)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 86)
        .opacity(isLocked ? 0.6 : 1.0)
    }
}
