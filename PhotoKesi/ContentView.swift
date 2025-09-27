//
//  ContentView.swift
//  PhotoKesi
//
//  Created by VarYU on 2025/09/27.
//

import SwiftUI
import Combine
import Photos

struct DummyPhotoCard: Identifiable {
    let id: UUID
    let title: String
    let symbolName: String
    let baseColor: Color
    var isChecked: Bool
    var isInBucket: Bool

    init(id: UUID = UUID(), title: String, symbolName: String, baseColor: Color, isChecked: Bool, isInBucket: Bool = false) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
        self.baseColor = baseColor
        self.isChecked = isChecked
        self.isInBucket = isInBucket
    }
}

struct BucketActionResult {
    let totalItems: Int
    let newlyAdded: Int
}

final class DummyGroupViewModel: ObservableObject {
    @Published private(set) var photoCards: [DummyPhotoCard]

    init(photoCards: [DummyPhotoCard] = [
        DummyPhotoCard(title: "ベストショット", symbolName: "star.fill", baseColor: .orange, isChecked: true),
        DummyPhotoCard(title: "類似候補A", symbolName: "photo.fill", baseColor: .teal, isChecked: false),
        DummyPhotoCard(title: "類似候補B", symbolName: "camera.macro", baseColor: .purple, isChecked: false)
    ]) {
        self.photoCards = photoCards
    }

    var bucketItems: [DummyPhotoCard] {
        photoCards.filter { $0.isInBucket }
    }

    func toggleCheck(for id: UUID) {
        guard let index = photoCards.firstIndex(where: { $0.id == id }) else { return }
        photoCards[index].isChecked.toggle()

        if photoCards[index].isChecked {
            photoCards[index].isInBucket = false
        }
    }

    func sendUncheckedToBucket() -> BucketActionResult {
        var newlyAdded = 0

        for index in photoCards.indices {
            if photoCards[index].isChecked {
                photoCards[index].isInBucket = false
            } else {
                if !photoCards[index].isInBucket {
                    newlyAdded += 1
                }
                photoCards[index].isInBucket = true
            }
        }

        return BucketActionResult(totalItems: bucketItems.count, newlyAdded: newlyAdded)
    }

    func clearBucketAfterDeletion() {
        for index in photoCards.indices {
            if photoCards[index].isInBucket {
                photoCards[index].isInBucket = false
                photoCards[index].isChecked = false
            }
        }
    }
}

struct ContentView: View {
    @StateObject private var viewModel = DummyGroupViewModel()
    @StateObject private var permissionViewModel = PhotoAuthorizationViewModel()
    @State private var isBucketAlertPresented = false
    @State private var bucketAlertMessage = ""
    @State private var isDeleteSheetPresented = false

    var body: some View {
        Group {
            switch permissionViewModel.status {
            case .authorized:
                authorizedContent(showLimitedBanner: false)
            case .limited:
                authorizedContent(showLimitedBanner: true)
            case .notDetermined:
                AuthorizationRequestView(onRequest: permissionViewModel.requestAuthorization)
            case .denied, .restricted:
                AuthorizationDeniedView(onOpenSettings: permissionViewModel.openSettings)
            @unknown default:
                AuthorizationDeniedView(onOpenSettings: permissionViewModel.openSettings)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: permissionViewModel.status)
    }

    private func handleBucketAction() {
        let result = viewModel.sendUncheckedToBucket()
        bucketAlertMessage = alertMessage(for: result)
        isBucketAlertPresented = true
    }

    private func alertMessage(for result: BucketActionResult) -> String {
        switch (result.totalItems, result.newlyAdded) {
        case (0, _):
            return "未チェックの写真がないため、バケツは空のままです。"
        case (_, 0):
            return "バケツに新しく追加される写真はありませんでした（計\(result.totalItems)枚）。"
        default:
            return "未チェックの写真\(result.newlyAdded)枚をバケツに入れました（計\(result.totalItems)枚）。"
        }
    }
}

private extension ContentView {
    @ViewBuilder
    func authorizedContent(showLimitedBanner: Bool) -> some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 24) {
                if showLimitedBanner {
                    LimitedAccessBanner(onOpenSettings: permissionViewModel.openSettings)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("仮の類似グループ")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("カードをタップしてチェックを切り替える挙動のみを確認するステップです。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(viewModel.photoCards) { card in
                            PhotoCardView(card: card) {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                                    viewModel.toggleCheck(for: card.id)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                Button {
                    handleBucketAction()
                } label: {
                    Text("チェック以外をバケツへ")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)

                Button {
                    isDeleteSheetPresented = true
                } label: {
                    Text("バケツを空にする（ダミー）")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)

                Spacer()
            }
            .padding(24)
            .navigationTitle("PhotoKesi")
            .alert("ダミーアクション", isPresented: $isBucketAlertPresented) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(bucketAlertMessage)
            }
            .sheet(isPresented: $isDeleteSheetPresented) {
                DeleteConfirmationSheet(items: viewModel.bucketItems) {
                    viewModel.clearBucketAfterDeletion()
                }
            }
        }
    }
}

private struct PhotoCardView: View {
    let card: DummyPhotoCard
    let onToggle: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(card.baseColor.gradient)
                .frame(width: 200, height: 260)
                .shadow(color: card.isChecked ? card.baseColor.opacity(0.35) : .black.opacity(0.15), radius: 12, x: 0, y: 6)
                .overlay(alignment: .bottom) {
                    VStack(spacing: 8) {
                        Text(card.title)
                            .font(.headline)
                            .foregroundStyle(.white)
                        Text(card.isChecked ? "チェック済み（残す）" : (card.isInBucket ? "バケツ候補" : "未チェック（削除候補）"))
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(.black.opacity(0.25))
                            )
                    }
                    .padding(.bottom, 16)
                }
                .overlay {
                    Image(systemName: card.symbolName)
                        .font(.system(size: 64, weight: .light))
                        .foregroundStyle(.white.opacity(0.8))
                        .offset(y: -28)
                }

            CheckBadge(isChecked: card.isChecked)
                .padding(16)
        }
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onTapGesture {
            onToggle()
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: card.isChecked)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(card.title)
        .accessibilityValue(card.isChecked ? "チェック済み" : (card.isInBucket ? "バケツ候補" : "未チェック"))
        .accessibilityAddTraits(card.isChecked ? [.isSelected] : [])
    }
}

private struct CheckBadge: View {
    let isChecked: Bool

    var body: some View {
        Label(isChecked ? "チェック済み" : "未チェック", systemImage: isChecked ? "checkmark.circle.fill" : "circle")
            .font(.headline)
            .labelStyle(.iconOnly)
            .padding(10)
            .background(
                Circle()
                    .fill(.ultraThinMaterial)
                    .shadow(color: .black.opacity(0.2), radius: 4)
            )
            .foregroundStyle(isChecked ? Color.green : Color.white.opacity(0.8))
    }
}

private struct DeleteConfirmationSheet: View {
    let items: [DummyPhotoCard]
    let onConfirmDeletion: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("削除候補（ダミー）") {
                    if items.isEmpty {
                        Label("削除候補はありません", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(items) { item in
                            Label(item.title, systemImage: "photo")
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("削除確認")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") {
                        dismiss()
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    onConfirmDeletion()
                    dismiss()
                } label: {
                    Text("チェックの無い画像を削除（ダミー）")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .padding()
                .disabled(items.isEmpty)
            }
        }
    }
}

private struct AuthorizationRequestView: View {
    let onRequest: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 72, weight: .light))
                .foregroundStyle(Color.accentColor)

            VStack(spacing: 12) {
                Text("写真ライブラリへのアクセスを許可してください")
                    .font(.title3)
                    .fontWeight(.semibold)
                Text("類似写真を束ねて整理するには、端末のフォトライブラリにアクセスする必要があります。許可後も限定アクセスから開始でき、後で設定から変更できます。")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                onRequest()
            } label: {
                Text("写真へのアクセスを許可")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(.indigo)

            Spacer()
        }
        .padding(32)
    }
}

private struct AuthorizationDeniedView: View {
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 64, weight: .regular))
                .foregroundStyle(.orange)

            VStack(spacing: 12) {
                Text("写真へのアクセスが許可されていません")
                    .font(.title3)
                    .fontWeight(.semibold)
                Text("設定アプリから PhotoKesi に写真ライブラリへのアクセスを許可してください。限定アクセスを選択してもアプリは利用できますが、完全アクセスにすると自動整理がよりスムーズになります。")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                onOpenSettings()
            } label: {
                Text("設定を開く")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(.indigo)

            Spacer()
        }
        .padding(32)
    }
}

private struct LimitedAccessBanner: View {
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "shield.lefthalf.filled")
                    .foregroundStyle(.yellow)
                Text("現在は限定アクセスで写真を利用しています")
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }

            Text("必要な写真だけを手動で選んでいる状態です。設定から PhotoKesi に完全アクセスを付与すると、毎回選び直す手間なく整理を進められます。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button(role: .none) {
                onOpenSettings()
            } label: {
                Text("設定で完全アクセスを許可")
                    .font(.footnote.weight(.semibold))
                    .padding(.vertical, 6)
                    .padding(.horizontal, 12)
                    .background(Capsule().fill(Color.indigo.opacity(0.15)))
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.quaternary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.indigo.opacity(0.35))
        )
    }
}

#Preview {
    ContentView()
}
