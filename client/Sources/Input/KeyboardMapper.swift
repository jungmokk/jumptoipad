import Foundation

/// KeyboardMapper translates USB HID keyboard scan codes (received from iPadOS UIKey events)
/// into macOS hardware-level virtual key codes (expected by macOS CGEvent).
class KeyboardMapper {
    
    /// Map USB HID usage code to macOS virtual keycode.
    /// Refer to standard USB HID Keyboard/Keypad usage IDs and <Carbon/HIToolbox/Events.h>
    static func mapUsbHidToMacVirtualKey(_ usbCode: UInt16) -> UInt16 {
        switch usbCode {
        // ─── Alphanumeric Keys ───
        case 4:   return 0   // A
        case 5:   return 11  // B
        case 6:   return 8   // C
        case 7:   return 2   // D
        case 8:   return 14  // E
        case 9:   return 3   // F
        case 10:  return 5   // G
        case 11:  return 4   // H
        case 12:  return 34  // I
        case 13:  return 38  // J
        case 14:  return 40  // K
        case 15:  return 37  // L
        case 16:  return 46  // M
        case 17:  return 45  // N
        case 18:  return 31  // O
        case 19:  return 35  // P
        case 20:  return 12  // Q
        case 21:  return 15  // R
        case 22:  return 1   // S
        case 23:  return 17  // T
        case 24:  return 32  // U
        case 25:  return 9   // V
        case 26:  return 13  // W
        case 27:  return 7   // X
        case 28:  return 16  // Y
        case 29:  return 6   // Z
        
        // ─── Number Keys ───
        case 30:  return 18  // 1
        case 31:  return 19  // 2
        case 32:  return 20  // 3
        case 33:  return 21  // 4
        case 34:  return 23  // 5
        case 35:  return 22  // 6
        case 36:  return 26  // 7
        case 37:  return 28  // 8
        case 38:  return 25  // 9
        case 39:  return 29  // 0
        
        // ─── Basic Control & Punctuation ───
        case 40:  return 36  // Return / Enter
        case 41:  return 53  // Escape
        case 42:  return 51  // Backspace / Delete
        case 43:  return 48  // Tab
        case 44:  return 49  // Spacebar
        case 45:  return 27  // - / _
        case 46:  return 24  // = / +
        case 47:  return 33  // [ / {
        case 48:  return 30  // ] / }
        case 49:  return 42  // \ / |
        case 51:  return 41  // ; / :
        case 52:  return 39  // ' / "
        case 53:  return 50  // ` / ~
        case 54:  return 43  // , / <
        case 55:  return 47  // . / >
        case 56:  return 44  // / / ?
        case 57:  return 57  // Caps Lock
        
        // ─── Function Keys ───
        case 58:  return 122 // F1
        case 59:  return 120 // F2
        case 60:  return 99  // F3
        case 61:  return 118 // F4
        case 62:  return 96  // F5
        case 63:  return 97  // F6
        case 64:  return 98  // F7
        case 65:  return 100 // F8
        case 66:  return 101 // F9
        case 67:  return 109 // F10
        case 68:  return 103 // F11
        case 69:  return 111 // F12
        
        // ─── Navigation & Arrow Keys ───
        case 79:  return 124 // Right Arrow
        case 80:  return 123 // Left Arrow
        case 81:  return 125 // Down Arrow
        case 82:  return 126 // Up Arrow
        
        // ─── Modifier Keys ───
        case 224: return 59  // Left Control
        case 225: return 56  // Left Shift
        case 226: return 58  // Left Option / Alt
        case 227: return 55  // Left Command (GUI)
        case 228: return 62  // Right Control
        case 229: return 60  // Right Shift
        case 230: return 61  // Right Option / Alt
        case 231: return 54  // Right Command (GUI)
            
        default:
            print("[KeyboardMapper] Unmapped USB code: \(usbCode), falling back to raw.")
            return usbCode // Fallback to raw if no mapping matches
        }
    }
}
