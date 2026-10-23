import Foundation

/// Night Shift, True Tone and Dark Mode. Each value is nil when the Mac does not offer the feature.
enum SystemControls {
    static var nightShift: Bool? {
        var on: ObjCBool = false
        return BDNightShiftGet(&on, nil) ? on.boolValue : nil
    }

    /// Night Shift warmth, 0...1.
    static var nightShiftStrength: Float? {
        var s: Float = 0
        return BDNightShiftGet(nil, &s) ? s : nil
    }

    static var trueTone: Bool? {
        var on: ObjCBool = false
        return BDTrueToneGet(&on) ? on.boolValue : nil
    }

    static var darkMode: Bool? {
        switch BDDarkModeGet() {
        case -1: return nil
        case let v: return v == 1
        }
    }

    static func setNightShift(_ on: Bool) throws {
        guard BDNightShiftSetEnabled(on) else { throw DisplayError.message("Night Shift is not available.") }
    }

    static func setNightShiftStrength(_ s: Float) throws {
        guard s.isFinite else { throw DisplayError.message("Night Shift strength must be a number from 0 to 1.") }
        guard BDNightShiftSetStrength(min(max(s, 0), 1)) else {
            throw DisplayError.message("Night Shift is not available.")
        }
    }

    static func setTrueTone(_ on: Bool) throws {
        guard BDTrueToneSetEnabled(on) else { throw DisplayError.message("True Tone is not available.") }
    }

    static func setDarkMode(_ on: Bool) throws {
        guard BDDarkModeSet(on) else { throw DisplayError.message("Dark Mode control is not available.") }
    }
}
