import SwiftUI
import WebRTC

/// A state-of-the-art SwiftUI Dashboard for Jump Desktop Clone Client.
/// Features a stunning glassmorphic UI, rich neon gradient background, pulsing glow animations,
/// and smooth transitions between connecting, streaming, and error states.
struct DashboardView: View {
    
    @StateObject private var coordinator: ClientConnectionCoordinator
    @State private var inputRoomId = "JUMPTOIPAD"
    @State private var isGlowAnimating = false
    // IMPORTANT: @State으로 저장하여 SwiftUI 리렌더 시마다 새 인스턴스가 생성되는 치명적 버그 방지
    @State private var inputCollector: InputCollector? = nil
    
    @State private var isHudVisible = false
    
    // Add Bitrate State
    @State private var selectedBitrateKbps: Int = 8000
    private let bitrateOptions: [(name: String, value: Int)] = [
        ("2Mbps", 2000),
        ("4Mbps", 4000),
        ("8Mbps", 8000),
        ("12Mbps", 12000)
    ]
    
    private var rttColor: Color {
        if coordinator.rttMs < 50.0 {
            return Color(red: 0.0, green: 1.0, blue: 0.5) // Neon Green-ish
        } else if coordinator.rttMs < 100.0 {
            return Color(red: 1.0, green: 0.6, blue: 0.0) // Neon Orange
        } else {
            return Color(red: 1.0, green: 0.2, blue: 0.2) // Neon Red
        }
    }
    
    /// Pre-configured local parameters (can be configured via settings menu in the future)
    init() {
        let serverURL = URL(string: "ws://100.119.136.35:8443")! // Connected over Tailscale VPN
        let mockToken = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJpUGFkQ2xpZW50Iiwicm9sZSI6ImNsaWVudCIsImlhdCI6MTcyMjIzODQ4MCwiZXhwIjoxODIyMjM4NDgwfQ.mockToken" // Mock test token
        let iceServers = [
            "stun:stun.l.google.com:19302",
            "turns:turn.yourdomain.hk:443?transport=tcp"
        ]
        
        _coordinator = StateObject(wrappedValue: ClientConnectionCoordinator(
            serverURL: serverURL,
            token: mockToken,
            iceServers: iceServers,
            turnUser: "jumpdesktop",
            turnPass: "changeme"
        ))
    }
    
    var body: some View {
        ZStack {
            // ─── Modern Premium Neon Gradient Background ───
            Color(red: 0.05, green: 0.05, blue: 0.08)
                .ignoresSafeArea()
            
            // Atmospheric dynamic glows
            Circle()
                .fill(LinearGradient(colors: [.indigo, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 450, height: 450)
                .blur(radius: 90)
                .opacity(0.15)
                .offset(x: -150, y: -200)
            
            Circle()
                .fill(LinearGradient(colors: [.purple, .pink], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 400, height: 400)
                .blur(radius: 90)
                .opacity(0.12)
                .offset(x: 200, y: 250)
            
            if coordinator.connectionState == .connected, let videoTrack = coordinator.activeVideoTrack {
                // ─── Active Fullscreen Streaming State ───
                ZStack {
                    VideoRendererView(videoTrack: videoTrack, inputCollector: inputCollector ?? InputCollector { _, _ in })
                        .ignoresSafeArea()
                    
                    // ─── Top Auto-Hiding HUD ───
                    VStack {
                        VStack(spacing: 0) {
                            // Actual HUD Box
                            HStack {
                                // Connection Status
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(coordinator.connectionState == .connected ? Color.green : Color.red)
                                        .frame(width: 8, height: 8)
                                    Text(coordinator.connectionState.rawValue)
                                        .font(.system(.subheadline, design: .rounded))
                                        .bold()
                                        .foregroundColor(coordinator.connectionState == .connected ? Color.green : Color.red)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(.ultraThinMaterial)
                                .cornerRadius(30)
                                
                                // RTT Status
                                HStack(spacing: 6) {
                                    Image(systemName: "wifi")
                                        .font(.system(size: 12, weight: .bold))
                                    Text(String(format: "%.1f ms", coordinator.rttMs))
                                        .font(.system(.subheadline, design: .monospaced))
                                        .bold()
                                }
                                .foregroundColor(rttColor)
                                .shadow(color: rttColor.opacity(0.4), radius: 4)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(.ultraThinMaterial)
                                .cornerRadius(30)
                                .overlay(RoundedRectangle(cornerRadius: 30).stroke(rttColor.opacity(0.3), lineWidth: 1))
                                
                                Spacer()
                                
                                // Disconnect Button
                                Button(action: {
                                    coordinator.disconnect()
                                }) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "power")
                                        Text("연결 종료").bold()
                                    }
                                    .font(.system(.subheadline, design: .rounded))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(Color.red.opacity(0.8))
                                    .cornerRadius(30)
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.top, 10)
                            .padding(.bottom, 10)
                            .opacity(isHudVisible ? 1 : 0)
                            .frame(height: isHudVisible ? nil : 0)
                            .clipped()
                            
                            // Pull-Tab Hint
                            Capsule()
                                .fill(Color.white.opacity(isHudVisible ? 0.0 : 0.3))
                                .frame(width: 40, height: 4)
                                .padding(.top, isHudVisible ? 0 : 8)
                        }
                        .background(
                            Rectangle()
                                .fill(Color.black.opacity(0.001)) // Invisible hit target
                        )
                        .offset(y: isHudVisible ? 0 : -10)
                        .onHover { isHovering in
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                                isHudVisible = isHovering
                            }
                        }
                        .onTapGesture {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                                isHudVisible.toggle()
                            }
                            if isHudVisible {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                                    if !isHudVisible { return } // Might have been hovered
                                    withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                                        isHudVisible = false
                                    }
                                }
                            }
                        }
                        
                        Spacer()
                    }
                    .transition(.asymmetric(insertion: .scale.combined(with: .opacity), removal: .opacity))
                    .onAppear {
                        isGlowAnimating = true
                        // inputCollector가 아직 없으면 coordinator와 연결된 인스턴스를 생성
                        if inputCollector == nil {
                            inputCollector = InputCollector { [weak coordinator] data, reliable in
                                coordinator?.sendInputEvent(data, reliable: reliable)
                            }
                        }
                    }
                } // End ZStack for streaming state
            } else {
                VStack(spacing: 30) {
                    // ─── Connection Panel & Setup View ───
                    Spacer()
                    
                    VStack(spacing: 12) {
                        Image(systemName: "macwindow.on.ipad")
                            .font(.system(size: 64))
                            .foregroundStyle(LinearGradient(colors: [.purple, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .shadow(color: .purple.opacity(0.5), radius: 16)
                            .padding(.bottom, 10)
                        
                        Text("JUMP DESKTOP CLONE")
                            .font(.system(size: 28, weight: .black, design: .rounded))
                            .tracking(2)
                            .foregroundColor(.white)
                        
                        Text("macOS 호스트 화면을 iPadOS에서 초저지연으로 제어합니다.")
                            .font(.system(.subheadline, design: .rounded))
                            .foregroundColor(.gray)
                    }
                    .padding(.top, 40)
                    
                    // Glassmorphic setup card
                    VStack(spacing: 24) {
                        Text("호스트 서버 연결")
                            .bold()
                            .font(.system(.headline, design: .rounded))
                            .foregroundColor(.white)
                        
                        // Room ID Input Box
                        HStack {
                            Image(systemName: "key.fill")
                                .foregroundColor(.purple)
                                .frame(width: 32)
                            
                            TextField("Room ID 입력 (8자리)", text: $inputRoomId)
                                .autocapitalization(.allCharacters)
                                .disableAutocorrection(true)
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.white)
                                .accentColor(.purple)
                        }
                        .padding()
                        .background(Color.white.opacity(0.06))
                        .cornerRadius(12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.white.opacity(0.12), lineWidth: 1)
                        )
                        
                        // Streaming Quality Picker
                        VStack(alignment: .leading, spacing: 8) {
                            Text("스트리밍 품질")
                                .font(.system(.caption, design: .rounded))
                                .foregroundColor(.gray)
                                .padding(.leading, 4)
                            
                            Picker("Bitrate", selection: $selectedBitrateKbps) {
                                ForEach(bitrateOptions, id: \.value) { option in
                                    Text(option.name).tag(option.value)
                                }
                            }
                            .pickerStyle(SegmentedPickerStyle())
                            .background(Color.white.opacity(0.1))
                            .cornerRadius(8)
                        }
                        
                        // Connect Button
                        if coordinator.connectionState == .connectingSignaling || 
                            coordinator.connectionState == .joiningRoom || 
                            coordinator.connectionState == .establishingWebRTC ||
                            coordinator.connectionState == .reconnecting {
                            
                            VStack(spacing: 12) {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .purple))
                                    .scaleEffect(1.2)
                                
                                Text(coordinator.connectionState.rawValue)
                                    .bold()
                                    .font(.system(.caption, design: .rounded))
                                    .foregroundColor(.purple)
                                    .multilineTextAlignment(.center)
                                
                                Button(action: {
                                    coordinator.disconnect()
                                }) {
                                    Text("취소")
                                        .bold()
                                        .font(.system(.footnote, design: .rounded))
                                        .foregroundColor(.red)
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 8)
                                        .contentShape(Rectangle())
                                }
                                .disabled(coordinator.connectionState == .connectingSignaling)
                                .opacity(coordinator.connectionState == .connectingSignaling ? 0.5 : 1.0)
                            }
                            .padding(.top, 10)
                            
                        } else {
                            Button(action: {
                                guard inputRoomId.count >= 4 else { return }
                                
                                #if os(iOS)
                                let screenBounds = UIScreen.main.bounds
                                let screenScale = UIScreen.main.scale
                                let targetWidth = Int(screenBounds.width * screenScale)
                                let targetHeight = Int(screenBounds.height * screenScale)
                                #else
                                let targetWidth = 1920
                                let targetHeight = 1080
                                #endif
                                
                                coordinator.connect(
                                    roomId: inputRoomId.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
                                    bitrateKbps: selectedBitrateKbps,
                                    width: targetWidth,
                                    height: targetHeight
                                )
                            }) {
                                Text("연결 시작")
                                    .bold()
                                    .font(.system(.headline, design: .rounded))
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(
                                        LinearGradient(colors: [.purple, .indigo], startPoint: .leading, endPoint: .trailing)
                                    )
                                    .cornerRadius(12)
                                    .shadow(color: .purple.opacity(0.4), radius: 12, x: 0, y: 4)
                            }
                            .disabled(inputRoomId.count < 4)
                            .opacity(inputRoomId.count < 4 ? 0.5 : 1.0)
                        }
                        
                        // Connection State Overlay if failed/disconnected
                        if coordinator.connectionState == .failed || coordinator.connectionState == .disconnected {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.red)
                                
                                Text("오류: \(coordinator.connectionState.rawValue)")
                                    .bold()
                                    .font(.system(.caption, design: .rounded))
                                    .foregroundColor(.red)
                            }
                            .padding(.top, 4)
                        }
                    }
                    .padding(30)
                    .background(.ultraThinMaterial)
                    .cornerRadius(24)
                    .overlay(
                        RoundedRectangle(cornerRadius: 24)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
                    .padding(.horizontal, 24)
                    .frame(maxWidth: 500)
                    
                    Spacer()
                    
                    // Footer details
                    Text("Powered by WebRTC, ScreenCaptureKit, & Antigravity Core")
                        .font(.system(.caption2, design: .rounded))
                        .foregroundColor(.gray.opacity(0.6))
                        .padding(.bottom, 20)
                }
            }
        }
        .preferredColorScheme(.dark) // Always dark premium mode
    }
}

// ─── Preview Support ───
struct DashboardView_Previews: PreviewProvider {
    static var previews: some View {
        DashboardView()
    }
}
