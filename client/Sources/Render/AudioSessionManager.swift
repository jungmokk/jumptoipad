import Foundation
import AVFoundation
import WebRTC

/// AudioSessionManager handles the configuration and activation of iPadOS AVAudioSession
/// for ultra-low latency WebRTC audio streaming.
class AudioSessionManager {
    
    static let shared = AudioSessionManager()
    
    private init() {}
    
    /// Configure and activate the iOS Audio Session for real-time WebRTC audio playback.
    /// Thread safe.
    func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            // Set category for low-latency playback compatible with speaker and bluetooth outputs
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat, // voiceChat optimizes for lowest delay and applies system echo cancellation
                options: [.allowBluetoothHFP, .defaultToSpeaker]
            )
            
            // Set preferred sample rate (48kHz matches Opus/ScreenCaptureKit audio captures)
            try session.setPreferredSampleRate(48000)
            
            // Set preferred IO buffer duration to minimize hardware latency (e.g. 5-10ms)
            try session.setPreferredIOBufferDuration(0.005)
            
            // Activate audio session
            try session.setActive(true)
            
            // Integrate WebRTC audio session listener
            let rtcSession = RTCAudioSession.sharedInstance()
            
            print("[Audio] AVAudioSession configured successfully. SampleRate: \(session.sampleRate)Hz, Latency: \(session.ioBufferDuration * 1000)ms")
            
        } catch {
            print("[Audio] Error configuring AVAudioSession: \(error.localizedDescription)")
        }
    }
    
    /// Deactivate audio session to release hardware locks when stream closes
    func deactivateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            print("[Audio] AVAudioSession deactivated.")
        } catch {
            print("[Audio] Error deactivating AVAudioSession: \(error.localizedDescription)")
        }
    }
}
