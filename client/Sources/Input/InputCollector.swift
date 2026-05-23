import Foundation
import SwiftUI

/// InputEvent encapsulates touch, mouse, and Apple Pencil events in a strict JSON-serializable schema.
enum InputEventType: String, Codable {
    case mouseMove = "mouse_move"
    case mouseClick = "mouse_click"
    case keyboard = "key"
    case pencil = "pencil"
    case clipboard = "clipboard"
    case ping = "ping"
    case pong = "pong"
    case scroll = "scroll"
}

struct InputEvent: Codable {
    let type: InputEventType
    
    // Position coordinates normalized between 0.0 and 1.0 (highly portable across varying display aspect ratios)
    var x: Double?
    var y: Double?
    
    // Mouse specific details
    var button: String? // "left", "right", "middle"
    var state: String?  // "down", "up", "click"
    var deltaX: Double? // For scrolling
    var deltaY: Double? // For scrolling
    
    // Keyboard specific details
    var keyCode: UInt16?
    var keyChar: String?
    
    // Apple Pencil specific details
    var pressure: Float?
    var tilt: Float? // Altitude angle in radians
    
    // Clipboard syncing details
    var clipboardText: String?
    
    // Latency measuring details
    var timestamp: Double?
}

/// InputCollector gathers touch, trackpad, pencil, and keyboard events from the iPadOS client UI,
/// serializes them into JSON packages, and passes them to the coordinator's DataChannel.
class InputCollector: ObservableObject {
    
    private let onSendEvent: (Data, Bool) -> Void
    
    // Throttling for high-frequency input events (e.g., 120Hz iPad Pro displays)
    private var lastMouseMoveTime: TimeInterval = 0
    private var lastPencilMoveTime: TimeInterval = 0
    private let throttleInterval: TimeInterval = 1.0 / 60.0 // Limit to 60 FPS
    
    /// Initialize with a data transmitter callback (usually pointing to ClientConnectionCoordinator.sendInputData)
    init(onSendEvent: @escaping (Data, Bool) -> Void) {
        self.onSendEvent = onSendEvent
    }
    
    /// Handle touchscreen tap/click events
    func sendTapEvent(at point: CGPoint, in size: CGSize, isRightClick: Bool = false) {
        let normX = Double(point.x / size.width)
        let normY = Double(point.y / size.height)
        
        let clickDown = InputEvent(
            type: .mouseClick,
            x: normX,
            y: normY,
            button: isRightClick ? "right" : "left",
            state: "down"
        )
        
        let clickUp = InputEvent(
            type: .mouseClick,
            x: normX,
            y: normY,
            button: isRightClick ? "right" : "left",
            state: "up"
        )
        
        serializeAndSend(clickDown, reliable: true)
        
        // Brief hardware simulation gap
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.serializeAndSend(clickUp, reliable: true)
        }
    }
    
    /// Handle real-time trackpad / drag movements
    func sendMouseMoveEvent(at point: CGPoint, in size: CGSize) {
        let now = Date().timeIntervalSince1970
        guard now - lastMouseMoveTime >= throttleInterval else { return }
        lastMouseMoveTime = now
        
        let normX = min(max(Double(point.x / size.width), 0.0), 1.0)
        let normY = min(max(Double(point.y / size.height), 0.0), 1.0)
        
        let moveEvent = InputEvent(
            type: .mouseMove,
            x: normX,
            y: normY
        )
        
        serializeAndSend(moveEvent, reliable: false)
    }
    
    /// Handle Apple Pencil high precision coordinates and pressure sensitivity
    func sendPencilEvent(at point: CGPoint, in size: CGSize, pressure: Float, tilt: Float) {
        let now = Date().timeIntervalSince1970
        guard now - lastPencilMoveTime >= throttleInterval else { return }
        lastPencilMoveTime = now
        
        let normX = min(max(Double(point.x / size.width), 0.0), 1.0)
        let normY = min(max(Double(point.y / size.height), 0.0), 1.0)
        
        let pencilEvent = InputEvent(
            type: .pencil,
            x: normX,
            y: normY,
            pressure: pressure,
            tilt: tilt
        )
        
        serializeAndSend(pencilEvent, reliable: false)
    }
    
    /// Handle physical key inputs from Magic Keyboard
    func sendKeyboardEvent(keyCode: UInt16, isDown: Bool) {
        let keyEvent = InputEvent(
            type: .keyboard,
            state: isDown ? "down" : "up",
            keyCode: keyCode
        )
        
        serializeAndSend(keyEvent, reliable: true)
    }
    
    /// Send local clipboard data
    func sendClipboardEvent(text: String) {
        let clipboardEvent = InputEvent(
            type: .clipboard,
            clipboardText: text
        )
        serializeAndSend(clipboardEvent, reliable: true)
    }
    
    /// Handle trackpad/mouse scroll wheel events
    func sendScrollEvent(deltaX: Double, deltaY: Double) {
        let scrollEvent = InputEvent(
            type: .scroll,
            deltaX: deltaX,
            deltaY: deltaY
        )
        // Scroll should be unreliable so it doesn't block if there's network jitter
        serializeAndSend(scrollEvent, reliable: false)
    }
    
    /// Send round-trip ping for latency measurement
    func sendPingEvent(timestamp: Double) {
        let pingEvent = InputEvent(
            type: .ping,
            timestamp: timestamp
        )
        serializeAndSend(pingEvent, reliable: true)
    }
    
    // ─── Private Serializer ───
    
    private func serializeAndSend(_ event: InputEvent, reliable: Bool = true) {
        // Offload JSON serialization from the main UI thread to prevent micro-stutters at 120Hz
        DispatchQueue.global(qos: .userInteractive).async {
            do {
                let encoder = JSONEncoder()
                let data = try encoder.encode(event)
                self.onSendEvent(data, reliable)
            } catch {
                print("[InputCollector] Error serializing input package: \(error.localizedDescription)")
            }
        }
    }
}
