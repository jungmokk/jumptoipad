import SwiftUI
import WebRTC

#if canImport(UIKit)
import UIKit

/// A high-performance, Metal-accelerated SwiftUI Video Renderer view wrapper.
/// Securely wraps WebRTC's native `RTCMTLVideoView` and captures remote inputs.
struct VideoRendererView: UIViewRepresentable {
    
    let videoTrack: RTCVideoTrack?
    let inputCollector: InputCollector
    
    func makeUIView(context: Context) -> TouchInputContainerView {
        let container = TouchInputContainerView(frame: .zero)
        container.inputCollector = inputCollector
        return container
    }
    
    func updateUIView(_ uiView: TouchInputContainerView, context: Context) {
        uiView.inputCollector = inputCollector
        
        // Handle dynamic changes in the video track
        if let track = videoTrack {
            print("[Render] Binding incoming RTCVideoTrack '\(track.trackId)' to Metal view.")
            track.add(uiView.videoView)
        } else {
            print("[Render] No active RTCVideoTrack. Clearing renderer view.")
        }
    }
    
    static func dismantleUIView(_ uiView: TouchInputContainerView, coordinator: ()) {
        uiView.removeFromSuperview()
    }
}

/// Custom UIView container that houses the WebRTC Metal view and intercepts
/// Custom UIView container that houses the WebRTC Metal view and intercepts
/// touch, drag, Apple Pencil (pressure & tilt), and Magic Keyboard input events.
class TouchInputContainerView: UIView, UIPointerInteractionDelegate {
    
    var inputCollector: InputCollector?
    let videoView = RTCMTLVideoView(frame: .zero)
    
    private var touchStartPoint: CGPoint = .zero
    private var hasMovedTouch: Bool = false
    private let moveThreshold: CGFloat = 8.0
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        
        // Add RTCMTLVideoView as subview
        videoView.videoContentMode = .scaleAspectFill
        videoView.clipsToBounds = true
        videoView.isUserInteractionEnabled = false
        videoView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(videoView)
        
        NSLayoutConstraint.activate([
            videoView.topAnchor.constraint(equalTo: topAnchor),
            videoView.bottomAnchor.constraint(equalTo: bottomAnchor),
            videoView.leadingAnchor.constraint(equalTo: leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        
        // Allow user interaction
        isUserInteractionEnabled = true
        
        // Listen to tap gesture to become first responder for keyboard input
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTapToFocus))
        tapGesture.cancelsTouchesInView = false
        addGestureRecognizer(tapGesture)
        
        // Hover Gesture for Trackpad/Mouse movement without clicking
        let hoverGesture = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        addGestureRecognizer(hoverGesture)
        
        // Pan Gesture specifically for Trackpad Two-finger scrolling / Mouse Wheel
        let scrollGesture = UIPanGestureRecognizer(target: self, action: #selector(handleScrollPan(_:)))
        scrollGesture.allowedScrollTypesMask = .all
        scrollGesture.allowedTouchTypes = [] // IMPORTANT: Ignore normal touch dragging
        addGestureRecognizer(scrollGesture)
        
        // Pointer Interaction to hide iPad native cursor
        let pointerInteraction = UIPointerInteraction(delegate: self)
        addInteraction(pointerInteraction)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    @objc private func handleTapToFocus() {
        if !isFirstResponder {
            becomeFirstResponder()
            print("[TouchInput] Container became first responder for keyboard inputs.")
        }
    }
    
    // ─── First Responder for Keyboard Capture ───
    override var canBecomeFirstResponder: Bool {
        return true
    }
    
    // ─── Pointer Interaction (Hide native cursor) ───
    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        // Completely hide the iPadOS cursor so it doesn't overlap with the Mac cursor
        return UIPointerStyle.hidden()
    }
    
    // ─── Trackpad / Mouse Specific Handling ───
    
    @objc private func handleHover(_ gesture: UIHoverGestureRecognizer) {
        guard let inputCollector = inputCollector else { return }
        let location = gesture.location(in: self)
        let size = self.bounds.size
        
        if gesture.state == .changed || gesture.state == .began {
            inputCollector.sendMouseMoveEvent(at: location, in: size)
        }
    }
    
    @objc private func handleScrollPan(_ gesture: UIPanGestureRecognizer) {
        guard let inputCollector = inputCollector else { return }
        
        let translation = gesture.translation(in: self)
        // Reset translation so we get continuous deltas
        gesture.setTranslation(.zero, in: self)
        
        // Trackpad scrolling on Mac vs iOS (we pass raw delta and let macOS handle natural scrolling)
        if gesture.state == .changed || gesture.state == .began {
            inputCollector.sendScrollEvent(deltaX: Double(translation.x), deltaY: Double(translation.y))
        }
    }
    
    // ─── Touch and Apple Pencil Handling ───
    
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        guard let touch = touches.first else { return }
        
        touchStartPoint = touch.location(in: self)
        hasMovedTouch = false
        
        handleTouchUpdate(touch, isMove: true)
    }
    
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        guard let touch = touches.first else { return }
        
        let currentPoint = touch.location(in: self)
        let distance = sqrt(pow(currentPoint.x - touchStartPoint.x, 2) + pow(currentPoint.y - touchStartPoint.y, 2))
        
        if distance > moveThreshold {
            hasMovedTouch = true
        }
        
        handleTouchUpdate(touch, isMove: true)
    }
    
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        guard let touch = touches.first else { return }
        
        if !hasMovedTouch {
            // Treat as absolute click tap
            handleTouchUpdate(touch, isMove: false)
        }
    }
    
    private func handleTouchUpdate(_ touch: UITouch, isMove: Bool) {
        guard let inputCollector = inputCollector else { return }
        
        let location = touch.location(in: self)
        let size = self.bounds.size
        
        if touch.type == .pencil {
            let pressure = Float(touch.force)
            let tilt = Float(touch.altitudeAngle)
            print("[TouchInput] Pencil Event - loc: \(location), pressure: \(pressure)")
            inputCollector.sendPencilEvent(at: location, in: size, pressure: pressure, tilt: tilt)
        } else {
            if isMove {
                print("[TouchInput] Mouse Move Event - loc: \(location) in size: \(size)")
                inputCollector.sendMouseMoveEvent(at: location, in: size)
            } else {
                print("[TouchInput] Mouse Tap/Click Event - loc: \(location) in size: \(size)")
                inputCollector.sendTapEvent(at: location, in: size)
            }
        }
    }
    
    // ─── Physical Keyboard Press Handling ───
    
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let inputCollector = inputCollector, let press = presses.first, let key = press.key else {
            super.pressesBegan(presses, with: event)
            return
        }
        
        let usbKeyCode = UInt16(key.keyCode.rawValue)
        let macKeyCode = KeyboardMapper.mapUsbHidToMacVirtualKey(usbKeyCode)
        print("[TouchInput] Key down: USB \(usbKeyCode) -> MAC \(macKeyCode)")
        inputCollector.sendKeyboardEvent(keyCode: macKeyCode, isDown: true)
    }
    
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let inputCollector = inputCollector, let press = presses.first, let key = press.key else {
            super.pressesEnded(presses, with: event)
            return
        }
        
        let usbKeyCode = UInt16(key.keyCode.rawValue)
        let macKeyCode = KeyboardMapper.mapUsbHidToMacVirtualKey(usbKeyCode)
        print("[TouchInput] Key up: USB \(usbKeyCode) -> MAC \(macKeyCode)")
        inputCollector.sendKeyboardEvent(keyCode: macKeyCode, isDown: false)
    }
}

#else
// Fallback for macOS testing environments if client compiles under macOS
struct VideoRendererView: View {
    let videoTrack: RTCVideoTrack?
    let inputCollector: InputCollector
    var body: some View {
        Text("Rendering only supported on iOS/iPadOS target.")
            .foregroundColor(.white)
    }
}
#endif

