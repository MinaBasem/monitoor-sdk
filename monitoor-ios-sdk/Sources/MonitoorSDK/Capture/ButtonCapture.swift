import SwiftUI
import UIKit
import ObjectiveC

// MARK: - SwiftUI

/// Records a tap event every time the user taps the modified view.
///
/// Attach to any tappable view — `Button`, `Text`, custom views, etc.
///
/// ```swift
/// Button("Buy Premium") { purchase() }
///     .monitoorTap("buy_premium_tapped")
///
/// Button("Delete Account") { delete() }
///     .monitoorTap("delete_account_tapped", properties: ["source": "settings"])
/// ```
public struct MonitoorTapModifier: ViewModifier {
    let eventName: String
    let properties: [String: Any]

    public func body(content: Content) -> some View {
        // simultaneousGesture lets the button's own action fire too.
        content.simultaneousGesture(
            TapGesture().onEnded { _ in
                MonitoorCore.shared?.capture(name: eventName, properties: properties)
            }
        )
    }
}

public extension View {
    /// Tracks a tap on this view as a Monitoor event.
    ///
    /// - Parameters:
    ///   - eventName: The name that appears in your Monitoor dashboard.
    ///   - properties: Optional key-value pairs sent with the event.
    func monitoorTap(_ eventName: String, properties: [String: Any] = [:]) -> some View {
        modifier(MonitoorTapModifier(eventName: eventName, properties: properties))
    }
}

// MARK: - UIKit subclass

/// A `UIButton` subclass that automatically tracks taps as a Monitoor event.
///
/// Use instead of `UIButton` wherever you want tap tracking:
///
/// ```swift
/// let buyButton = MonitoorButton(eventName: "buy_premium_tapped")
/// let deleteButton = MonitoorButton(
///     eventName: "delete_account_tapped",
///     properties: ["source": "settings"]
/// )
/// ```
public final class MonitoorButton: UIButton {

    public var trackingEventName: String
    public var trackingProperties: [String: Any]

    public init(
        eventName: String,
        properties: [String: Any] = [:],
        frame: CGRect = .zero
    ) {
        self.trackingEventName  = eventName
        self.trackingProperties = properties
        super.init(frame: frame)
        addTarget(self, action: #selector(didTap), for: .touchUpInside)
    }

    required init?(coder: NSCoder) {
        self.trackingEventName  = "button_tapped"
        self.trackingProperties = [:]
        super.init(coder: coder)
        addTarget(self, action: #selector(didTap), for: .touchUpInside)
    }

    @objc private func didTap() {
        MonitoorCore.shared?.capture(name: trackingEventName, properties: trackingProperties)
    }
}

// MARK: - UIKit extension (for existing UIButton instances)

/// Tracks taps on any existing `UIButton` without subclassing.
///
/// ```swift
/// myButton.monitoor_trackTaps(eventName: "sign_in_tapped")
/// ```
public extension UIButton {
    func monitoor_trackTaps(eventName: String, properties: [String: Any] = [:]) {
        let tracker = ButtonActionTracker(eventName: eventName, properties: properties)
        // Retain the tracker for the lifetime of this button via an associated object.
        objc_setAssociatedObject(self, &ButtonActionTracker.key, tracker, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        addTarget(tracker, action: #selector(ButtonActionTracker.fire), for: .touchUpInside)
    }
}

// Helper object used as the UIButton action target.
private final class ButtonActionTracker: NSObject {
    static var key: UInt8 = 0

    let eventName: String
    let properties: [String: Any]

    init(eventName: String, properties: [String: Any]) {
        self.eventName  = eventName
        self.properties = properties
    }

    @objc func fire() {
        MonitoorCore.shared?.capture(name: eventName, properties: properties)
    }
}
