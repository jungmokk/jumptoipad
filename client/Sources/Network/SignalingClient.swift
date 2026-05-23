import Foundation

/// Delegate protocol for Client SignalingClient events.
protocol SignalingClientDelegate: AnyObject {
    func signalingClientDidConnect(_ client: SignalingClient)
    func signalingClientDidDisconnect(_ client: SignalingClient)
    func signalingClient(_ client: SignalingClient, didReceiveWelcome deviceId: String, role: String)
    func signalingClient(_ client: SignalingClient, didJoinRoom roomId: String)
    func signalingClient(_ client: SignalingClient, didPeerJoin deviceId: String)
    func signalingClient(_ client: SignalingClient, didPeerLeave deviceId: String)
    func signalingClient(_ client: SignalingClient, didReceiveSDPOffer sdp: String)
    func signalingClient(_ client: SignalingClient, didReceiveSDPAnswer sdp: String)
    func signalingClient(_ client: SignalingClient, didReceiveICECandidate candidate: [String: Any])
    func signalingClient(_ client: SignalingClient, didReceiveError error: String)
}

/// A robust WebSocket-based signaling client for Jump Desktop Clone (iPadOS Client).
/// Uses Apple's native `URLSessionWebSocketTask` for maximum performance and low power consumption.
class SignalingClient: NSObject {
    
    weak var delegate: SignalingClientDelegate?
    
    private let serverURL: URL
    private let token: String
    private var webSocketTask: URLSessionWebSocketTask?
    private lazy var urlSession = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    
    private var isConnected = false
    private var pingTimer: Timer?
    private let workQueue = DispatchQueue(label: "com.jumpdesktop.client.signaling", qos: .userInitiated)
    
    /// Initialize with signaling server URL and JWT authorization token
    init(serverURL: URL, token: String) {
        self.serverURL = serverURL
        self.token = token
        super.init()
    }
    
    /// Connect to the WebSocket signaling server
    func connect() {
        workQueue.async { [weak self] in
            guard let self = self else { return }
            // Perform synchronous cleanup instead of calling async disconnect()
            self.stopPingTimer()
            self.webSocketTask?.cancel(with: .normalClosure, reason: nil)
            self.webSocketTask = nil
            self.isConnected = false
            
            // Build authenticated WSS request with token query parameter
            var components = URLComponents(url: self.serverURL, resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "token", value: self.token)]
            
            guard let authenticatedURL = components?.url else {
                print("[Signaling] Failed to construct authenticated URL.")
                return
            }
            
            var request = URLRequest(url: authenticatedURL)
            request.timeoutInterval = 10.0
            
            print("[Signaling] Connecting to \(authenticatedURL.host ?? "server")...")
            self.webSocketTask = self.urlSession.webSocketTask(with: request)
            self.webSocketTask?.resume()
            self.listen()
        }
    }
    
    /// Disconnect from the signaling server
    func disconnect() {
        workQueue.async { [weak self] in
            guard let self = self else { return }
            self.stopPingTimer()
            self.webSocketTask?.cancel(with: .normalClosure, reason: nil)
            self.webSocketTask = nil
            if self.isConnected {
                self.isConnected = false
                self.delegate?.signalingClientDidDisconnect(self)
            }
        }
    }
    
    /// Join an existing room on the signaling server using roomId
    func joinRoom(roomId: String, settings: [String: Any]? = nil) {
        sendMessage(type: "join_room", roomId: roomId, payload: settings)
    }
    
    /// Send SDP Answer to the remote host
    func sendSDPAnswer(sdp: String) {
        let payload: [String: Any] = [
            "type": "answer",
            "sdp": sdp
        ]
        sendMessage(type: "sdp_answer", payload: payload)
    }
    
    /// Send ICE Candidate to the remote host
    func sendICECandidate(sdpMid: String, sdpMLineIndex: Int32, candidate: String) {
        let payload: [String: Any] = [
            "sdpMid": sdpMid,
            "sdpMLineIndex": sdpMLineIndex,
            "candidate": candidate
        ]
        sendMessage(type: "ice_candidate", payload: payload)
    }
    
    // ─── Private Helpers ───
    
    private func listen() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleIncomingMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleIncomingMessage(text)
                    }
                @unknown default:
                    break
                }
                self.listen() // Continue listening
            case .failure(let error):
                print("[Signaling] Connection failure: \(error.localizedDescription)")
                self.disconnect()
            }
        }
    }
    
    private func handleIncomingMessage(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        do {
            if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let type = json["type"] as? String {
                
                switch type {
                case "welcome":
                    if let deviceId = json["deviceId"] as? String, let role = json["role"] as? String {
                        self.isConnected = true
                        self.startPingTimer()
                        delegate?.signalingClient(self, didReceiveWelcome: deviceId, role: role)
                    }
                case "room_joined":
                    if let roomId = json["roomId"] as? String {
                        delegate?.signalingClient(self, didJoinRoom: roomId)
                    }
                case "peer_joined":
                    if let deviceId = json["deviceId"] as? String {
                        delegate?.signalingClient(self, didPeerJoin: deviceId)
                    }
                case "peer_left":
                    if let deviceId = json["deviceId"] as? String {
                        delegate?.signalingClient(self, didPeerLeave: deviceId)
                    }
                case "sdp_offer":
                    if let payload = json["payload"] as? [String: Any], let sdp = payload["sdp"] as? String {
                        delegate?.signalingClient(self, didReceiveSDPOffer: sdp)
                    }
                case "sdp_answer":
                    if let payload = json["payload"] as? [String: Any], let sdp = payload["sdp"] as? String {
                        delegate?.signalingClient(self, didReceiveSDPAnswer: sdp)
                    }
                case "ice_candidate":
                    if let payload = json["payload"] as? [String: Any] {
                        delegate?.signalingClient(self, didReceiveICECandidate: payload)
                    }
                case "pong":
                    // Heartbeat acknowledgment, do nothing
                    break
                case "error":
                    if let errorMessage = json["message"] as? String {
                        delegate?.signalingClient(self, didReceiveError: errorMessage)
                    }
                default:
                    print("[Signaling] Warning: Unrecognized message type '\(type)'.")
                }
            }
        } catch {
            print("[Signaling] Error parsing incoming message: \(error.localizedDescription)")
        }
    }
    
    private func sendMessage(type: String, roomId: String? = nil, payload: [String: Any]? = nil) {
        workQueue.async { [weak self] in
            guard let self = self, self.isConnected else { return }
            
            var message: [String: Any] = ["type": type]
            if let roomId = roomId {
                message["roomId"] = roomId
            }
            if let payload = payload {
                message["payload"] = payload
            }
            
            do {
                let data = try JSONSerialization.data(withJSONObject: message, options: [])
                if let jsonString = String(data: data, encoding: .utf8) {
                    self.webSocketTask?.send(.string(jsonString)) { error in
                        if let error = error {
                            print("[Signaling] Send error: \(error.localizedDescription)")
                        }
                    }
                }
            } catch {
                print("[Signaling] Error serializing message: \(error.localizedDescription)")
            }
        }
    }
    
    private func startPingTimer() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.stopPingTimer()
            self.pingTimer = Timer.scheduledTimer(withTimeInterval: 20.0, repeats: true) { [weak self] _ in
                self?.sendMessage(type: "ping")
            }
        }
    }
    
    private func stopPingTimer() {
        pingTimer?.invalidate()
        pingTimer = nil
    }
}

// ─── URLSessionWebSocketDelegate ───

extension SignalingClient: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        print("[Signaling] WebSocket connection established.")
        delegate?.signalingClientDidConnect(self)
    }
    
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWithCode closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        print("[Signaling] WebSocket connection closed with code: \(closeCode.rawValue).")
        self.disconnect()
    }
}
