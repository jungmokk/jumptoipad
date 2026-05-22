import Foundation
import WebRTC
import CoreMedia
import AVFoundation

/// Delegate protocol for AudioCapturer events
protocol AudioCapturerDelegate: AnyObject {
    func audioCapturer(_ capturer: AudioCapturer, didCaptureAudioData data: Data, numberOfSamples: Int)
    func audioCapturer(_ capturer: AudioCapturer, didFailWithError error: Error)
}

/// A fallback/supplementary AudioCapturer for macOS system sound loopback.
/// Acts as the pipeline coordinator to ingest CoreAudio / ScreenCaptureKit PCM audio frames and pass them to WebRTC.
class AudioCapturer: NSObject {
    
    weak var delegate: AudioCapturerDelegate?
    
    private var audioSource: RTCAudioSource?
    private var audioTrack: RTCAudioTrack?
    
    private let captureQueue = DispatchQueue(label: "com.jumpdesktop.host.audiocapturer", qos: .userInteractive)
    
    /// Sets up and starts the audio session or routing pipeline
    func startCapture(factory: RTCPeerConnectionFactory) -> RTCAudioTrack? {
        // Create an audio track and source from the factory
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let source = factory.audioSource(with: constraints)
        let track = factory.audioTrack(with: source, trackId: "host_audio_track")
        
        self.audioSource = source
        self.audioTrack = track
        
        print("[Audio] WebRTC AudioTrack initialized and activated.")
        return track
    }
    
    /// Stops audio capture and releases resources
    func stopCapture() {
        audioTrack = nil
        audioSource = nil
        print("[Audio] Audio Capture pipeline stopped.")
    }
    
    /// Ingests captured PCM sample buffers (e.g. from ScreenCaptureKit or HAL loopback device)
    /// and formats them for WebRTC ingestion.
    func processAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        captureQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Extract block buffer and details
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
            let bufferLength = CMBlockBufferGetDataLength(blockBuffer)
            
            var data = Data(count: bufferLength)
            data.withUnsafeMutableBytes { (pointer: UnsafeMutableRawBufferPointer) in
                if let baseAddress = pointer.baseAddress {
                    CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: bufferLength, destination: baseAddress)
                }
            }
            
            // CoreMedia sample metadata
            let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
            
            // Dispatch formatted samples to the delegate
            self.delegate?.audioCapturer(self, didCaptureAudioData: data, numberOfSamples: numSamples)
        }
    }
}
