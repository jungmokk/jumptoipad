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
    private let virtualDisplayManager = VirtualDisplayManager()
    
    private var videoSource: RTCVideoSource?
    private var dummyCapturer: RTCVideoCapturer?
    private var videoTrack: RTCVideoTrack?
    private var audioTrack: RTCAudioTrack?
    
    private var activeRoomId: String?
    
    private var isStopped = false
    
    /// Initialize the coordinator with signaling and STUN/TURN configurations
    init(serverURL: URL, token: String, iceServers: [String], turnUser: String, turnPass: String) {
        self.signalingClient = SignalingClient(serverURL: serverURL, token: token)
        self.webRTCManager = WebRTCManager(iceServers: iceServers, turnUsername: turnUser, turnCredential: turnPass)
        
        super.init()
        
        // Bind delegates
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
        isStopped = false
        signalingClient.connect()
    }
    
    /// Shut down all captures and connections
    func stop() {
        print("[Coordinator] Stopping Host connection and captures...")
        isStopped = true
        screenCapturer.stopCapture()
        audioCapturer.stopCapture()
        virtualDisplayManager.destroyVirtualDisplay()
        webRTCManager.close()
        signalingClient.disconnect()
        activeRoomId = nil
    }
}

// ─── SignalingClientDelegate ───

extension HostConnectionCoordinator: SignalingClientDelegate {
    
    func signalingClientDidConnect(_ client: SignalingClient) {
        print("[Coordinator] Connected to signaling server. Waiting for welcome message...")
    }
    
    func signalingClientDidDisconnect(_ client: SignalingClient) {
        print("[Coordinator] Disconnected from signaling server.")
        
        // Clean up captures
        screenCapturer.stopCapture()
        audioCapturer.stopCapture()
        virtualDisplayManager.destroyVirtualDisplay()
        webRTCManager.close()
        
        if !isStopped {
            // Trigger automatic reconnect to signaling server after 2 seconds
            print("[Coordinator] Attempting to reconnect to signaling server in 2.0 seconds...")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self = self, !self.isStopped else { return }
                print("[Coordinator] Reconnecting to signaling server...")
                self.signalingClient.connect()
            }
        }
    }
    
    func signalingClient(_ client: SignalingClient, didReceiveWelcome deviceId: String, role: String) {
        print("[Coordinator] Welcome received. DeviceId: \(deviceId), Role: \(role)")
        print("[Coordinator] Creating room...")
        client.createRoom()
    }
    
    func signalingClient(_ client: SignalingClient, didCreateRoom roomId: String) {
        self.activeRoomId = roomId
        print("==================================================")
        print("  ROOM CREATED: \(roomId)")
        print("  Share this Room ID with the iPadOS Client.")
        print("==================================================")
    }
    
    func signalingClient(_ client: SignalingClient, didPeerJoin deviceId: String, payload: [String: Any]?) {
        print("[Coordinator] Client \(deviceId) joined the room. Initiating WebRTC peer connection...")
        
        let targetWidthRaw = payload?["width"] as? Int
        let targetHeightRaw = payload?["height"] as? Int
        let targetBitrateKbps = payload?["bitrateKbps"] as? Int ?? 8000
        
        print("[Coordinator] Client requested resolution: \(targetWidthRaw ?? -1)x\(targetHeightRaw ?? -1) at \(targetBitrateKbps)kbps")
        
        // Safety cap for Virtual Display (macOS private API may reject huge resolutions like 2732x2048)
        // CRITICAL: Width and Height MUST be multiples of 16 for stable H.264 Hardware Encoding
        var safeWidth = targetWidthRaw
        var safeHeight = targetHeightRaw
        if let w = safeWidth, let h = safeHeight {
            let maxResolution: CGFloat = 2560.0 // Cap max width to 2K to ensure hardware acceleration
            let ratio = CGFloat(h) / CGFloat(w)
            
            if CGFloat(w) > maxResolution {
                safeWidth = Int(maxResolution)
                safeHeight = Int(maxResolution * ratio)
            }
            
            // Align to multiple of 16 to prevent VideoToolbox/WebRTC encoder crashes
            safeWidth = (safeWidth! / 16) * 16
            safeHeight = (safeHeight! / 16) * 16
            
            print("[Coordinator] Hardware-aligned Virtual Display Resolution: \(safeWidth!)x\(safeHeight!)")
        }
        
        // 1. Setup peer connection on WebRTC
        webRTCManager.setupPeerConnection()
        
        // 2. Initialize and configure local media tracks
        // A. Video track setup
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let source = webRTCManager.peerConnectionFactory.videoSource()
        self.videoSource = source
        self.dummyCapturer = RTCVideoCapturer(delegate: source)
        self.videoTrack = webRTCManager.peerConnectionFactory.videoTrack(with: source, trackId: "host_video_track")
        
        if let videoTrack = self.videoTrack {
            webRTCManager.addTrack(videoTrack, streamIds: ["host_media_stream"])
        }
        
        // B. Audio track setup
        self.audioTrack = audioCapturer.startCapture(factory: webRTCManager.peerConnectionFactory)
        if let audioTrack = self.audioTrack {
            webRTCManager.addTrack(audioTrack, streamIds: ["host_media_stream"])
        }
        
        var activeDisplayID: CGDirectDisplayID? = nil
        if let w = safeWidth, let h = safeHeight {
            print("[Coordinator] Attempting to create Virtual Display with \(w)x\(h)...")
            activeDisplayID = virtualDisplayManager.createVirtualDisplay(width: w, height: h)
            if activeDisplayID == nil {
                print("[Coordinator] WARNING: Virtual Display creation failed. Falling back to main display.")
            } else {
                print("[Coordinator] Virtual Display created successfully: \(activeDisplayID!)")
            }
        } else {
            print("[Coordinator] No resolution provided by client. Falling back to main display.")
        }
        
        // 3. Delay capture start and SDP Offer by 1.0 second to allow macOS display configuration to fully settle.
        // This prevents VideoToolbox from crash-triggering resolution changes on immediate connection.
        let delaySeconds = 1.0
        print("[Coordinator] Waiting \(delaySeconds)s for virtual display to settle before starting capture...")
        DispatchQueue.main.asyncAfter(deadline: .now() + delaySeconds) { [weak self] in
            guard let self = self else { return }
            
            print("[Coordinator] Virtual display settled. Starting screen capture...")
            // Start high-performance captures with requested dimensions
            self.screenCapturer.startCapture(targetWidth: safeWidth, targetHeight: safeHeight, displayID: activeDisplayID)
            
            // Create and send SDP Offer to client
            self.webRTCManager.createOffer(targetBitrateKbps: targetBitrateKbps)
        }
    }
    
    func signalingClient(_ client: SignalingClient, didPeerLeave deviceId: String) {
        print("[Coordinator] Client \(deviceId) disconnected. Stopping captures...")
        screenCapturer.stopCapture()
        audioCapturer.stopCapture()
        virtualDisplayManager.destroyVirtualDisplay()
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
            virtualDisplayManager.destroyVirtualDisplay()
            webRTCManager.close() // Clean up old WebRTC connection cleanly!
        }
    }
    
    func webRTCManager(_ manager: WebRTCManager, didGenerateLocalIceCandidate candidate: RTCIceCandidate) {
        // 1. Send the original WebRTC generated candidate
        signalingClient.sendICECandidate(
            sdpMid: candidate.sdpMid ?? "",
            sdpMLineIndex: candidate.sdpMLineIndex,
            candidate: candidate.sdp
        )
        
        // 2. Scan all local network interfaces (including VPN / Tailscale 100.x.x.x)
        // and replicate this candidate for each IP, overriding the connection address.
        // This bypasses WebRTC's default filtering of VPN/tun virtual interfaces.
        let localIPs = getLocalIPv4Addresses()
        let candidateSdp = candidate.sdp
        let parts = candidateSdp.components(separatedBy: " ")
        
        if parts.count > 4 {
            let originalIP = parts[4]
            if originalIP.contains(".") { // IPv4 verification
                for ip in localIPs {
                    if ip != originalIP {
                        var modifiedParts = parts
                        modifiedParts[4] = ip
                        let modifiedSdp = modifiedParts.joined(separator: " ")
                        print("[Coordinator] Replicating ICE Candidate for VPN/Tailscale interface (\(ip)): \(modifiedSdp)")
                        signalingClient.sendICECandidate(
                            sdpMid: candidate.sdpMid ?? "",
                            sdpMLineIndex: candidate.sdpMLineIndex,
                            candidate: modifiedSdp
                        )
                    }
                }
            }
        }
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
        if let dummy = self.dummyCapturer {
            videoSource?.capturer(dummy, didCapture: frame)
        }
    }
    
    func screenCapturer(_ capturer: ScreenCapturer, didCaptureAudioBuffer sampleBuffer: CMSampleBuffer) {
        // Ingest captured ScreenCaptureKit audio frames directly into Audio capturer pipeline
        audioCapturer.processAudioSampleBuffer(sampleBuffer)
    }
    
    func screenCapturer(_ capturer: ScreenCapturer, didFailWithError error: Error) {
        print("[Coordinator] Screen Capturer Error: \(error.localizedDescription)")
    }
}

// ─── Network Utilities for VPN/Tailscale Traversal ───

private func getLocalIPv4Addresses() -> [String] {
    var addresses: [String] = []
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0 else { return [] }
    guard let firstAddr = ifaddr else { return [] }
    
    for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
        let flags = Int32(ptr.pointee.ifa_flags)
        guard let addr = ptr.pointee.ifa_addr else { continue }
        
        // Check for running IPv4 interface that is not loopback
        if addr.pointee.sa_family == UInt8(AF_INET) {
            if (flags & IFF_LOOPBACK) == 0 {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let address = String(cString: hostname)
                    addresses.append(address)
                }
            }
        }
    }
    freeifaddrs(ifaddr)
    return addresses
}
