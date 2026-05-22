import Foundation
import WebRTC
import CoreMedia

/// HostConnectionCoordinator acts as the orchestrator of Phase 1 and Phase 2.
/// Tightly coordinates the Signaling Client, WebRTC connection state, and ScreenCaptureKit pipelines.
class HostConnectionCoordinator: NSObject {
    
    private let signalingClient: SignalingClient
    private let webRTCManager: WebRTCManager
    private let screenCapturer = ScreenCapturer()
    private let audioCapturer = AudioCapturer()
    private let inputInjector = InputInjector()
    
    private var videoSource: RTCVideoSource?
    private var videoTrack: RTCVideoTrack?
    private var audioTrack: RTCAudioTrack?
    
    private var activeRoomId: String?
    
    /// Initialize the coordinator with signaling and STUN/TURN configurations
    init(serverURL: URL, token: String, iceServers: [String], turnUser: String, turnPass: String) {
        self.signalingClient = SignalingClient(serverURL: serverURL, token: token)
        self.webRTCManager = WebRTCManager(iceServers: iceServers, turnUsername: turnUser, turnCredential: turnPass)
        
        super.init()
        
        // Connect delegates
        self.signalingClient.delegate = self
        self.webRTCManager.delegate = self
        self.screenCapturer.delegate = self
        
        // Bind input injector reply channel for feedback (like ping/pong RTT responses)
        self.inputInjector.onSendReply = { [weak self] replyData in
            self?.webRTCManager.sendInputData(replyData)
        }
    }
    
    /// Start connection process by connecting to signaling server and creating a room
    func start() {
        print("[Coordinator] Starting Host Connection Coordinator...")
        signalingClient.connect()
    }
    
    /// Shut down all captures and connections
    func stop() {
        print("[Coordinator] Stopping Host connection and captures...")
        screenCapturer.stopCapture()
        audioCapturer.stopCapture()
        webRTCManager.close()
        signalingClient.disconnect()
        activeRoomId = nil
    }
}

// ─── SignalingClientDelegate ───

extension HostConnectionCoordinator: SignalingClientDelegate {
    
    func signalingClientDidConnect(_ client: SignalingClient) {
        print("[Coordinator] Connected to signaling server. Creating room...")
        client.createRoom()
    }
    
    func signalingClientDidDisconnect(_ client: SignalingClient) {
        print("[Coordinator] Disconnected from signaling server.")
        stop()
    }
    
    func signalingClient(_ client: SignalingClient, didReceiveWelcome deviceId: String, role: String) {
        print("[Coordinator] Welcome received. DeviceId: \(deviceId), Role: \(role)")
    }
    
    func signalingClient(_ client: SignalingClient, didCreateRoom roomId: String) {
        self.activeRoomId = roomId
        print("==================================================")
        print("  ROOM CREATED: \(roomId)")
        print("  Share this Room ID with the iPadOS Client.")
        print("==================================================")
    }
    
    func signalingClient(_ client: SignalingClient, didPeerJoin deviceId: String) {
        print("[Coordinator] Client \(deviceId) joined the room. Initiating WebRTC peer connection...")
        
        // 1. Setup peer connection on WebRTC
        webRTCManager.setupPeerConnection()
        
        // 2. Initialize and configure local media tracks
        // A. Video track setup
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let source = webRTCManager.peerConnectionFactory.videoSource()
        self.videoSource = source
        self.videoTrack = webRTCManager.peerConnectionFactory.videoTrack(with: source, trackId: "host_video_track")
        
        if let videoTrack = self.videoTrack {
            webRTCManager.addTrack(videoTrack, streamIds: ["host_media_stream"])
        }
        
        // B. Audio track setup
        self.audioTrack = audioCapturer.startCapture(factory: webRTCManager.peerConnectionFactory)
        if let audioTrack = self.audioTrack {
            webRTCManager.addTrack(audioTrack, streamIds: ["host_media_stream"])
        }
        
        // 3. Start high-performance captures
        screenCapturer.startCapture()
        
        // 4. Create and send SDP Offer to client
        webRTCManager.createOffer()
    }
    
    func signalingClient(_ client: SignalingClient, didPeerLeave deviceId: String) {
        print("[Coordinator] Client \(deviceId) disconnected. Stopping captures...")
        screenCapturer.stopCapture()
        audioCapturer.stopCapture()
        webRTCManager.close()
    }
    
    func signalingClient(_ client: SignalingClient, didReceiveSDPOffer sdp: String) {
        // Host only creates offers, should not receive one in standard flow
    }
    
    func signalingClient(_ client: SignalingClient, didReceiveSDPAnswer sdp: String) {
        print("[Coordinator] Received SDP Answer from client. Setting remote description...")
        webRTCManager.setRemoteAnswer(sdp: sdp)
    }
    
    func signalingClient(_ client: SignalingClient, didReceiveICECandidate candidate: [String : Any]) {
        guard let sdp = candidate["candidate"] as? String,
              let sdpMid = candidate["sdpMid"] as? String,
              let sdpMLineIndex = candidate["sdpMLineIndex"] as? Int32 else { return }
        
        webRTCManager.addRemoteIceCandidate(sdpMid: sdpMid, sdpMLineIndex: sdpMLineIndex, candidate: sdp)
    }
    
    func signalingClient(_ client: SignalingClient, didReceiveError error: String) {
        print("[Coordinator] Signaling Error: \(error)")
    }
}

// ─── WebRTCManagerDelegate ───

extension HostConnectionCoordinator: WebRTCManagerDelegate {
    
    func webRTCManager(_ manager: WebRTCManager, didChangeConnectionState state: RTCPeerConnectionState) {
        print("[Coordinator] WebRTC Connection State Changed: \(state.rawValue)")
        if state == .failed || state == .disconnected {
            print("[Coordinator] Connection lost. Stopping captures...")
            screenCapturer.stopCapture()
            audioCapturer.stopCapture()
        }
    }
    
    func webRTCManager(_ manager: WebRTCManager, didGenerateLocalIceCandidate candidate: RTCIceCandidate) {
        signalingClient.sendICECandidate(
            sdpMid: candidate.sdpMid ?? "",
            sdpMLineIndex: candidate.sdpMLineIndex,
            candidate: candidate.sdp
        )
    }
    
    func webRTCManager(_ manager: WebRTCManager, didDiscoverLocalSdp sdp: String) {
        signalingClient.sendSDPOffer(sdp: sdp)
    }
    
    func webRTCManager(_ manager: WebRTCManager, didReceiveData data: Data, onChannel channelName: String) {
        if channelName == "input_control" {
            inputInjector.injectEvent(data: data)
        }
    }
}

// ─── ScreenCapturerDelegate ───

extension HostConnectionCoordinator: ScreenCapturerDelegate {
    
    func screenCapturer(_ capturer: ScreenCapturer, didCaptureVideoFrame frame: RTCVideoFrame) {
        // Ingest captured ScreenCaptureKit video frames directly into WebRTC video source
        videoSource?.capturer(capturer, didCapture: frame)
    }
    
    func screenCapturer(_ capturer: ScreenCapturer, didCaptureAudioBuffer sampleBuffer: CMSampleBuffer) {
        // Ingest captured ScreenCaptureKit audio frames directly into Audio capturer pipeline
        audioCapturer.processAudioSampleBuffer(sampleBuffer)
    }
    
    func screenCapturer(_ capturer: ScreenCapturer, didFailWithError error: Error) {
        print("[Coordinator] Screen Capturer Error: \(error.localizedDescription)")
    }
}
