import CoreGraphics
import Foundation
import IOKit

/// GPU temporal dithering on Apple silicon: the `enableDither` property of the display's
/// IOMobileFramebufferShim, written with IORegistryEntrySetCFProperty.
enum Dithering {
    private static let key = "enableDither"
    private static let defaultsKey = "ditheringByDisplay"

    /// The framebuffer service driving `display`, matched by EDID identity
    /// (external) or by being the internal panel (built-in). Caller releases it.
    static func framebuffer(for display: CGDirectDisplayID) -> io_service_t? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMobileFramebufferShim"),
                                           &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        let builtin = CGDisplayIsBuiltin(display) != 0
        let vendor = Int(CGDisplayVendorNumber(display))
        let model = Int(CGDisplayModelNumber(display))
        let serial = Int(CGDisplaySerialNumber(display))
        var fallback: io_service_t?
        while case let service = IOIteratorNext(iterator), service != 0 {
            let external = property(service, "external") as? Bool ?? false
            // The internal panel's framebuffer is the one not marked external; its
            // DisplayAttributes are not always published, so do not require them.
            let product = (property(service, "DisplayAttributes") as? [String: Any])?["ProductAttributes"]
                as? [String: Any]
            guard property(service, key) != nil, builtin || product != nil else {
                IOObjectRelease(service)
                continue
            }
            let matches: Bool
            if builtin {
                matches = !external
            } else {
                let product = product!
                matches = external
                    && product["LegacyManufacturerID"] as? Int == vendor
                    && product["ProductID"] as? Int == model
                    && (serial == 0 || product["SerialNumber"] as? Int == serial)
            }
            if matches {
                if let fallback { IOObjectRelease(fallback) }
                return service
            }
            // Same vendor/model but different serial: keep as a fallback for
            // monitors whose EDID serial differs from what CoreGraphics reports.
            if !builtin, external, fallback == nil,
               product?["LegacyManufacturerID"] as? Int == vendor, product?["ProductID"] as? Int == model {
                fallback = service
            } else {
                IOObjectRelease(service)
            }
        }
        return fallback
    }

    static func isSupported(_ display: CGDirectDisplayID) -> Bool {
        guard let fb = framebuffer(for: display) else { return false }
        IOObjectRelease(fb)
        return true
    }

    static func isEnabled(_ display: CGDirectDisplayID) -> Bool? {
        guard let fb = framebuffer(for: display) else { return nil }
        defer { IOObjectRelease(fb) }
        return property(fb, key) as? Bool
    }

    static func set(_ on: Bool, for display: CGDirectDisplayID, persistentKey: String?) throws {
        guard let fb = framebuffer(for: display) else {
            throw DisplayError.message("GPU dithering control is not available for this display (Apple silicon only).")
        }
        defer { IOObjectRelease(fb) }
        let kr = IORegistryEntrySetCFProperty(fb, key as CFString, on ? kCFBooleanTrue : kCFBooleanFalse)
        guard kr == KERN_SUCCESS else {
            throw DisplayError.message("Could not change GPU dithering (IOKit error 0x\(String(kr, radix: 16))).")
        }
        if let persistentKey { Store.setValue(on, in: defaultsKey, for: persistentKey) }
    }

    /// Reapply the saved dithering choice, e.g. after the display reconnects.
    static func restore(_ display: Display) throws {
        guard let saved: Bool = Store.value(in: defaultsKey, for: display.persistentKey),
              isEnabled(display.id) != saved else { return }
        try set(saved, for: display.id, persistentKey: nil)
    }

    static func savedValue(for key: String) -> Bool? { Store.value(in: defaultsKey, for: key) }

    private static func property(_ service: io_service_t, _ name: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, name as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
