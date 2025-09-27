//
//  PhotoAuthorizationViewModel.swift
//  PhotoKesi
//
//  Created by Codex on 2025/09/27.
//

import Foundation
import Photos
import Combine
#if canImport(UIKit)
import UIKit
#endif

final class PhotoAuthorizationViewModel: ObservableObject {
    @Published private(set) var status: PHAuthorizationStatus

    private var cancellables = Set<AnyCancellable>()

    init() {
        status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        observeAppLifecycle()
    }

    var canAccessLibrary: Bool {
        switch status {
        case .authorized, .limited:
            return true
        default:
            return false
        }
    }

    var isLimited: Bool {
        status == .limited
    }

    func requestAuthorization() {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] newStatus in
            DispatchQueue.main.async {
                self?.status = newStatus
            }
        }
    }

    func refreshStatus() {
        DispatchQueue.main.async {
            self.status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        }
    }

    func openSettings() {
        #if canImport(UIKit)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        DispatchQueue.main.async {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
        #endif
    }

    private func observeAppLifecycle() {
        #if canImport(UIKit)
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshStatus()
            }
            .store(in: &cancellables)
        #endif
    }
}
