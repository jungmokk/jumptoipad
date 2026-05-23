import Foundation
import ScreenCaptureKit
import WebRTC
import CoreMedia
import VideoToolbox

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
    // Use NV12 for Zero-Copy Hardware Encoding (VideoToolbox)
    private let pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    
    /// Starts capturing a specified display (defaults to main display) and system audio loopback
    func startCapture(targetWidth: Int? = nil, targetHeight: Int? = nil, displayID: CGDirectDisplayID? = nil) {
        guard !isCapturing else { return }
        
        attemptCapture(targetWidth: targetWidth, targetHeight: targetHeight, displayID: displayID, retriesLeft: 10)
    }
    
    private func attemptCapture(targetWidth: Int?, targetHeight: Int?, displayID: CGDirectDisplayID?, retriesLeft: Int) {
        // Retrieve shareable content to find the primary display
        SCShareableContent.getWithCompletionHandler { [weak self] content, error in
            guard let self = self else { return }
            if let error = error {
                self.delegate?.screenCapturer(self, didFailWithError: error)
                return
            }
            
            var selectedDisplay: SCDisplay?
            if let displayID = displayID {
                selectedDisplay = content?.displays.first { $0.displayID == displayID }
                
                // If the display isn't in SCShareableContent yet (timing issue with virtual displays), retry
                if selectedDisplay == nil && retriesLeft > 0 {
                    print("[Capture] Display ID \(displayID) not yet visible to ScreenCaptureKit. Retrying in 0.5s... (\(retriesLeft) attempts left)")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.attemptCapture(targetWidth: targetWidth, targetHeight: targetHeight, displayID: displayID, retriesLeft: retriesLeft - 1)
                    }
                    return
                }
            }
            
            guard let display = selectedDisplay ?? content?.displays.first else {
                let displayError = NSError(
                    domain: "com.jumpdesktop.screencapture",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "No active display found for ScreenCaptureKit."]
                )
                self.delegate?.screenCapturer(self, didFailWithError: displayError)
                return
            }
            
            self.setupStream(with: display, targetWidth: targetWidth, targetHeight: targetHeight)
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
    
    private func setupStream(with display: SCDisplay, targetWidth: Int?, targetHeight: Int?) {
        // Create an inclusive filter for the selected display
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        
        // Define stream configurations
        let config = SCStreamConfiguration()
        
        var width = targetWidth ?? display.width
        var height = targetHeight ?? display.height
        
        // CRITICAL: WebRTC's H264 hardware encoder (VideoToolbox) will crash with EXC_BREAKPOINT 
        // if the pixel buffer width or height is not an even number. Align to 2.
        width = (width / 2) * 2
        height = (height / 2) * 2
        
        // Resolution (accounting for scale factor if needed, or matching display native size)
        config.width = width
        config.height = height
        
        // Framerate pacing
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(targetFps))
        config.queueDepth = 2 // Extremely low depth for real-time low latency (drop frames rather than buffering)
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
            try scStream.addStreamOutput(self, type: SCStreamOutputType.screen, sampleHandlerQueue: captureQueue)
            
            if #available(macOS 13.0, *) {
                try scStream.addStreamOutput(self, type: SCStreamOutputType.audio, sampleHandlerQueue: captureQueue)
            }
            
            scStream.startCapture { [weak self] (error: Error?) in
                guard let self = self else { return }
                if let error = error {
                    self.delegate?.screenCapturer(self, didFailWithError: error)
                    return
                }
                
                self.stream = scStream
                self.isCapturing = true
                print("[Capture] SCStream started. Dimensions: \(width)x\(height) @ \(self.targetFps)fps")
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
            rotation: ._0,
            timeStampNs: timestampNs
        )
        
        delegate?.screenCapturer(self, didCaptureVideoFrame: rtcVideoFrame)
    }
    

}
