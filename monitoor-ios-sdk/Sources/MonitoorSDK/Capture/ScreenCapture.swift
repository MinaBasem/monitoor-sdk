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
        // Skip system containers that aren't real screens.
        let excluded: Set<String> = [
            "UINavigationController",
            "UITabBarController",
            "UIPageViewController",
            "UISplitViewController",
            "UIInputViewController",
            "UIAlertController",
        ]
        let className = String(describing: type(of: self))
        guard !excluded.contains(className) else { return }

        let screenName = className
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
