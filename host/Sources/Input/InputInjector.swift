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
    case scroll = "scroll"
}

struct RemoteInputEvent: Codable {
    let type: RemoteInputEventType
    var x: Double? = nil
    var y: Double? = nil
    var button: String? = nil // "left", "right"
    var state: String? = nil  // "down", "up"
    var keyCode: UInt16? = nil
    var pressure: Float? = nil
    var tilt: Float? = nil
    var clipboardText: String? = nil
    var timestamp: Double? = nil
    var deltaX: Double? = nil
    var deltaY: Double? = nil
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
        // Offload JSON decoding from the WebRTC DataChannel thread to prevent blocking network receives
        DispatchQueue.global(qos: .userInteractive).async {
            do {
                let decoder = JSONDecoder()
                let event = try decoder.decode(RemoteInputEvent.self, from: data)
                
                switch event.type {
                case .mouseMove:
                    // Preflight accessibility credentials for physical actions
                    guard AccessibilityHelper.isAccessibilityTrusted() else { return }
                    self.handleMouseMove(event)
                case .mouseClick:
                    guard AccessibilityHelper.isAccessibilityTrusted() else { return }
                    self.handleMouseClick(event)
                case .keyboard:
                    guard AccessibilityHelper.isAccessibilityTrusted() else { return }
                    self.handleKeyboard(event)
                case .pencil:
                    guard AccessibilityHelper.isAccessibilityTrusted() else { return }
                    self.handlePencil(event)
                case .clipboard:
                    self.handleClipboard(event)
                case .ping:
                    self.handlePing(event)
                case .pong:
                    break // Handled on Client side only
                case .scroll:
                    guard AccessibilityHelper.isAccessibilityTrusted() else { return }
                    self.handleScroll(event)
                }
            } catch {
                print("[Injector] Error decoding input payload: \(error.localizedDescription)")
            }
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
        cgEvent?.post(tap: CGEventTapLocation.cghidEventTap)
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
        
        cgEvent?.post(tap: CGEventTapLocation.cghidEventTap)
    }
    
    private func handleKeyboard(_ event: RemoteInputEvent) {
        guard let keyCode = event.keyCode, let stateStr = event.state else { return }
        let isDown = stateStr == "down"
        
        let cgEvent = CGEvent(
            keyboardEventSource: eventSource,
            virtualKey: keyCode,
            keyDown: isDown
        )
        
        cgEvent?.post(tap: CGEventTapLocation.cghidEventTap)
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
        
        cgEvent?.post(tap: CGEventTapLocation.cghidEventTap)
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
            timestamp: timestamp,
            deltaX: nil,
            deltaY: nil
        )
        
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(reply)
            onSendReply?(data)
        } catch {
            print("[Latency] Error encoding pong reply: \(error.localizedDescription)")
        }
    }
    
    private func handleScroll(_ event: RemoteInputEvent) {
        guard let deltaX = event.deltaX, let deltaY = event.deltaY else { return }
        
        // Multiplier to match trackpad natural scroll sensitivity
        let multiplier: Int32 = 5 
        let wheel1 = Int32(deltaY) * multiplier
        let wheel2 = Int32(deltaX) * multiplier
        
        let cgEvent = CGEvent(
            scrollWheelEvent2Source: eventSource,
            units: .pixel,
            wheelCount: 2,
            wheel1: wheel1,
            wheel2: wheel2,
            wheel3: 0
        )
        
        cgEvent?.post(tap: CGEventTapLocation.cghidEventTap)
    }
    
    // ─── Coordinator Math ───
    
    private func calculateScreenPoint(normX: Double, normY: Double) -> CGPoint {
        // Retrieve exact bounds of the primary active screen (which the Virtual Display was forced to become)
        let bounds = CGDisplayBounds(CGMainDisplayID())
        
        // normalized coordinates are 0.0 - 1.0 relative to display bounding box
        let screenX = bounds.minX + CGFloat(normX) * bounds.width
        let screenY = bounds.minY + CGFloat(normY) * bounds.height
        
        return CGPoint(x: screenX, y: screenY)
    }
}
