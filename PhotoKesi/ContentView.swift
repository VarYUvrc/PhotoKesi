//
//  ContentView.swift
//  PhotoKesi
//
//  Created by VarYU on 2025/09/27.
//

import SwiftUI
import Photos

struct ContentView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var libraryViewModel = PhotoLibraryViewModel()
    @StateObject private var permissionViewModel = PhotoAuthorizationViewModel()

    @State private var hasLoadedInitialThumbnails = false
    @State private var isDeleteSheetPresented = false
    @State private var isFullScreenPresented = false
    @State private var viewerSelectionIndex = 0
    private let currentModeTitle = "類似写真の整理モード"

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
    func authorizedContent(showLimitedBanner: Bool) -> some View {
        NavigationStack {
            GeometryReader { proxy in
                let metrics = LayoutMetrics(containerSize: proxy.size, dynamicType: dynamicTypeSize)

                VStack(alignment: .leading, spacing: metrics.sectionSpacing) {
                    if showLimitedBanner {
                        LimitedAccessBanner(onOpenSettings: permissionViewModel.openSettings)
                    }

                    photoGroupSection(metrics: metrics)
                }
                .padding(metrics.containerPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(uiColor: .systemBackground))
            }
            .navigationTitle(currentModeTitle)
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
        .sheet(isPresented: $isDeleteSheetPresented) {
            DeleteConfirmationSheet(items: libraryViewModel.bucketItems) {
                libraryViewModel.clearBucketAfterDeletion()
                libraryViewModel.advanceToNextGroup()
            }
        }
        .fullScreenCover(isPresented: $isFullScreenPresented) {
            FullScreenPhotoViewer(
                thumbnails: libraryViewModel.currentGroup,
                selectedIndex: $viewerSelectionIndex,
                onClose: { isFullScreenPresented = false },
                onToggleCheck: { id in
                    libraryViewModel.toggleCheck(for: id)
                }
            )
        }
        .onChange(of: libraryViewModel.currentGroup) { newGroup in
            guard !newGroup.isEmpty else {
                isFullScreenPresented = false
                viewerSelectionIndex = 0
                return
            }
            if viewerSelectionIndex >= newGroup.count {
                viewerSelectionIndex = max(0, newGroup.count - 1)
            }
        }
    }

    func photoGroupSection(metrics: LayoutMetrics) -> some View {
        VStack(alignment: .leading, spacing: metrics.sectionSpacing) {
            if libraryViewModel.groupCount > 0 {
                Text("現在のグループ: \(libraryViewModel.currentGroupIndex + 1) / \(libraryViewModel.groupCount) ・ 時間幅 \(libraryViewModel.groupingWindowMinutes)分")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }

            Group {
                if libraryViewModel.isLoading && !libraryViewModel.didFinishInitialLoad {
                    PhotoBoardSkeletonView(metrics: metrics)
                } else if libraryViewModel.currentGroup.isEmpty {
                    ContentUnavailableView(
                        "サムネイルはまだありません",
                        systemImage: "photo",
                        description: Text("写真が読み込まれるとここに表示されます。")
                    )
                    .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    PhotoGroupBoard(
                        group: libraryViewModel.currentGroup,
                        metrics: metrics,
                        onToggleCheck: { id in
                            libraryViewModel.toggleCheck(for: id)
                        },
                        onSetCheck: { id, isChecked in
                            libraryViewModel.setCheck(isChecked, for: id)
                        },
                        onOpenViewer: { index in
                            viewerSelectionIndex = index
                            isFullScreenPresented = true
                        }
                    )
                }
            }

            if !libraryViewModel.currentGroup.isEmpty {
                actionButtons(metrics: metrics)
            }
        }
    }

    func actionButtons(metrics: LayoutMetrics) -> some View {
        VStack(alignment: .leading, spacing: metrics.buttonSpacing) {
            Button {
                if libraryViewModel.bucketItems.isEmpty {
                    libraryViewModel.advanceToNextGroup()
                } else {
                    isDeleteSheetPresented = true
                }
            } label: {
                Label("仕分けを完了して次のグループへ", systemImage: "trash.slash")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, metrics.buttonVerticalPadding)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.green.opacity(0.85))
        }
    }

}

private struct PhotoGroupBoard: View {
    let group: [PhotoLibraryViewModel.AssetThumbnail]
    let metrics: LayoutMetrics
    let onToggleCheck: (String) -> Void
    let onSetCheck: (String, Bool) -> Void
    let onOpenViewer: (Int) -> Void

    private struct IndexedThumbnail: Identifiable {
        let index: Int
        let thumbnail: PhotoLibraryViewModel.AssetThumbnail
        var id: String { thumbnail.id }
    }

    private var checked: [IndexedThumbnail] {
        group.enumerated().compactMap { index, item in
            item.isChecked ? IndexedThumbnail(index: index, thumbnail: item) : nil
        }
    }

    private var unchecked: [IndexedThumbnail] {
        group.enumerated().compactMap { index, item in
            item.isChecked ? nil : IndexedThumbnail(index: index, thumbnail: item)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.boardSpacing) {
            boardSection(
                title: "残す写真",
                systemImage: "checkmark.circle.fill",
                thumbnails: checked,
                isUpperRow: true
            )

            boardSection(
                title: "バケツ",
                systemImage: "trash",
                thumbnails: unchecked,
                isUpperRow: false
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.18), value: group)
    }

    @ViewBuilder
    private func boardSection(title: String,
                              systemImage: String,
                              thumbnails: [IndexedThumbnail],
                              isUpperRow: Bool) -> some View {
        VStack(alignment: .leading, spacing: metrics.rowSpacing) {
            HStack(spacing: 8) {
                let accentColor = isUpperRow ? Color.green : Color.red
                Image(systemName: systemImage)
                    .foregroundStyle(accentColor)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Color.primary)
            }

            if thumbnails.isEmpty {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
                    .frame(height: metrics.placeholderHeight)
                    .overlay(
                        Text(isUpperRow ? "チェックが付いた写真はここに並びます" : "バケツの写真はここに並びます")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    )
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: metrics.thumbnailSpacing) {
                        ForEach(thumbnails) { item in
                            PhotoThumbnailCard(
                                thumbnail: item.thumbnail,
                                isBest: item.index == 0,
                                cardSize: metrics.cardSize,
                                onOpenViewer: { onOpenViewer(item.index) },
                                onToggleCheck: { onToggleCheck(item.thumbnail.id) },
                                onSwipeUp: {
                                    onSetCheck(item.thumbnail.id, true)
                                },
                                onSwipeDown: {
                                    onSetCheck(item.thumbnail.id, false)
                                },
                                isToggleDisabled: false,
                                allowSwipeUp: !isUpperRow,
                                allowSwipeDown: isUpperRow
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}

private struct PhotoBoardSkeletonView: View {
    let metrics: LayoutMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.boardSpacing) {
            skeletonRow(title: "残す写真")
            skeletonRow(title: "バケツ")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .redacted(reason: .placeholder)
    }

    @ViewBuilder
    private func skeletonRow(title: String) -> some View {
        VStack(alignment: .leading, spacing: metrics.rowSpacing) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.stack.fill")
                Text(title)
                    .font(.headline)
            }
            LazyHStack(spacing: metrics.thumbnailSpacing) {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.secondary.opacity(0.12))
                        .frame(width: metrics.cardSize.width, height: metrics.cardSize.height)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

private struct PhotoThumbnailCard: View {
    let thumbnail: PhotoLibraryViewModel.AssetThumbnail
    let isBest: Bool
    let cardSize: CGSize
    let onOpenViewer: () -> Void
    let onToggleCheck: () -> Void
    let onSwipeUp: () -> Void
    let onSwipeDown: () -> Void
    let isToggleDisabled: Bool
    let allowSwipeUp: Bool
    let allowSwipeDown: Bool

    var body: some View {
        let dragGesture = DragGesture(minimumDistance: 30)
            .onEnded { value in
                if value.translation.height < -60, allowSwipeUp {
                    onSwipeUp()
                } else if value.translation.height > 60, allowSwipeDown {
                    onSwipeDown()
                }
            }

        ZStack(alignment: .topTrailing) {
            Image(uiImage: thumbnail.image)
                .resizable()
                .scaledToFill()
                .frame(width: cardSize.width, height: cardSize.height)
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
                    if let creationDate = thumbnail.asset.creationDate {
                        Text(PhotoThumbnailCard.dateFormatter.string(from: creationDate))
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
                .overlay(alignment: .top) {
                    if isBest {
                        BestBadge()
                            .padding(.top, 12)
                    }
                }
                .shadow(color: thumbnail.isChecked ? .white.opacity(0.25) : .black.opacity(0.2), radius: 12, x: 0, y: 6)

            CheckBadgeButton(isChecked: thumbnail.isChecked, isDisabled: isToggleDisabled, action: onToggleCheck)
                .padding(16)
        }
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onTapGesture(perform: onOpenViewer)
        .gesture(dragGesture)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: thumbnail.isChecked)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("写真カード")
        .accessibilityValue(thumbnail.isChecked ? "チェック済み" : (thumbnail.isInBucket ? "バケツ候補" : "バケツ"))
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

private struct CheckBadgeButton: View {
    let isChecked: Bool
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isChecked ? "checkmark.circle.fill" : "trash.fill")
                .font(.headline)
                .padding(10)
                .background(
                    Circle()
                        .fill(isChecked ? Color.white.opacity(0.2) : Color.red.opacity(0.85))
                        .shadow(color: .black.opacity(0.25), radius: 4)
                )
                .foregroundStyle(isChecked ? Color.green : Color.white)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.55 : 1)
        .accessibilityLabel(isChecked ? "バケツに入れる" : "チェック済みにする")
    }
}

private struct BestBadge: View {
    var body: some View {
        Text("best✨")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(Color.yellow.opacity(0.85))
            )
            .foregroundStyle(.black)
            .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
    }
}

private struct FullScreenPhotoViewer: View {
    let thumbnails: [PhotoLibraryViewModel.AssetThumbnail]
    @Binding var selectedIndex: Int
    let onClose: () -> Void
    let onToggleCheck: (String) -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if thumbnails.isEmpty {
                ProgressView()
                    .tint(.white)
            } else {
                TabView(selection: $selectedIndex) {
                    ForEach(Array(thumbnails.enumerated()), id: \.0) { index, item in
                        GeometryReader { geometry in
                            Image(uiImage: item.image)
                                .resizable()
                                .scaledToFit()
                                .frame(width: geometry.size.width, height: geometry.size.height)
                                .clipped()
                                .overlay(alignment: .top) {
                                    if index == 0 {
                                        BestBadge()
                                            .padding(.top, 24)
                                    }
                                }
                        }
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }

            VStack {
                HStack {
                    Button(action: onClose) {
                        Image(systemName: "chevron.left")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(12)
                            .background(
                                Circle()
                                    .fill(Color.white.opacity(0.08))
                            )
                    }
                    .accessibilityLabel("一覧に戻る")

                    Spacer()

                    if let current = thumbnails[safe: selectedIndex] {
                        CheckBadgeButton(
                            isChecked: current.isChecked,
                            isDisabled: false,
                            action: {
                                onToggleCheck(current.id)
                            }
                        )
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 32)

                Spacer()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 40)
                .onEnded { value in
                    if abs(value.translation.width) < 80 && value.translation.height < -90 {
                        onClose()
                    }
                }
        )
        .onChange(of: thumbnails) { newValue in
            if selectedIndex >= newValue.count {
                selectedIndex = max(0, newValue.count - 1)
            }
        }
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
                    Label("削除確定", systemImage: "trash.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .padding()
                .disabled(items.isEmpty)
            }
        }
    }
}


private struct LayoutMetrics {
    let cardSize: CGSize
    let sectionSpacing: CGFloat
    let boardSpacing: CGFloat
    let rowSpacing: CGFloat
    let thumbnailSpacing: CGFloat
    let containerPadding: EdgeInsets
    let buttonVerticalPadding: CGFloat
    let buttonSpacing: CGFloat
    let placeholderHeight: CGFloat

    init(containerSize: CGSize, dynamicType: DynamicTypeSize) {
        let horizontalPadding: CGFloat = containerSize.width <= 360 ? 16 : 24
        containerPadding = EdgeInsets(top: 24, leading: horizontalPadding, bottom: 24, trailing: horizontalPadding)

        let isAccessibility = dynamicType.isAccessibilitySize

        sectionSpacing = isAccessibility ? 18 : 20
        boardSpacing = isAccessibility ? 14 : 18
        rowSpacing = isAccessibility ? 10 : 12
        thumbnailSpacing = isAccessibility ? 12 : 16
        buttonVerticalPadding = isAccessibility ? 12 : 14
        buttonSpacing = isAccessibility ? 10 : 12

        let availableWidth = max(160, containerSize.width - horizontalPadding * 2)
        var cardWidth = min(220, availableWidth * 0.55)
        cardWidth = max(140, cardWidth)

        var cardHeight = cardWidth * 1.08
        let maxHeight = max(150, containerSize.height * 0.36)
        cardHeight = min(cardHeight, maxHeight)
        cardHeight = max(140, cardHeight)

        if isAccessibility {
            cardWidth = max(140, min(cardWidth, availableWidth * 0.5))
            cardHeight = max(150, min(cardHeight, containerSize.height * 0.34))
        }

        cardSize = CGSize(width: cardWidth, height: cardHeight)
        placeholderHeight = cardHeight + 12
    }
}

private extension DynamicTypeSize {
    var isAccessibilitySize: Bool {
        switch self {
        case .accessibility1, .accessibility2, .accessibility3, .accessibility4, .accessibility5:
            return true
        default:
            return false
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

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

#Preview {
    ContentView()
}
