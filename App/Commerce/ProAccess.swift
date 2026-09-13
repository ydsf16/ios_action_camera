// SPDX-License-Identifier: GPL-3.0-or-later
import StoreKit
import SwiftUI

@MainActor
final class ProAccess: ObservableObject {
    static let shared = ProAccess()
    static let productID = "com.grape.RoamShot.pro.lifetime"
    @Published private(set) var hasPro = false
    @Published private(set) var product: Product?
    @Published private(set) var busy = false
    @Published private(set) var loadingProduct = false
    @Published private(set) var message: String?
    private var updates: Task<Void, Never>?
    private var refreshRevision = 0

    init() {
        // Install the listener before reading entitlements, including Ask to Buy approval
        // and transactions completed on another device. No entitlement in UserDefaults.
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                guard case let .verified(transaction) = result,
                      transaction.productID == Self.productID else { continue }
                await self.refresh()
                await transaction.finish()
            }
        }
        Task { await refresh() }
    }
    deinit { updates?.cancel() }

    @discardableResult func refresh() async -> Bool {
        refreshRevision += 1
        let revision = refreshRevision
        var entitled = false
        for await result in Transaction.currentEntitlements {
            if case let .verified(transaction) = result,
               transaction.productID == Self.productID,
               transaction.productType == .nonConsumable,
               transaction.revocationDate == nil, !transaction.isUpgraded {
                entitled = true
            }
        }
        if revision == refreshRevision { hasPro = entitled }
        return entitled
    }
    func loadProduct() async {
        guard !loadingProduct else { return }
        loadingProduct = true
        defer { loadingProduct = false }
        do {
            product = try await Product.products(for: [Self.productID]).first { $0.type == .nonConsumable }
            message = product == nil ? "暂时无法获取购买项目，请稍后重试。已购买的用户可恢复购买。" : nil
        } catch { message = "无法连接 App Store，请检查网络后重试。" }
    }
    func purchase() async {
        guard !busy, let product, !hasPro else { return }
        busy = true; message = nil
        defer { busy = false }
        do {
            switch try await product.purchase() {
            case let .success(result):
                guard case let .verified(transaction) = result,
                      transaction.productID == Self.productID,
                      transaction.productType == .nonConsumable,
                      transaction.revocationDate == nil else {
                    message = "购买凭证尚未通过验证，请稍后恢复购买。"; return
                }
                await refresh()
                await transaction.finish()
                if !hasPro { message = "购买已完成，权益正在同步，请稍后恢复购买。" }
            case .pending: message = "购买正在等待批准。批准后会自动解锁，原片已保留。"
            case .userCancelled: break
            @unknown default: message = "购买尚未完成，请稍后重试。"
            }
        } catch { message = "购买未完成，请检查网络或稍后重试。" }
    }
    func restore() async {
        guard !busy else { return }
        busy = true; message = nil
        defer { busy = false }
        do {
            // Explicit user action only; normal startup uses the local verified entitlement.
            try await AppStore.sync()
            await refresh()
            message = hasPro ? "已恢复永久解锁。" : "当前 Apple 账户没有此购买记录。"
        } catch { message = "恢复购买未完成，请稍后重试。" }
    }

}
