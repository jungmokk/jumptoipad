import Foundation
import ScreenCaptureKit
import WebRTC
import CoreMedia

/// Delegate protocol for ScreenCapturer events
protocol ScreenCapturerDelegate: AnyObject {
    func screenCapturer(_ capturer: ScreenCapturer, didCaptureVideoFrame frame: RTCVideoFrame)
    func screenCapturer(_ capturer: ScreenCapturer, didCaptureAudioBuffer sampleBuffer: CMSampleBuffer)
    func screenCapturer(_ capturer: ScreenCapturer, didFailWithError error: Error)
}

/// A state-of-the-art macOS ScreenCaptureKit stream coordinator.
/// Captures ultra-low latency screen pixels and system audio loopback without virtual audio drivers (macOS 13+).
class ScreenCapturer: NSObject {
    
    weak var delegate: ScreenCapturerDelegate?
    
    private var stream: SCStream?
    private let captureQueue = DispatchQueue(label: "com.jumpdesktop.host.capturermidi", qos: .userInteractive)
    
    private(set) var isCapturing = false
    
    // Configurable Capture parameters
    private let targetFps: Int = 60
    private let pixelFormat = kCVPixelFormatType_32BGRA // Optimal and standard for WebRTC compatibility
    
    /// Starts capturing a specified display (defaults to main display) and system audio loopback
    func startCapture() {
        guard !isCapturing else { return }
        
        // Retrieve shareable content to find the primary display
        SCShareableContent.getWithCompletionHandler { [weak self] content, error in
            guard let self = self else { return }
            if let error = error {
                self.delegate?.screenCapturer(self, didFailWithError: error)
                return
            }
            
            guard let content = content, let display = content.displays.first else {
                let displayError = NSError(
                    domain: "com.jumpdesktop.screencapture",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "No active display found for ScreenCaptureKit."]
                )
                self.delegate?.screenCapturer(self, didFailWithError: displayError)
                return
            }
            
            self.setupStream(with: display)
        }
    }
    
    /// Stops the ScreenCaptureKit stream
    func stopCapture() {
        guard isCapturing, let activeStream = stream else { return }
        
        activeStream.stopCapture { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                print("[Capture] Error stopping SCStream: \(error.localizedDescription)")
            }
            self.stream = nil
            self.isCapturing = false
            print("[Capture] Screen Capture stopped successfully.")
        }
    }
    
    // ─── Private Stream Setup ───
    
    private func setupStream(with display: SCDisplay) {
        // Create an inclusive filter for the selected display
        let filter = SCContentFilter(display: display, excludingApplications: [])
        
        // Define stream configurations
        let config = SCStreamConfiguration()
        
        // Resolution (accounting for scale factor if needed, or matching display native size)
        config.width = display.width
        config.height = display.height
        
        // Framerate pacing
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(targetFps))
        config.queueDepth = 8 // Sufficient depth to prevent stuttering on frames drop
        config.pixelFormat = pixelFormat
        
        // Custom performance settings
        config.showsCursor = true // Enable remote pointer visibility
        config.colorSpaceName = CGColorSpace.sRGB // Harmoneous desktop color rendering
        
        // ─── Audio Loopback Configuration (macOS 13+) ───
        if #available(macOS 13.0, *) {
            config.capturesAudio = true
            config.sampleRate = 48000 // Professional standard WebRTC Opus sampling rate
            config.channelCount = 2   // Stereo loopback
            print("[Capture] Audio Loopback capture enabled natively via ScreenCaptureKit.")
        } else {
            print("[Capture] WARNING: Native Audio Loopback via ScreenCaptureKit requires macOS 13+. System audio will fallback to CoreAudio.")
        }
        
        do {
            let scStream = SCStream(filter: filter, configuration: config, delegate: self)
            
            // Add stream outputs for both Video and Audio to the interactive queue
            try scStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
            
            if #available(macOS 13.0, *) {
                try scStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: captureQueue)
            }
            
            scStream.startCapture { [weak self] error in
                guard let self = self else { return }
                if let error = error {
                    self.delegate?.screenCapturer(self, didFailWithError: error)
                    return
                }
                
                self.stream = scStream
                self.isCapturing = true
                print("[Capture] SCStream started. Dimensions: \(display.width)x\(display.height) @ \(self.targetFps)fps")
            }
            
        } catch {
            delegate?.screenCapturer(self, didFailWithError: error)
        }
    }
}

// ─── SCStreamDelegate ───

extension ScreenCapturer: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("[Capture] Stream terminated due to error: \(error.localizedDescription)")
        delegate?.screenCapturer(self, didFailWithError: error)
        stopCapture()
    }
}

// ─── SCStreamOutput ───

extension ScreenCapturer: SCStreamOutput {
    
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard isCapturing else { return }
        
        switch type {
        case .screen:
            handleVideoFrame(sampleBuffer)
        case .audio:
            delegate?.screenCapturer(self, didCaptureAudioBuffer: sampleBuffer)
        @unknown default:
            break
        }
    }
    
    private func handleVideoFrame(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        // Extract frame timestamp
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let timestampNs = Int64(CMTimeGetSeconds(presentationTime) * 1_000_000_000)
        
        // Wrap the standard CVPixelBuffer into WebRTC structures
        let rtcPixelBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
        
        let rtcVideoFrame = RTCVideoFrame(
            buffer: rtcPixelBuffer,
            rotation: .rotation_0,
            timeStampNs: timestampNs
        )
        
        delegate?.screenCapturer(self, didCaptureVideoFrame: rtcVideoFrame)
    }
}
