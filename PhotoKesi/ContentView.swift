//
//  ContentView.swift
//  PhotoKesi
//
//  Created by VarYU on 2025/09/27.
//

import SwiftUI
import Photos

struct ContentView: View {
    @StateObject private var libraryViewModel = PhotoLibraryViewModel()
    @StateObject private var permissionViewModel = PhotoAuthorizationViewModel()
    @State private var hasLoadedInitialThumbnails = false
    @State private var isBucketAlertPresented = false
    @State private var bucketAlertMessage = ""
    @State private var isDeleteSheetPresented = false

    var body: some View {
        Group {
            switch permissionViewModel.status {
            case .authorized:
                authorizedFlow(showLimitedBanner: false)
            case .limited:
                authorizedFlow(showLimitedBanner: true)
            case .notDetermined:
                AuthorizationRequestView(onRequest: permissionViewModel.requestAuthorization)
            case .denied, .restricted:
                AuthorizationDeniedView(onOpenSettings: permissionViewModel.openSettings)
            @unknown default:
                AuthorizationDeniedView(onOpenSettings: permissionViewModel.openSettings)
            }
        }
        .task(id: permissionViewModel.status) {
            await handleAuthorizationStatusChange(permissionViewModel.status)
        }
        .animation(.easeInOut(duration: 0.22), value: permissionViewModel.status)
    }

    private func handleAuthorizationStatusChange(_ status: PHAuthorizationStatus) async {
        switch status {
        case .authorized, .limited:
            guard !hasLoadedInitialThumbnails else { return }
            hasLoadedInitialThumbnails = true
            await libraryViewModel.loadThumbnails()
        default:
            hasLoadedInitialThumbnails = false
            libraryViewModel.reset()
        }
    }
}

private extension ContentView {
    @ViewBuilder
    func authorizedFlow(showLimitedBanner: Bool) -> some View {
        if libraryViewModel.didFinishInitialLoad {
            authorizedContent(showLimitedBanner: showLimitedBanner)
        } else {
            InitialLoadingView(isLimitedAccess: showLimitedBanner,
                               isLoading: libraryViewModel.isLoading)
        }
    }

    func authorizedContent(showLimitedBanner: Bool) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if showLimitedBanner {
                        LimitedAccessBanner(onOpenSettings: permissionViewModel.openSettings)
                    }

                    photoGroupSection
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("PhotoKesi")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsView(libraryViewModel: libraryViewModel)
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("設定を開く")
                }
            }
        }
        .alert("バケツに送信", isPresented: $isBucketAlertPresented) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(bucketAlertMessage)
        }
        .sheet(isPresented: $isDeleteSheetPresented) {
            DeleteConfirmationSheet(items: libraryViewModel.bucketItems) {
                libraryViewModel.clearBucketAfterDeletion()
            }
        }
    }

    var photoGroupSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("最近の写真サムネイル")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("撮影時刻の近さでまとめた暫定グループを表示しています。チェックの切り替えやバケツ操作の流れを確認できます。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if libraryViewModel.groupCount > 0 {
                    Text("現在のグループ: \(libraryViewModel.currentGroupIndex + 1) / \(libraryViewModel.groupCount) ・ 時間幅 \(libraryViewModel.groupingWindowMinutes)分")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
            }

            Group {
                if libraryViewModel.isLoading {
                    ProgressView("写真を読み込み中...")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 32)
                } else if libraryViewModel.currentGroup.isEmpty {
                    ContentUnavailableView(
                        "サムネイルはまだありません",
                        systemImage: "photo",
                        description: Text("写真が読み込まれるとここに表示されます。")
                    )
                    .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            ForEach(libraryViewModel.currentGroup) { thumbnail in
                                PhotoThumbnailCard(thumbnail: thumbnail) {
                                    libraryViewModel.toggleCheck(for: thumbnail.id)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            if !libraryViewModel.currentGroup.isEmpty {
                actionButtons
            }
        }
    }

    var actionButtons: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                Text("バケツを空にする（削除確認）")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .disabled(libraryViewModel.bucketItems.isEmpty)
        }
    }

    func handleBucketAction() {
        let result = libraryViewModel.sendUncheckedToBucket()
        bucketAlertMessage = alertMessage(for: result)
        isBucketAlertPresented = true
    }

    private func alertMessage(for result: PhotoLibraryViewModel.BucketActionResult) -> String {
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

private struct PhotoThumbnailCard: View {
    let thumbnail: PhotoLibraryViewModel.AssetThumbnail
    let onToggle: () -> Void

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(uiImage: thumbnail.image)
                .resizable()
                .scaledToFill()
                .frame(width: 200, height: 260)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(
                    LinearGradient(
                        colors: [Color.black.opacity(0.0), Color.black.opacity(0.55)],
                        startPoint: .center,
                        endPoint: .bottom
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                )
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 6) {
                        if let creationDate = thumbnail.asset.creationDate {
                            Text(Self.dateFormatter.string(from: creationDate))
                                .font(.footnote)
                                .fontWeight(.medium)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule()
                                        .fill(Color.white.opacity(0.25))
                                )
                        }
                    }
                    .padding([.leading, .bottom], 16)
                }
                .overlay(alignment: .bottomTrailing) {
                    if thumbnail.isInBucket {
                        BucketBadge()
                            .padding([.trailing, .bottom], 16)
                    }
                }
                .shadow(color: thumbnail.isChecked ? .white.opacity(0.25) : .black.opacity(0.2), radius: 12, x: 0, y: 6)

            CheckBadge(isChecked: thumbnail.isChecked)
                .padding(16)
        }
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onTapGesture {
            onToggle()
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: thumbnail.isChecked)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("写真カード")
        .accessibilityValue(thumbnail.isChecked ? "チェック済み" : (thumbnail.isInBucket ? "バケツ候補" : "未チェック"))
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

private struct BucketBadge: View {
    var body: some View {
        Text("バケツ候補")
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(Color.red.opacity(0.65))
            )
    }
}

private struct DeleteConfirmationSheet: View {
    let items: [PhotoLibraryViewModel.AssetThumbnail]
    let onConfirmDeletion: () -> Void
    @Environment(\.dismiss) private var dismiss

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        NavigationStack {
            List {
                Section("削除候補（ダミー）") {
                    if items.isEmpty {
                        Label("削除候補はありません", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(items) { item in
                            HStack(spacing: 12) {
                                Image(uiImage: item.image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 48, height: 48)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                VStack(alignment: .leading, spacing: 4) {
                                    if let creationDate = item.asset.creationDate {
                                        Text(Self.dateFormatter.string(from: creationDate))
                                    } else {
                                        Text("撮影日時不明")
                                    }
                                    Text(item.asset.localIdentifier)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
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

private struct InitialLoadingView: View {
    let isLimitedAccess: Bool
    let isLoading: Bool

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            ProgressView()
                .progressViewStyle(.circular)
                .tint(.indigo)
                .scaleEffect(1.4)

            VStack(spacing: 12) {
                Text("写真ライブラリを準備中です")
                    .font(.title3)
                    .fontWeight(.semibold)

                Text(isLimitedAccess ? "選択された写真の読み込みとサムネイル生成を開始しています。完了するとメイン画面に切り替わります。" : "端末内の最近の写真を読み込み、サムネイル生成とキャッシュの準備を進めています。完了するとメイン画面に切り替わります。")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if !isLoading {
                Text("まもなく表示されます…")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }

            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
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
