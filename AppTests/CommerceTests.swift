// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import StoreKitTest
import StoreKit
@testable import RoamShot

@MainActor final class CommerceTests: XCTestCase {
    func testPurchaseRestoreRefundAndPendingApproval() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "RoamShot", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.disableDialogs = true
        try XCTSkipUnless(session.disableDialogs, "The StoreKit test runtime rejected configuration; run CommerceQA in Xcode and check StoreKitTest service availability.")
        session.clearTransactions()
        defer { session.clearTransactions(); session.resetToDefaultState() }
        let access = ProAccess()
        await access.refresh()
        XCTAssertFalse(access.hasPro)
        XCTAssertEqual(RecordingLimitPolicy.maximumDuration(hasPro: access.hasPro), 60)
        await access.loadProduct()
        let product = try XCTUnwrap(access.product)
        XCTAssertEqual(product.id, ProAccess.productID)
        XCTAssertEqual(product.price, 20)
        XCTAssertEqual(product.type, .nonConsumable)
        await access.purchase()
        XCTAssertTrue(access.hasPro, access.message ?? "Purchase should unlock")
        XCTAssertNil(RecordingLimitPolicy.maximumDuration(hasPro: access.hasPro))
        let restored = ProAccess()
        await restored.restore()
        XCTAssertTrue(restored.hasPro, restored.message ?? "Restore should unlock")
        let transaction = try XCTUnwrap(session.allTransactions().first)
        try session.refundTransaction(identifier: transaction.identifier)
        try await waitFor { !access.hasPro && !restored.hasPro }
        XCTAssertEqual(RecordingLimitPolicy.maximumDuration(hasPro: access.hasPro), 60)
        session.clearTransactions()
        session.askToBuyEnabled = true
        await access.purchase()
        XCTAssertFalse(access.hasPro)
        XCTAssertTrue(access.message?.contains("等待批准") == true)
        let pending = try XCTUnwrap(session.allTransactions().first)
        try session.approveAskToBuyTransaction(identifier: pending.identifier)
        try await waitFor { access.hasPro }
        XCTAssertNil(RecordingLimitPolicy.maximumDuration(hasPro: access.hasPro))
    }
    private func waitFor(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("StoreKit transaction listener did not update within 10 seconds")
    }
}
