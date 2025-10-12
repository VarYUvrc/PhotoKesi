import SwiftUI

struct SettingsView: View {
    @ObservedObject var libraryViewModel: PhotoLibraryViewModel
    @Environment(\.dismiss) private var dismiss

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

        Form {
            Section("グルーピングの設定") {
                VStack(alignment: .leading, spacing: 12) {
                    Stepper(value: bindingForGroupingWindow(), in: minMinutes...maxMinutes, step: stepMinutes) {
                        Text("時間幅: \(formattedWindow(minutes: libraryViewModel.groupingWindowMinutes))")
                    }

                    Slider(value: bindingForSlider(), in: Double(minMinutes)...Double(maxMinutes), step: Double(stepMinutes))
                        .accessibilityLabel("グループの対象時間幅")

                    Text("撮影時刻が指定した時間幅内に収まる写真を同じグループとして扱います。幅を広げるとグループは少なく、狭めると細かく分割されます。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("設定")
        .navigationBarTitleDisplayMode(.inline)
        .simultaneousGesture(swipeGesture)
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
}
