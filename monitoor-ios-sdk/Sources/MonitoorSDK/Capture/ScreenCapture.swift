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

        // Only consider classes defined in the app's own bundle.
        guard Bundle(for: cls) == Bundle.main else { return }

        // Use the Objective-C runtime name to check the module prefix.
        // App-defined classes look like "AppName.MyViewController".
        // SwiftUI-generated specialisations look like
        // "AppName.(unknown context).(PresentationHostingController<...>)"
        // or just "_UIKitNavigationController".
        let runtimeName = NSStringFromClass(cls)

        // Exclude anything that looks like a generic specialisation:
        // PresentationHosting<AnyView>, NavigationStackHosting<AnyView>, etc.
        guard !runtimeName.contains("<") else { return }

        // Exclude internal names that start with an underscore.
        let shortName = runtimeName.components(separatedBy: ".").last ?? runtimeName
        guard !shortName.hasPrefix("_") else { return }

        // Exclude SwiftUI-reserved prefixes: "UI...", "SwiftUI...", "Hosting...",
        // "Presentation...", "Navigation..." when they originate from system internals.
        let systemPrefixes = ["UI", "SwiftUI", "Hosting", "Presentation", "Navigation",
                              "Input", "Keyboard", "Remote", "Alert", "Action"]
        guard !systemPrefixes.contains(where: { shortName.hasPrefix($0) }) else { return }

        let screenName = shortName
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
