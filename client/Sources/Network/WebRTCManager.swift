import Foundation
import WebRTC

/// Delegate protocol for Client WebRTCManager events.
protocol WebRTCManagerDelegate: AnyObject {
    func webRTCManager(_ manager: WebRTCManager, didChangeConnectionState state: RTCPeerConnectionState)
    func webRTCManager(_ manager: WebRTCManager, didGenerateLocalIceCandidate candidate: RTCIceCandidate)
    func webRTCManager(_ manager: WebRTCManager, didDiscoverLocalSdp sdp: String)
    func webRTCManager(_ manager: WebRTCManager, didReceiveVideoTrack videoTrack: RTCVideoTrack)
    func webRTCManager(_ manager: WebRTCManager, didReceiveAudioTrack audioTrack: RTCAudioTrack)
    func webRTCManager(_ manager: WebRTCManager, didOpenDataChannel channel: RTCDataChannel)
    func webRTCManager(_ manager: WebRTCManager, didReceiveData data: Data, onChannel channelName: String)
}

/// WebRTCManager manages the RTCPeerConnection, ICE gathering, track rendering, and input control for the iPadOS Client.
class WebRTCManager: NSObject {
    
    weak var delegate: WebRTCManagerDelegate?
    
    let peerConnectionFactory: RTCPeerConnectionFactory
    private var peerConnection: RTCPeerConnection?
    private var dataChannel: RTCDataChannel?
    private var unreliableDataChannel: RTCDataChannel?
    
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
    
    /// Sets up the RTCPeerConnection for the Client
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
        
        // Configure WebRTC constraints to expect incoming video and audio tracks
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueTrue,
                kRTCMediaConstraintsOfferToReceiveVideo: kRTCMediaConstraintsValueTrue
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
        print("[WebRTC] PeerConnection set up successfully.")
    }
    
    /// Set remote SDP Offer and create SDP Answer
    func handleRemoteOffer(sdp: String) {
        guard let connection = peerConnection else { return }
        
        let remoteSdp = RTCSessionDescription(type: .offer, sdp: sdp)
        connection.setRemoteDescription(remoteSdp) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                print("[WebRTC] Error setting remote offer: \(error.localizedDescription)")
                return
            }
            
            print("[WebRTC] Remote Offer set successfully. Creating Answer...")
            self.createAnswer()
        }
    }
    
    private func createAnswer() {
        guard let connection = peerConnection else { return }
        
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueTrue,
                kRTCMediaConstraintsOfferToReceiveVideo: kRTCMediaConstraintsValueTrue
            ],
            optionalConstraints: nil
        )
        
        connection.answer(for: constraints) { [weak self] sdpDescription, error in
            guard let self = self else { return }
            if let error = error {
                print("[WebRTC] Error creating answer: \(error.localizedDescription)")
                return
            }
            
            guard let localSdp = sdpDescription else { return }
            
            connection.setLocalDescription(localSdp) { error in
                if let error = error {
                    print("[WebRTC] Error setting local SDP: \(error.localizedDescription)")
                    return
                }
                
                print("[WebRTC] Answer created and set as LocalDescription.")
                self.delegate?.webRTCManager(self, didDiscoverLocalSdp: localSdp.sdp)
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
    
    /// Send remote control input data via the "input_control" DataChannel
    func sendInputData(_ data: Data, reliable: Bool = true) {
        let buffer = RTCDataBuffer(data: data, isBinary: true)
        if reliable {
            if let channel = dataChannel, channel.readyState == .open {
                channel.sendData(buffer)
            } else {
                print("[WebRTC] Error: Reliable input control data channel is not open.")
            }
        } else {
            if let channel = unreliableDataChannel, channel.readyState == .open {
                channel.sendData(buffer)
            } else {
                print("[WebRTC] Error: Unreliable input control data channel is not open.")
            }
        }
    }
    
    /// Close the WebRTC peer connection
    func close() {
        dataChannel?.close()
        dataChannel = nil
        peerConnection?.close()
        peerConnection = nil
        print("[WebRTC] Connection closed.")
    }
}

// ─── RTCPeerConnectionDelegate ───

extension WebRTCManager: RTCPeerConnectionDelegate {
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        print("[WebRTC] Signaling state changed: \(stateChanged.rawValue)")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        print("[WebRTC] Stream added. Tracks - Video: \(stream.videoTracks.count), Audio: \(stream.audioTracks.count)")
        
        if let videoTrack = stream.videoTracks.first {
            delegate?.webRTCManager(self, didReceiveVideoTrack: videoTrack)
        }
        if let audioTrack = stream.audioTracks.first {
            delegate?.webRTCManager(self, didReceiveAudioTrack: audioTrack)
        }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        print("[WebRTC] Stream removed.")
    }
    
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        print("[WebRTC] Peer connection should negotiate.")
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
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen channel: RTCDataChannel) {
        print("[WebRTC] Data channel opened remotely: \(channel.label)")
        if channel.label == "input_control" {
            self.dataChannel = channel
            channel.delegate = self
            delegate?.webRTCManager(self, didOpenDataChannel: channel)
        } else if channel.label == "input_control_unreliable" {
            self.unreliableDataChannel = channel
            channel.delegate = self
        }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
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
