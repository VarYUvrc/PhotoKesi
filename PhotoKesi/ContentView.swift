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
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var libraryViewModel = PhotoLibraryViewModel()
    @StateObject private var permissionViewModel = PhotoAuthorizationViewModel()

    @State private var hasLoadedInitialThumbnails = false
    @State private var isDeleteSheetPresented = false
    @State private var isFullScreenPresented = false
    @State private var viewerSelectionIndex = 0
    @State private var isPerformingDeletion = false
    @State private var alertContext: MessageAlertContext?
    @State private var shouldNavigateToSettings = false
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
    @MainActor
    private func performDeletion() async {
        guard !isPerformingDeletion else { return }
        isPerformingDeletion = true
        defer { isPerformingDeletion = false }

        do {
            let deletedCount = try await libraryViewModel.deleteBucketItems()
            alertContext = MessageAlertContext(
                title: "削除が完了しました",
                message: "\(deletedCount)枚の写真を『最近削除した項目』に移動しました。写真アプリの『最近削除した項目』から復元できます。"
            )
        } catch let error as PhotoLibraryViewModel.DeletionError {
            alertContext = MessageAlertContext(
                title: "削除できません",
                message: error.errorDescription ?? "不明なエラーが発生しました。"
            )
        } catch {
            alertContext = MessageAlertContext(
                title: "削除できません",
                message: error.localizedDescription
            )
        }
    }

    private func advanceToNextGroup() {
        do {
            let didAdvance = try libraryViewModel.advanceToNextGroup()
            if didAdvance && libraryViewModel.remainingAdvanceQuota == 0 {
                alertContext = MessageAlertContext(
                    title: "本日の仕分け上限に達しました",
                    message: "無料プランの仕分け上限に達しました。翌日0:00にリセットされます。",
                    allowsUpgradeAction: true
                )
            }
        } catch let error as PhotoLibraryViewModel.GroupAdvanceError {
            alertContext = MessageAlertContext(
                title: "本日の上限に達しました",
                message: error.errorDescription ?? "無料プランの上限に達しました。翌日0:00にリセットされます。",
                allowsUpgradeAction: true
            )
        } catch {
            alertContext = MessageAlertContext(
                title: "仕分けできません",
                message: error.localizedDescription
            )
        }
    }

    func authorizedContent(showLimitedBanner: Bool) -> some View {
        NavigationStack {
            ZStack {
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

                NavigationLink(isActive: $shouldNavigateToSettings) {
                    SettingsView(libraryViewModel: libraryViewModel)
                } label: {
                    EmptyView()
                }
                .hidden()
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
        .onAppear {
            libraryViewModel.refreshAdvanceQuotaIfNeeded()
        }
        .sheet(isPresented: $isDeleteSheetPresented) {
            DeleteConfirmationSheet(
                groups: libraryViewModel.bucketItemGroups,
                isProcessing: isPerformingDeletion
            ) {
                Task { await performDeletion() }
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
        .alert(item: $alertContext) { context in
            if context.allowsUpgradeAction {
                return Alert(
                    title: Text(context.title),
                    message: Text(context.message),
                    primaryButton: .default(Text("OK")),
                    secondaryButton: .default(Text("上限を解除"), action: {
                        shouldNavigateToSettings = true
                    })
                )
            } else {
                return Alert(
                    title: Text(context.title),
                    message: Text(context.message),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                libraryViewModel.refreshAdvanceQuotaIfNeeded()
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
                advanceToNextGroup()
            } label: {
                Label("バケツ候補をバケツに送って次へ", systemImage: "trash.slash")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, metrics.buttonVerticalPadding * 0.8)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.green.opacity(0.85))

            HStack(spacing: metrics.buttonSpacing) {
                BucketBadgeButton(count: libraryViewModel.bucketItems.count) {
                    isDeleteSheetPresented = true
                }
                .disabled(!libraryViewModel.hasBucketItems)
                .opacity(libraryViewModel.hasBucketItems ? 1.0 : 0.5)

                Button {
                    isDeleteSheetPresented = true
                } label: {
                    Text("バケツを空にする")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, metrics.buttonVerticalPadding * 0.8)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .frame(maxWidth: .infinity)
                .disabled(!libraryViewModel.hasBucketItems)
                .opacity(libraryViewModel.hasBucketItems ? 1.0 : 0.5)
            }
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
                title: "バケツ送り候補",
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
                        Text(isUpperRow ? "残す写真なし。すべてバケツに送ります" : "バケツ送り候補なし")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    )
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: metrics.thumbnailSpacing) {
                        ForEach(thumbnails) { item in
                            PhotoThumbnailCard(
                                thumbnail: item.thumbnail,
                                isBest: item.thumbnail.isBest,
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
            skeletonRow(title: "バケツ送り候補")
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

    @State private var highResolutionImages: [String: UIImage] = [:]
    @State private var loadingIdentifiers: Set<String> = []
    @State private var zoomLevels: [String: CGFloat] = [:]
    @State private var isZoomed = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if thumbnails.isEmpty {
                ProgressView()
                    .tint(.white)
            } else {
                TabView(selection: $selectedIndex) {
                    ForEach(Array(thumbnails.enumerated()), id: \.0) { index, item in
                        ZStack {
                            ZoomableImageView(
                                image: highResolutionImages[item.id] ?? item.image,
                                zoomScale: zoomBinding(for: item.id)
                            )

                            if item.isBest {
                                BestBadge()
                                    .padding(.top, 24)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                            }

                            if loadingIdentifiers.contains(item.id) && highResolutionImages[item.id] == nil {
                                ProgressView()
                                    .tint(.white)
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
                    guard !isZoomed else { return }
                    let horizontal = value.translation.width
                    let vertical = value.translation.height
                    guard abs(vertical) > abs(horizontal) else { return }
                    if vertical > 90 {
                        onClose()
                    }
                }
        )
        .onChange(of: thumbnails) { newValue in
            if selectedIndex >= newValue.count {
                selectedIndex = max(0, newValue.count - 1)
            }
            synchronizeZoomLevels(with: newValue)
            prefetchHighResolutionImages(around: selectedIndex)
        }
        .onAppear {
            synchronizeZoomLevels(with: thumbnails)
            prefetchHighResolutionImages(around: selectedIndex)
        }
        .onChange(of: selectedIndex) { newValue in
            resetZoom(for: thumbnails, at: newValue)
            prefetchHighResolutionImages(around: newValue)
        }
    }

    @MainActor
    private func loadHighResolutionImage(for thumbnail: PhotoLibraryViewModel.AssetThumbnail) {
        if highResolutionImages[thumbnail.id] != nil || loadingIdentifiers.contains(thumbnail.id) {
            return
        }

        loadingIdentifiers.insert(thumbnail.id)

        Task {
            let scale = UIScreen.main.scale
            let screenSize = UIScreen.main.bounds.size
            let targetSize = CGSize(width: screenSize.width * scale, height: screenSize.height * scale)
            let result = await PhotoFullImageLoader.shared.image(for: thumbnail.asset,
                                                                 targetSize: targetSize,
                                                                 contentMode: .aspectFit)

            await MainActor.run {
                loadingIdentifiers.remove(thumbnail.id)
                if case let .success(image) = result {
                    highResolutionImages[thumbnail.id] = image
                    pruneCacheIfNeeded()
                }
            }
        }
    }

    @MainActor
    private func prefetchHighResolutionImages(around index: Int) {
        guard !thumbnails.isEmpty else { return }
        let nearby = [index - 1, index, index + 1]

        for position in nearby {
            guard thumbnails.indices.contains(position) else { continue }
            let thumbnail = thumbnails[position]
            loadHighResolutionImage(for: thumbnail)
        }
    }

    @MainActor
    private func pruneCacheIfNeeded() {
        let allowedIndices = Set((selectedIndex-2...selectedIndex+2).filter { thumbnails.indices.contains($0) })
        let allowedIDs: Set<String> = Set(allowedIndices.map { thumbnails[$0].id })

        for key in highResolutionImages.keys where !allowedIDs.contains(key) {
            highResolutionImages.removeValue(forKey: key)
        }
    }
    
    private func zoomBinding(for assetID: String) -> Binding<CGFloat> {
        Binding(
            get: { zoomLevels[assetID] ?? 1 },
            set: { newValue in
                zoomLevels[assetID] = newValue
                isZoomed = newValue > 1.01
                if newValue <= 1.01 {
                    zoomLevels[assetID] = 1
                }
            }
        )
    }

    private func synchronizeZoomLevels(with thumbnails: [PhotoLibraryViewModel.AssetThumbnail]) {
        let existingIDs = Set(thumbnails.map(\.id))
        zoomLevels = zoomLevels.filter { existingIDs.contains($0.key) }

        if let current = thumbnails[safe: selectedIndex] {
            zoomLevels[current.id] = 1
        }
        isZoomed = false
    }

    private func resetZoom(for thumbnails: [PhotoLibraryViewModel.AssetThumbnail], at index: Int) {
        guard let item = thumbnails[safe: index] else {
            isZoomed = false
            return
        }
        zoomLevels[item.id] = 1
        isZoomed = false
    }
}

private struct MessageAlertContext: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let allowsUpgradeAction: Bool

    init(title: String, message: String, allowsUpgradeAction: Bool = false) {
        self.title = title
        self.message = message
        self.allowsUpgradeAction = allowsUpgradeAction
    }
}

private struct DeleteConfirmationSheet: View {
    let groups: [PhotoLibraryViewModel.BucketGroup]
    let isProcessing: Bool
    let onConfirmDeletion: () -> Void
    @Environment(\.dismiss) private var dismiss

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private static let detailFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let intervalFormatter: DateIntervalFormatter = {
        let formatter = DateIntervalFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private var totalCount: Int {
        groups.reduce(into: 0) { partialResult, group in
            partialResult += group.items.count
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if totalCount > 0 {
                        Text("まとめて削除する写真 \(totalCount) 枚")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 4)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    if groups.isEmpty {
                        emptyState
                            .frame(maxWidth: .infinity, alignment: .center)
                    } else {
                        deletionInfoCard
                        ForEach(groups) { group in
                            groupSection(for: group)
                        }
                    }

                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .background(Color(uiColor: .systemGroupedBackground))
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
                    guard !isProcessing else { return }
                    onConfirmDeletion()
                    dismiss()
                } label: {
                    if isProcessing {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    } else {
                        Label(confirmButtonTitle, systemImage: "trash.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .padding()
                .disabled(isConfirmDisabled)
            }
        }
    }

    private var confirmButtonTitle: String {
        totalCount > 0 ? "削除確定 (\(totalCount)枚)" : "削除確定"
    }

    private var isConfirmDisabled: Bool {
        groups.isEmpty || isProcessing
    }

    @ViewBuilder
    private var deletionInfoCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "trash.circle")
                .font(.title3)
                .foregroundStyle(Color.secondary)
            Text("削除後の写真は写真アプリの『最近削除した項目』に移動し、30日以内なら復元できます。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Label("削除候補はありません", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
            Text("バケツに入れた写真がここにまとめて表示されます。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(32)
    }

    @ViewBuilder
    private func groupSection(for group: PhotoLibraryViewModel.BucketGroup) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("グループ \(group.displayIndex)")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                if let summary = dateSummary(for: group) {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                bucketRow(for: item)
                    .padding(.vertical, 4)

                if index < group.items.count - 1 {
                    Divider()
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color(uiColor: .separator), lineWidth: 1)
        )
        .transition(.opacity.combined(with: .scale))
    }

    @ViewBuilder
    private func bucketRow(for item: PhotoLibraryViewModel.AssetThumbnail) -> some View {
        HStack(spacing: 12) {
            Image(uiImage: item.image)
                .resizable()
                .scaledToFill()
                .frame(width: 54, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                if let creationDate = item.asset.creationDate {
                    Text(Self.detailFormatter.string(from: creationDate))
                } else {
                    Text("撮影日時不明")
                }
                Text(item.asset.localIdentifier)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private func dateSummary(for group: PhotoLibraryViewModel.BucketGroup) -> String? {
        let dates = group.items.compactMap { $0.asset.creationDate }
        guard let earliest = dates.min(), let latest = dates.max() else { return nil }

        if Calendar.current.isDate(earliest, inSameDayAs: latest) {
            let day = Self.dateFormatter.string(from: earliest)
            let start = Self.timeFormatter.string(from: earliest)
            let end = Self.timeFormatter.string(from: latest)
            if start == end {
                return "\(day) \(start)"
            } else {
                return "\(day) \(start)〜\(end)"
            }
        } else {
            return Self.intervalFormatter.string(from: earliest, to: latest)
        }
    }
}

private struct BucketBadgeButton: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 48, height: 48)
                    .overlay {
                        Image(systemName: "trash.fill")
                            .font(.headline)
                            .foregroundStyle(.white)
                    }

                if count > 0 {
                    BadgeView(count: count)
                        .offset(x: 12, y: -12)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("バケツに入っている写真")
        .accessibilityValue("\(count)枚")
    }

    private struct BadgeView: View {
        let count: Int

        var body: some View {
            Text(countDisplay)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(Color.red.opacity(0.9))
                )
        }

        private var countDisplay: String {
            count > 99 ? "99+" : String(count)
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
