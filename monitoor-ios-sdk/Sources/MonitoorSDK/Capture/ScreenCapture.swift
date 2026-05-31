import UIKit
import SwiftUI
import ObjectiveC

// MARK: - UIKit automatic screen tracking via method swizzling

private let swizzleOnce: Void = {
    let cls = UIViewController.self
    guard
        let original = class_getInstanceMethod(cls, #selector(UIViewController.viewDidAppear(_:))),
        let swizzled = class_getInstanceMethod(cls, #selector(UIViewController.monitoor_viewDidAppear(_:)))
    else { return }
    method_exchangeImplementations(original, swizzled)
}()

extension UIViewController {
    static func monitoor_installSwizzle() {
        _ = swizzleOnce
    }

    @objc func monitoor_viewDidAppear(_ animated: Bool) {
        monitoor_viewDidAppear(animated) // calls original implementation due to swizzle

        // Only track view controllers defined in the app's own bundle.
        // This filters out every internal Apple/SwiftUI class (UIKitNavigationController,
        // _UIHostingController, etc.) without needing an explicit exclusion list.
        guard Bundle(for: type(of: self)) == Bundle.main else { return }

        let screenName = String(describing: type(of: self))
            .replacingOccurrences(of: "ViewController", with: "")
            .replacingOccurrences(of: "Controller", with: "")
            .replacingOccurrences(of: "VC", with: "")

        MonitoorCore.shared?.captureScreen(screenName, properties: [:])
    }
}

// MARK: - SwiftUI modifier

public struct MonitoorScreenViewModifier: ViewModifier {
    let screenName: String
    let properties: [String: Any]

    public func body(content: Content) -> some View {
        content.onAppear {
            MonitoorCore.shared?.captureScreen(screenName, properties: properties)
        }
    }
}

public extension View {
    func monitoorScreen(_ name: String, properties: [String: Any] = [:]) -> some View {
        modifier(MonitoorScreenViewModifier(screenName: name, properties: properties))
    }
}
