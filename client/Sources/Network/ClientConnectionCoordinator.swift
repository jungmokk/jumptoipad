import Foundation
import WebRTC
import Combine
import UIKit

/// Connection states for remote stream
enum RemoteConnectionState: String {
    case idle = "대기 중 (Idle)"
    case connectingSignaling = "시그널링 서버 연결 중 (Connecting Signaling...)"
    case joiningRoom = "방 입장 중 (Joining Room...)"
    case establishingWebRTC = "WebRTC 터널링 구성 중 (Establishing WebRTC...)"
    case connected = "연결됨 (Connected)"
    case disconnected = "연결 끊김 (Disconnected)"
    case reconnecting = "재연결 시도 중 (Reconnecting...)"
    case failed = "연결 실패 (Failed)"
}

/// ClientConnectionCoordinator manages connection logic, exponential backoff reconnects,
/// and publishes the connection state and tracks for SwiftUI bindings.
class ClientConnectionCoordinator: NSObject, ObservableObject {
    
    @Published var connectionState: RemoteConnectionState = .idle
    @Published var activeVideoTrack: RTCVideoTrack?
    @Published var activeAudioTrack: RTCAudioTrack?
    @Published var rttMs: Double = 0.0
    
    private var signalingClient: SignalingClient?
    private var webRTCManager: WebRTCManager?
    
    private let serverURL: URL
    private let token: String
    private let iceServers: [String]
    private let turnUser: String
    private let turnPass: String
    
    private var activeRoomId: String?
    private var targetBitrateKbps: Int = 8000
    private var targetWidth: Int = 1920
    private var targetHeight: Int = 1080
    
    // ─── Exponential Backoff Reconnection Parameters ───
    private var isReconnecting = false
    private var reconnectAttempt = 0
    private let maxReconnectAttempts = 8
    private var reconnectWorkItem: DispatchWorkItem?
    
    // ─── Phase 5: Timers for latency metrics & clipboard ───
    private var pingTimer: Timer?
    private var clipboardTimer: Timer?
    private var lastSyncedClipboardText: String?
    
    /// Initialize with configuration details
    init(serverURL: URL, token: String, iceServers: [String], turnUser: String, turnPass: String) {
        self.serverURL = serverURL
        self.token = token
        self.iceServers = iceServers
        self.turnUser = turnUser
        self.turnPass = turnPass
        super.init()
    }
    
    /// Connect to the signaling server and join a room
    func connect(roomId: String, bitrateKbps: Int = 8000, width: Int = 1920, height: Int = 1080) {
        // Cancel any pending reconnect tasks
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        
        self.activeRoomId = roomId
        self.targetBitrateKbps = bitrateKbps
        self.targetWidth = width
        self.targetHeight = height
        
        self.isReconnecting = false
        self.reconnectAttempt = 0
        
        updateState(.connectingSignaling)
        
        // Setup clients
        self.signalingClient = SignalingClient(serverURL: serverURL, token: token)
        self.signalingClient?.delegate = self
        
        self.webRTCManager = WebRTCManager(iceServers: iceServers, turnUsername: turnUser, turnCredential: turnPass)
        self.webRTCManager?.delegate = self
        
        signalingClient?.connect()
    }
    
    /// Fully disconnect and release resources
    func disconnect() {
        print("[ClientCoordinator] User requested manual disconnect.")
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        activeRoomId = nil
        isReconnecting = false
        
        stopTimers()
        
        signalingClient?.disconnect()
        signalingClient = nil
        
        webRTCManager?.close()
        webRTCManager = nil
        
        AudioSessionManager.shared.deactivateAudioSession()
        
        DispatchQueue.main.async {
            self.activeVideoTrack = nil
            self.activeAudioTrack = nil
        }
        
        updateState(.idle)
    }
    
    func sendInputEvent(_ data: Data, reliable: Bool = true) {
        webRTCManager?.sendInputData(data, reliable: reliable)
    }
    
    // ─── Private Helpers ───
    
    private func updateState(_ state: RemoteConnectionState) {
        DispatchQueue.main.async {
            self.connectionState = state
            print("[ClientCoordinator] State transitioned to: \(state.rawValue)")
        }
    }
    
    /// Trigger reconnect attempt with exponential backoff delay (1s -> 2s -> 4s -> 8s -> max 30s)
    private func attemptReconnection() {
        guard let roomId = activeRoomId else { return }
        guard reconnectAttempt < maxReconnectAttempts else {
            print("[ClientCoordinator] Max reconnection attempts reached. Failing.")
            updateState(.failed)
            disconnect()
            return
        }
        
        isReconnecting = true
        reconnectAttempt += 1
        
        // Calculate backoff: 2^(attempt - 1) seconds
        let delaySeconds = pow(2.0, Double(reconnectAttempt - 1))
        let cappedDelay = min(delaySeconds, 30.0) // Cap at 30 seconds
        
        updateState(.reconnecting)
        print("[ClientCoordinator] Reconnect attempt \(reconnectAttempt)/\(maxReconnectAttempts) in \(cappedDelay) seconds...")
        
        // Cancel old work items
        reconnectWorkItem?.cancel()
        
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            print("[ClientCoordinator] Dispatching reconnect connection task for room \(roomId)...")
            
            // Close old peer connections cleanly before retrying
            self.webRTCManager?.close()
            self.signalingClient?.disconnect()
            
            // Re-establish connection
            self.signalingClient?.connect()
        }
        
        self.reconnectWorkItem = workItem
        DispatchQueue.global().asyncAfter(deadline: .now() + cappedDelay, execute: workItem)
    }
    
    // ─── Timer Helper Functions ───
    
    private func startPingTimer() {
        stopPingTimer()
        DispatchQueue.main.async {
            self.pingTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                self?.sendPing()
            }
        }
    }

    private func stopPingTimer() {
        DispatchQueue.main.async {
            self.pingTimer?.invalidate()
            self.pingTimer = nil
        }
    }

    private func sendPing() {
        let now = Date().timeIntervalSince1970
        let pingEvent = InputEvent(
            type: .ping,
            x: nil, y: nil, button: nil, state: nil, keyCode: nil, keyChar: nil, pressure: nil, tilt: nil,
            clipboardText: nil,
            timestamp: now
        )
        do {
            let data = try JSONEncoder().encode(pingEvent)
            sendInputEvent(data)
        } catch {
            print("[ClientCoordinator] Error encoding ping event: \(error)")
        }
    }

    private func startClipboardTimer() {
        stopClipboardTimer()
        DispatchQueue.main.async {
            // Keep track of the initial clipboard state so we don't send it recursively
            self.lastSyncedClipboardText = UIPasteboard.general.string
            
            self.clipboardTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.checkLocalClipboard()
            }
        }
    }

    private func stopClipboardTimer() {
        DispatchQueue.main.async {
            self.clipboardTimer?.invalidate()
            self.clipboardTimer = nil
        }
    }

    private func checkLocalClipboard() {
        DispatchQueue.main.async {
            guard let localText = UIPasteboard.general.string, !localText.isEmpty else { return }
            if localText != self.lastSyncedClipboardText {
                print("[ClientCoordinator] Local clipboard change detected: \(localText)")
                self.lastSyncedClipboardText = localText
                self.sendClipboard(text: localText)
            }
        }
    }

    private func sendClipboard(text: String) {
        let clipboardEvent = InputEvent(
            type: .clipboard,
            x: nil, y: nil, button: nil, state: nil, keyCode: nil, keyChar: nil, pressure: nil, tilt: nil,
            clipboardText: text,
            timestamp: nil
        )
        do {
            let data = try JSONEncoder().encode(clipboardEvent)
            sendInputEvent(data)
        } catch {
            print("[ClientCoordinator] Error encoding clipboard event: \(error)")
        }
    }

    private func stopTimers() {
        stopPingTimer()
        stopClipboardTimer()
    }
}

// ─── SignalingClientDelegate ───

extension ClientConnectionCoordinator: SignalingClientDelegate {
    
    func signalingClientDidConnect(_ client: SignalingClient) {
        print("[ClientCoordinator] Connected to signaling server. Waiting for welcome message...")
    }
    
    func signalingClientDidDisconnect(_ client: SignalingClient) {
        print("[ClientCoordinator] Signaling client disconnected.")
        if activeRoomId != nil {
            attemptReconnection()
        } else {
            updateState(.disconnected)
        }
    }
    
    func signalingClient(_ client: SignalingClient, didReceiveWelcome deviceId: String, role: String) {
        print("[ClientCoordinator] Welcome package unpacked. Device ID: \(deviceId)")
        guard let roomId = activeRoomId else { return }
        updateState(.joiningRoom)
        
        let settings: [String: Any] = [
            "bitrateKbps": targetBitrateKbps,
            "width": targetWidth,
            "height": targetHeight
        ]
        
        client.joinRoom(roomId: roomId, settings: settings)
    }
    
    func signalingClient(_ client: SignalingClient, didJoinRoom roomId: String) {
        updateState(.establishingWebRTC)
        
        // Ready PeerConnection to receive SDP offer from Host
        webRTCManager?.setupPeerConnection()
    }
    
    func signalingClient(_ client: SignalingClient, didPeerJoin deviceId: String) {
        // Handled on Host, Client ignores
    }
    
    func signalingClient(_ client: SignalingClient, didPeerLeave deviceId: String) {
        print("[ClientCoordinator] Host left the room. Disconnecting.")
        disconnect()
    }
    
    func signalingClient(_ client: SignalingClient, didReceiveSDPOffer sdp: String) {
        print("[ClientCoordinator] Received SDP Offer from Host. Passing to WebRTC manager...")
        webRTCManager?.handleRemoteOffer(sdp: sdp)
    }
    
    func signalingClient(_ client: SignalingClient, didReceiveSDPAnswer sdp: String) {
        // Client only sends answers, ignores incoming answers
    }
    
    func signalingClient(_ client: SignalingClient, didReceiveICECandidate candidate: [String : Any]) {
        guard let sdp = candidate["candidate"] as? String,
              let sdpMid = candidate["sdpMid"] as? String,
              let sdpMLineIndex = candidate["sdpMLineIndex"] as? Int32 else { return }
        
        webRTCManager?.addRemoteIceCandidate(sdpMid: sdpMid, sdpMLineIndex: sdpMLineIndex, candidate: sdp)
    }
    
    func signalingClient(_ client: SignalingClient, didReceiveError error: String) {
        print("[ClientCoordinator] Signaling server reported error: \(error)")
        if error.contains("Room not found") {
            // Room invalid or destroyed, fail immediately without endless retries
            updateState(.failed)
            disconnect()
        }
    }
}

// ─── WebRTCManagerDelegate ───

extension ClientConnectionCoordinator: WebRTCManagerDelegate {
    
    func webRTCManager(_ manager: WebRTCManager, didChangeConnectionState state: RTCPeerConnectionState) {
        print("[ClientCoordinator] Peer connection state transitioned to: \(state.rawValue)")
        
        switch state {
        case .connected:
            updateState(.connected)
            // Reset backoff on successful connection
            reconnectAttempt = 0
            isReconnecting = false
            startPingTimer()
            startClipboardTimer()
        case .disconnected:
            stopTimers()
            if activeRoomId != nil {
                attemptReconnection()
            } else {
                updateState(.disconnected)
            }
        case .failed:
            stopTimers()
            if activeRoomId != nil {
                attemptReconnection()
            } else {
                updateState(.failed)
            }
        default:
            break
        }
    }
    
    func webRTCManager(_ manager: WebRTCManager, didGenerateLocalIceCandidate candidate: RTCIceCandidate) {
        // 1. Send the original WebRTC generated candidate
        signalingClient?.sendICECandidate(
            sdpMid: candidate.sdpMid ?? "",
            sdpMLineIndex: candidate.sdpMLineIndex,
            candidate: candidate.sdp
        )
        
        // 2. Scan all local network interfaces (including VPN / Tailscale 100.x.x.x)
        // and replicate this candidate for each IP, overriding the connection address.
        // This bypasses WebRTC's default filtering of VPN/tun virtual interfaces on iOS.
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
                        print("[ClientCoordinator] Replicating ICE Candidate for VPN/Tailscale interface (\(ip)): \(modifiedSdp)")
                        signalingClient?.sendICECandidate(
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
        print("[ClientCoordinator] Local SDP Answer generated. Relaying back to Host...")
        signalingClient?.sendSDPAnswer(sdp: sdp)
    }
    
    func webRTCManager(_ manager: WebRTCManager, didReceiveVideoTrack videoTrack: RTCVideoTrack) {
        print("[ClientCoordinator] Received active video stream track from Host.")
        DispatchQueue.main.async {
            self.activeVideoTrack = videoTrack
        }
    }
    
    func webRTCManager(_ manager: WebRTCManager, didReceiveAudioTrack audioTrack: RTCAudioTrack) {
        print("[ClientCoordinator] Received active audio stream track from Host. Initializing system speaker routing...")
        DispatchQueue.main.async {
            self.activeAudioTrack = audioTrack
        }
        
        // Prepare iPad audio components dynamically
        AudioSessionManager.shared.configureAudioSession()
    }
    
    func webRTCManager(_ manager: WebRTCManager, didOpenDataChannel channel: RTCDataChannel) {
        print("[ClientCoordinator] Shared input control data channel is open and ready.")
    }
    
    func webRTCManager(_ manager: WebRTCManager, didReceiveData data: Data, onChannel channelName: String) {
        // Only parse incoming packets on "input_control"
        guard channelName == "input_control" else { return }
        
        do {
            let decoder = JSONDecoder()
            let event = try decoder.decode(InputEvent.self, from: data)
            
            switch event.type {
            case .pong:
                if let timestamp = event.timestamp {
                    let now = Date().timeIntervalSince1970
                    let rtt = (now - timestamp) * 1000.0
                    DispatchQueue.main.async {
                        self.rttMs = rtt
                    }
                }
            case .clipboard:
                if let text = event.clipboardText {
                    print("[ClientCoordinator] Received remote clipboard content: \(text)")
                    self.lastSyncedClipboardText = text
                    DispatchQueue.main.async {
                        UIPasteboard.general.string = text
                    }
                }
            default:
                break
            }
        } catch {
            print("[ClientCoordinator] Error decoding incoming data channel package: \(error.localizedDescription)")
        }
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
