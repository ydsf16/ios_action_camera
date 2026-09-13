// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct ProUpgradeView: View {
    var freeRecording: (() -> Void)? = nil
    var unlocked: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var access = ProAccess.shared
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    Image(systemName: access.hasPro ? "checkmark.seal.fill" : "sparkles")
                        .font(.system(size: 48)).foregroundStyle(AppTheme.accent).padding(.top, 24)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("RoamShot Pro").font(.largeTitle.bold())
                        Text(access.hasPro ? "已永久解锁" : "让精彩继续").font(.title2.weight(.semibold))
                        Text("永久解锁超过 1 分钟的视频录制。一次购买，无订阅。")
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        Label("免费：每段最长 1 分钟，不限次数", systemImage: "video")
                        Label("Pro：解锁长时间连续录制", systemImage: "infinity")
                        Label("全画质、全部稳定参数，无水印", systemImage: "slider.horizontal.3")
                        Label("素材保存在本机，原片随时导出", systemImage: "internaldrive")
                    }.font(.subheadline)
                    if access.hasPro {
                        Button("继续") { dismiss(); unlocked?() }.buttonStyle(PrimaryActionStyle())
                    } else {
                        Button {
                            Task { await access.purchase() }
                        } label: {
                            HStack {
                                if access.busy || access.loadingProduct { ProgressView() }
                                Text(access.product.map { "\($0.displayPrice) · 永久解锁" } ?? "正在获取价格")
                            }.frame(maxWidth: .infinity)
                        }.buttonStyle(PrimaryActionStyle()).disabled(access.busy || access.product == nil)
                        HStack {
                            Button("恢复购买") { Task { await access.restore() } }
                            Spacer()
                            if access.product == nil { Button("重试") { Task { await access.loadProduct() } } }
                        }.font(.subheadline).disabled(access.busy || access.loadingProduct)
                    }
                    if let freeRecording, !access.hasPro {
                        Button("免费录制 1 分钟") { dismiss(); freeRecording() }
                            .frame(maxWidth: .infinity).buttonStyle(.bordered)
                            .disabled(access.busy)
                    }
                    if let message = access.message { Text(message).font(.footnote).foregroundStyle(AppTheme.amber) }
                    Text("免费录制到 1 分钟会自动停止并保存，稳定处理和导出不再收费。长视频需要更多存储空间和处理时间。")
                        .font(.footnote).foregroundStyle(.secondary)
                    HStack {
                        Link("隐私政策", destination: AppLinks.privacy)
                        Spacer()
                        Link("使用条款", destination: AppLinks.terms)
                    }.font(.footnote)
                }.padding(24)
            }.background(AppTheme.background)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }.tint(AppTheme.accent)
            .interactiveDismissDisabled(access.busy)
            .task { await access.refresh(); if !access.hasPro { await access.loadProduct() } }
            .onChange(of: access.hasPro) { _, value in if value { dismiss(); unlocked?() } }
    }
}

enum AppLinks {
    static let privacy = URL(string: "https://ydsf16.github.io/ios_action_camera/privacy.html")!
    static let terms = URL(string: "https://ydsf16.github.io/ios_action_camera/terms.html")!
    static let support = URL(string: "https://ydsf16.github.io/ios_action_camera/")!
}
