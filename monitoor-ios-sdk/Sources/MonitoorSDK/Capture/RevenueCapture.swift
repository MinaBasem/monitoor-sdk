import Foundation
import StoreKit

final class RevenueCapture {
    private let eventCapture: EventCapture
    private var observerTask: Task<Void, Never>?

    init(eventCapture: EventCapture) {
        self.eventCapture = eventCapture
    }

    func startObserving() {
        observerTask = Task { [weak self] in
            for await result in Transaction.updates {
                guard case .verified(let tx) = result else { continue }
                self?.trackTransaction(tx)
            }
        }
    }

    func stopObserving() {
        observerTask?.cancel()
        observerTask = nil
    }

    func trackManual(
        productId: String,
        amount: Double,
        currency: String,
        type: RevenueType,
        transactionId: String
    ) {
        let props: [String: Any] = [
            "product_id":     productId,
            "amount":         amount,
            "currency":       currency,
            "type":           type.rawValue,
            "transaction_id": transactionId,
        ]
        eventCapture.enqueue(name: "$revenue", type: "event", properties: props)
    }

    // MARK: - Private

    private func trackTransaction(_ tx: Transaction) {
        let productType: String
        switch tx.productType {
        case .autoRenewable:    productType = "subscription"
        case .nonConsumable:    productType = "one_time"
        case .consumable:       productType = "consumable"
        default:                productType = "one_time"
        }

        var props: [String: Any] = [
            "product_id":     tx.productID,
            "type":           productType,
            "transaction_id": String(tx.id),
        ]

        if #available(iOS 16.0, *) {
            if let price = tx.price {
                props["amount"] = NSDecimalNumber(decimal: price).doubleValue
            }
            if let currency = tx.currency {
                props["currency"] = currency.identifier
            }
        }

        eventCapture.enqueue(name: "$revenue", type: "event", properties: props)
    }
}

public enum RevenueType: String, Sendable {
    case subscription = "subscription"
    case oneTime      = "one_time"
    case consumable   = "consumable"
}
