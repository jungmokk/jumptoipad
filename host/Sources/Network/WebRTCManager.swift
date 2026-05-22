import Foundation
import WebRTC

/// Delegate protocol for WebRTCManager events.
protocol WebRTCManagerDelegate: AnyObject {
    func webRTCManager(_ manager: WebRTCManager, didChangeConnectionState state: RTCPeerConnectionState)
    func webRTCManager(_ manager: WebRTCManager, didGenerateLocalIceCandidate candidate: RTCIceCandidate)
    func webRTCManager(_ manager: WebRTCManager, didDiscoverLocalSdp sdp: String)
    func webRTCManager(_ manager: WebRTCManager, didReceiveData data: Data, onChannel channelName: String)
}

/// WebRTCManager manages the RTCPeerConnection, ICE gathering, and Data Channels for the macOS Host.
class WebRTCManager: NSObject {
    
    weak var delegate: WebRTCManagerDelegate?
    
    private var peerConnectionFactory: RTCPeerConnectionFactory
    private var peerConnection: RTCPeerConnection?
    private var dataChannel: RTCDataChannel?
    
    private let iceServers: [String]
    private let turnUsername: String
    private let turnCredential: String
    
    /// Initialize WebRTCManager with TURN server settings
    init(iceServers: [String], turnUsername: String, turnCredential: String) {
        self.iceServers = iceServers
        self.turnUsername = turnUsername
        self.turnCredential = turnCredential
        
        // Initialize WebRTC globals and Factory
        RTCInitializeSSL()
        let videoEncoderFactory = RTCDefaultVideoEncoderFactory()
        let videoDecoderFactory = RTCDefaultVideoDecoderFactory()
        self.peerConnectionFactory = RTCPeerConnectionFactory(
            encoderFactory: videoEncoderFactory,
            decoderFactory: videoDecoderFactory
        )
        
        super.init()
    }
    
    deinit {
        RTCCleanupSSL()
    }
    
    /// Sets up the RTCPeerConnection and the "input_control" DataChannel
    func setupPeerConnection() {
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        
        // Create custom self-hosted TURN configurations
        var rtcIceServers: [RTCIceServer] = []
        for serverUri in iceServers {
            let server = RTCIceServer(
                urlStrings: [serverUri],
                username: turnUsername,
                credential: turnCredential
            )
            rtcIceServers.append(server)
        }
        config.iceServers = rtcIceServers
        
        // Configure WebRTC constraints
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueFalse,
                kRTCMediaConstraintsOfferToReceiveVideo: kRTCMediaConstraintsValueFalse
            ],
            optionalConstraints: nil
        )
        
        guard let connection = peerConnectionFactory.peerConnection(
            with: config,
            constraints: constraints,
            delegate: self
        ) else {
            print("[WebRTC] Failed to create PeerConnection.")
            return
        }
        
        self.peerConnection = connection
        
        // Set up the input data channel for receiving keyboard/mouse inputs
        let dataChannelConfig = RTCDataChannelConfiguration()
        dataChannelConfig.isOrdered = true // Important for remote control inputs
        dataChannelConfig.maxRetransmits = -1
        dataChannelConfig.maxPacketLifeTime = -1
        
        guard let channel = connection.dataChannel(
            forLabel: "input_control",
            configuration: dataChannelConfig
        ) else {
            print("[WebRTC] Failed to create 'input_control' data channel.")
            return
        }
        
        channel.delegate = self
        self.dataChannel = channel
        
        print("[WebRTC] PeerConnection and DataChannel set up successfully.")
    }
    
    /// Create SDP Offer and notify via delegate
    func createOffer() {
        guard let connection = peerConnection else {
            print("[WebRTC] Error: PeerConnection is not initialized.")
            return
        }
        
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueFalse,
                kRTCMediaConstraintsOfferToReceiveVideo: kRTCMediaConstraintsValueFalse
            ],
            optionalConstraints: nil
        )
        
        connection.offer(for: constraints) { [weak self] sdpDescription, error in
            guard let self = self else { return }
            if let error = error {
                print("[WebRTC] Error creating offer: \(error.localizedDescription)")
                return
            }
            
            guard let localSdp = sdpDescription else { return }
            
            connection.setLocalDescription(localSdp) { error in
                if let error = error {
                    print("[WebRTC] Error setting local SDP: \(error.localizedDescription)")
                    return
                }
                
                print("[WebRTC] Offer created and set as LocalDescription.")
                self.delegate?.webRTCManager(self, didDiscoverLocalSdp: localSdp.sdp)
            }
        }
    }
    
    /// Set remote SDP Answer
    func setRemoteAnswer(sdp: String) {
        guard let connection = peerConnection else { return }
        
        let remoteSdp = RTCSessionDescription(type: .answer, sdp: sdp)
        connection.setRemoteDescription(remoteSdp) { error in
            if let error = error {
                print("[WebRTC] Error setting remote answer: \(error.localizedDescription)")
            } else {
                print("[WebRTC] Remote Answer set successfully.")
            }
        }
    }
    
    /// Inject remote ICE Candidate
    func addRemoteIceCandidate(sdpMid: String, sdpMLineIndex: Int32, candidate: String) {
        guard let connection = peerConnection else { return }
        
        let rtcCandidate = RTCIceCandidate(
            sdp: candidate,
            sdpMLineIndex: sdpMLineIndex,
            sdpMid: sdpMid
        )
        
        connection.add(rtcCandidate) { error in
            if let error = error {
                print("[WebRTC] Failed to add remote ICE Candidate: \(error.localizedDescription)")
            }
        }
    }
    
    /// Add custom media tracks to PeerConnection (called when ScreenCaptureKit/CoreAudio starts)
    func addTrack(_ track: RTCMediaStreamTrack, streamIds: [String]) {
        guard let connection = peerConnection else { return }
        connection.add(track, streamIds: streamIds)
        print("[WebRTC] Track added: \(track.trackId)")
    }
    
    /// Close the WebRTC peer connection
    func close() {
        dataChannel?.close()
        dataChannel = nil
        peerConnection?.close()
        peerConnection = nil
        print("[WebRTC] Connection closed.")
    }
    
    /// Send data back to the client via the open "input_control" DataChannel
    func sendInputData(_ data: Data) {
        guard let channel = dataChannel, channel.readyState == .open else {
            print("[WebRTC] Error: Input control data channel is not open.")
            return
        }
        
        let buffer = RTCDataBuffer(data: data, isBinary: true)
        channel.sendData(buffer)
    }
}

// ─── RTCPeerConnectionDelegate ───

extension WebRTCManager: RTCPeerConnectionDelegate {
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        print("[WebRTC] Signaling state changed: \(stateChanged.rawValue)")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        print("[WebRTC] Stream added.")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        print("[WebRTC] Stream removed.")
    }
    
    func peerConnectionShouldTriggerIceRestart(_ peerConnection: RTCPeerConnection) {
        print("[WebRTC] ICE restart triggered.")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        print("[WebRTC] ICE Connection State changed: \(newState.rawValue)")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        print("[WebRTC] ICE Gathering State changed: \(newState.rawValue)")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        print("[WebRTC] Local ICE Candidate generated: \(candidate.sdp)")
        delegate?.webRTCManager(self, didGenerateLocalIceCandidate: candidate)
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {
        print("[WebRTC] Candidates removed.")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        print("[WebRTC] Data channel opened: \(dataChannel.label)")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChangeState newState: RTCPeerConnectionState) {
        print("[WebRTC] Peer Connection State changed: \(newState.rawValue)")
        delegate?.webRTCManager(self, didChangeConnectionState: newState)
    }
}

// ─── RTCDataChannelDelegate ───

extension WebRTCManager: RTCDataChannelDelegate {
    
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        print("[WebRTC] Data channel '\(dataChannel.label)' state changed: \(dataChannel.readyState.rawValue)")
    }
    
    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        delegate?.webRTCManager(self, didReceiveData: buffer.data, onChannel: dataChannel.label)
    }
}
