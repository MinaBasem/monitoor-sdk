import Foundation
import UIKit

struct DeviceInfo {
    let appVersion: String
    let build: String
    let osVersion: String
    let model: String
    let locale: String
    let timezone: String
    let bundleId: String

    static func current() -> DeviceInfo {
        let bundle = Bundle.main
        let appVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build      = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        let bundleId   = bundle.bundleIdentifier ?? "unknown"
        let osVersion  = UIDevice.current.systemVersion
        let model      = Self.modelIdentifier()
        let locale     = Locale.current.identifier
        let timezone   = TimeZone.current.identifier

        return DeviceInfo(
            appVersion: appVersion,
            build: build,
            osVersion: "iOS \(osVersion)",
            model: model,
            locale: locale,
            timezone: timezone,
            bundleId: bundleId
        )
    }

    func asEventContext() -> EventContext {
        EventContext(
            appVersion: appVersion,
            build: build,
            os: osVersion,
            device: model,
            locale: locale,
            timezone: timezone,
            bundleId: bundleId
        )
    }

    private static func modelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }
}
