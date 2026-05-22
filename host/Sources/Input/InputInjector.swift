import Foundation
import CoreGraphics
import AppKit

/// Host side deserialization models matching Client InputCollector
enum RemoteInputEventType: String, Codable {
    case mouseMove = "mouse_move"
    case mouseClick = "mouse_click"
    case keyboard = "key"
    case pencil = "pencil"
    case clipboard = "clipboard"
    case ping = "ping"
    case pong = "pong"
}

struct RemoteInputEvent: Codable {
    let type: RemoteInputEventType
    let x: Double?
    let y: Double?
    let button: String? // "left", "right"
    let state: String?  // "down", "up"
    let keyCode: UInt16?
    let pressure: Float?
    let tilt: Float?
    let clipboardText: String?
    let timestamp: Double?
}

/// InputInjector decodes the JSON packet received from the DataChannel,
/// converts normalized coordinates to screen pixel coordinates, and injects
/// hardware events directly into macOS CoreGraphics (CGEvent) at the HID layer.
class InputInjector {
    
    private let eventSource = CGEventSource(stateID: .combinedSessionState)
    
    /// Transmit reply events back to the client (such as pong responses)
    var onSendReply: ((Data) -> Void)?
    
    /// Parse and inject remote event package
    func injectEvent(data: Data) {
        do {
            let decoder = JSONDecoder()
            let event = try decoder.decode(RemoteInputEvent.self, from: data)
            
            switch event.type {
            case .mouseMove:
                // Preflight accessibility credentials for physical actions
                guard AccessibilityHelper.isAccessibilityTrusted() else { return }
                handleMouseMove(event)
            case .mouseClick:
                guard AccessibilityHelper.isAccessibilityTrusted() else { return }
                handleMouseClick(event)
            case .keyboard:
                guard AccessibilityHelper.isAccessibilityTrusted() else { return }
                handleKeyboard(event)
            case .pencil:
                guard AccessibilityHelper.isAccessibilityTrusted() else { return }
                handlePencil(event)
            case .clipboard:
                handleClipboard(event)
            case .ping:
                handlePing(event)
            case .pong:
                break // Handled on Client side only
            }
        } catch {
            print("[Injector] Error decoding input payload: \(error.localizedDescription)")
        }
    }
    
    // ─── Input Handlers ───
    
    private func handleMouseMove(_ event: RemoteInputEvent) {
        guard let normX = event.x, let normY = event.y else { return }
        let point = calculateScreenPoint(normX: normX, normY: normY)
        
        // Post moving event
        let cgEvent = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left
        )
        cgEvent?.post(tap: .cghidEventTap)
    }
    
    private func handleMouseClick(_ event: RemoteInputEvent) {
        guard let normX = event.x, let normY = event.y, 
              let buttonStr = event.button, let stateStr = event.state else { return }
        
        let point = calculateScreenPoint(normX: normX, normY: normY)
        let isLeft = buttonStr == "left"
        let isDown = stateStr == "down"
        
        let type: CGEventType
        let button: CGMouseButton
        
        if isLeft {
            type = isDown ? .leftMouseDown : .leftMouseUp
            button = .left
        } else {
            type = isDown ? .rightMouseDown : .rightMouseUp
            button = .right
        }
        
        let cgEvent = CGEvent(
            mouseEventSource: eventSource,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: button
        )
        
        cgEvent?.post(tap: .cghidEventTap)
    }
    
    private func handleKeyboard(_ event: RemoteInputEvent) {
        guard let keyCode = event.keyCode, let stateStr = event.state else { return }
        let isDown = stateStr == "down"
        
        let cgEvent = CGEvent(
            keyboardEventSource: eventSource,
            virtualKey: keyCode,
            keyDown: isDown
        )
        
        cgEvent?.post(tap: .cghidEventTap)
    }
    
    private func handlePencil(_ event: RemoteInputEvent) {
        guard let normX = event.x, let normY = event.y else { return }
        let point = calculateScreenPoint(normX: normX, normY: normY)
        
        // Apple Pencil generates mouse movement with optional pressure attributes
        let cgEvent = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left
        )
        
        if let pressure = event.pressure {
            // Emulate tablet stylus pressure field
            cgEvent?.setIntegerValueField(.tabletEventPointPressure, value: Int64(pressure * 1000))
        }
        
        cgEvent?.post(tap: .cghidEventTap)
    }
    
    private func handleClipboard(_ event: RemoteInputEvent) {
        guard let text = event.clipboardText else { return }
        print("[Clipboard] Received remote clipboard data: \(text)")
        
        // Write to macOS Pasteboard thread-safely on the main thread
        DispatchQueue.main.async {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
    }
    
    private func handlePing(_ event: RemoteInputEvent) {
        guard let timestamp = event.timestamp else { return }
        
        // Echo back as pong event
        let reply = RemoteInputEvent(
            type: .pong,
            x: nil, y: nil, button: nil, state: nil, keyCode: nil, pressure: nil, tilt: nil,
            clipboardText: nil,
            timestamp: timestamp
        )
        
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(reply)
            onSendReply?(data)
        } catch {
            print("[Latency] Error encoding pong reply: \(error.localizedDescription)")
        }
    }
    
    // ─── Coordinator Math ───
    
    private func calculateScreenPoint(normX: Double, normY: Double) -> CGPoint {
        // Retrieve size of the primary active screen
        let screenFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        
        // normalized coordinates are 0.0 - 1.0 relative to display bounding box
        let screenX = CGFloat(normX) * screenFrame.width
        let screenY = CGFloat(normY) * screenFrame.height
        
        return CGPoint(x: screenX, y: screenY)
    }
}
