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
    func authorizedContent(showLimitedBanner: Bool) -> some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 24) {
                if showLimitedBanner {
                    LimitedAccessBanner(onOpenSettings: permissionViewModel.openSettings)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("最近の写真サムネイル")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("読み込み済みの写真から縮小サムネイルを即座に参照できるようになりました。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Group {
                    if libraryViewModel.isLoading {
                        ProgressView("写真を読み込み中...")
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 32)
                    } else if libraryViewModel.thumbnails.isEmpty {
                        ContentUnavailableView(
                            "サムネイルはまだありません",
                            systemImage: "photo",
                            description: Text("写真が読み込まれるとここに表示されます。")
                        )
                        .frame(maxWidth: .infinity, alignment: .center)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 16) {
                                ForEach(libraryViewModel.thumbnails) { thumbnail in
                                    PhotoThumbnailCard(thumbnail: thumbnail)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                Spacer()
            }
            .padding(24)
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

private struct PhotoThumbnailCard: View {
    let thumbnail: PhotoLibraryViewModel.AssetThumbnail

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .bottomLeading) {
                Image(uiImage: thumbnail.image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 200, height: 260)
                    .clipped()
                    .overlay(
                        LinearGradient(
                            colors: [Color.black.opacity(0.0), Color.black.opacity(0.55)],
                            startPoint: .center,
                            endPoint: .bottom
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .shadow(color: .black.opacity(0.2), radius: 12, x: 0, y: 6)

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
                        .padding([.leading, .bottom], 16)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        if let creationDate = thumbnail.asset.creationDate {
            return "写真、\(Self.dateFormatter.string(from: creationDate))"
        } else {
            return "写真"
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
