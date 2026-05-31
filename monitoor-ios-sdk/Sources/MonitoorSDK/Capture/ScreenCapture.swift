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

        let cls = type(of: self)

        // Only consider classes compiled into the app bundle.
        guard Bundle(for: cls) == Bundle.main else { return }

        // String(describing:) gives the clean class name without module prefix or parentheses,
        // unlike NSStringFromClass which wraps SwiftUI generics in "(unknown context at ...)".
        let className = String(describing: cls)

        // Drop anything with generic type parameters — every SwiftUI hosting controller
        // uses generics: PresentationHostingController<AnyView>, etc.
        guard !className.contains("<") else { return }

        // Drop class names that contain known system/SwiftUI substrings.
        let noiseSubstrings = ["Hosting", "UIKit", "SwiftUI", "Presentation",
                               "Input", "Keyboard", "Remote", "Accessibility",
                               "Window", "Scene", "Navigation", "Transition",
                               "Gesture", "Popover", "Sheet"]
        guard !noiseSubstrings.contains(where: { className.contains($0) }) else { return }

        // Drop classes whose names start with system-reserved prefixes.
        let noisePrefixes = ["UI", "_", "NS", "AV", "MK", "SK", "AR", "CL"]
        guard !noisePrefixes.contains(where: { className.hasPrefix($0) }) else { return }

        let screenName = className
            .replacingOccurrences(of: "ViewController", with: "")
            .replacingOccurrences(of: "Controller", with: "")
            .replacingOccurrences(of: "VC", with: "")

        guard !screenName.isEmpty else { return }

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
