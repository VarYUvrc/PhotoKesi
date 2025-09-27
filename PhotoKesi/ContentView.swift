//
//  ContentView.swift
//  PhotoKesi
//
//  Created by VarYU on 2025/09/27.
//

import SwiftUI

struct DummyPhotoCard: Identifiable {
    let id = UUID()
    let title: String
    let symbolName: String
    let baseColor: Color
    var isChecked: Bool
}

struct ContentView: View {
    @State private var photoCards: [DummyPhotoCard] = [
        DummyPhotoCard(title: "ベストショット", symbolName: "star.fill", baseColor: .orange, isChecked: true),
        DummyPhotoCard(title: "類似候補A", symbolName: "photo.fill", baseColor: .teal, isChecked: false),
        DummyPhotoCard(title: "類似候補B", symbolName: "camera.macro", baseColor: .purple, isChecked: false)
    ]
    @State private var isBucketAlertPresented = false
    @State private var isDeleteSheetPresented = false
    private let dummyBucketItems = [
        "未チェックの写真 #1",
        "未チェックの写真 #2",
        "未チェックの写真 #3"
    ]

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 24) {
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
                        ForEach($photoCards) { $card in
                            PhotoCardView(card: $card)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Button {
                    isBucketAlertPresented = true
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
                Text("S2 段階ではチェック済み以外をバケツに送る処理は未実装です。アラートが出れば UI イベントが通っています。")
            }
            .sheet(isPresented: $isDeleteSheetPresented) {
                DeleteConfirmationSheet(items: dummyBucketItems)
            }
        }
    }
}

private struct PhotoCardView: View {
    @Binding var card: DummyPhotoCard

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
                        Text(card.isChecked ? "チェック済み（残す）" : "未チェック（削除候補）")
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
            card.isChecked.toggle()
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: card.isChecked)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(card.title)
        .accessibilityValue(card.isChecked ? "チェック済み" : "未チェック")
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
    let items: [String]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("削除候補（ダミー）") {
                    ForEach(items, id: \.self) { item in
                        Label(item, systemImage: "photo")
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
                    dismiss()
                } label: {
                    Text("チェックの無い画像を削除（ダミー）")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .padding()
            }
        }
    }
}

#Preview {
    ContentView()
}
