import SwiftUI
import WebRTC

/// A state-of-the-art SwiftUI Dashboard for Jump Desktop Clone Client.
/// Features a stunning glassmorphic UI, rich neon gradient background, pulsing glow animations,
/// and smooth transitions between connecting, streaming, and error states.
struct DashboardView: View {
    
    @StateObject private var coordinator: ClientConnectionCoordinator
    @State private var inputRoomId = ""
    @State private var isGlowAnimating = false
    
    private var inputCollector: InputCollector {
        InputCollector { data in
            coordinator.sendInputEvent(data)
        }
    }
    
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
        let serverURL = URL(string: "wss://127.0.0.1:8443")! // Defaults to localhost for development
        let mockToken = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJpUGFkQ2xpZW50Iiwicm9sZSI6ImNsaWVudCIsImlhdCI6MTcyMjIzODQ4MCwiZXhwIjoxODIyMjM4NDgwfQ.mockToken" // Mock test token
        let iceServers = ["turns:turn.yourdomain.hk:443?transport=tcp"]
        
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
            
            VStack(spacing: 30) {
                if coordinator.connectionState == .connected, let videoTrack = coordinator.activeVideoTrack {
                    // ─── Active Fullscreen Streaming State ───
                    ZStack {
                        VideoRendererView(videoTrack: videoTrack, inputCollector: inputCollector)
                            .cornerRadius(16)
                            .shadow(color: .purple.opacity(0.4), radius: 24, x: 0, y: 8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(LinearGradient(colors: [.purple.opacity(0.5), .clear], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                            )
                        
                        // Overlay HUD Dashboard bar
                        VStack {
                            HStack(spacing: 12) {
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(Color.green)
                                        .frame(width: 8, height: 8)
                                        .scaleEffect(isGlowAnimating ? 1.2 : 0.8)
                                        .animation(Animation.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isGlowAnimating)
                                    
                                    Text("원격 연결 중 (Live)")
                                        .font(.system(.subheadline, design: .rounded))
                                        .bold()
                                        .foregroundColor(.white)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(.ultraThinMaterial)
                                .cornerRadius(30)
                                
                                // Real-time Latency HUD Overlay
                                HStack(spacing: 6) {
                                    Image(systemName: "gauge.medium")
                                        .font(.system(size: 12))
                                        .foregroundColor(rttColor)
                                    
                                    Text(String(format: "RTT: %.1fms", coordinator.rttMs))
                                        .font(.system(.subheadline, design: .monospaced))
                                        .bold()
                                        .foregroundColor(rttColor)
                                        .shadow(color: rttColor.opacity(0.4), radius: 4)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(.ultraThinMaterial)
                                .cornerRadius(30)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 30)
                                        .stroke(rttColor.opacity(0.3), lineWidth: 1)
                                )
                                
                                Spacer()
                                
                                Button(action: {
                                    coordinator.disconnect()
                                }) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "power")
                                        Text("연결 종료")
                                    }
                                    .font(.system(.subheadline, design: .rounded))
                                    .bold()
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(Color.red.opacity(0.8))
                                    .cornerRadius(30)
                                }
                            }
                            .padding()
                            
                            Spacer()
                        }
                    }
                    .padding()
                    .transition(.asymmetric(insertion: .scale.combined(with: .opacity), removal: .opacity))
                    .onAppear {
                        isGlowAnimating = true
                    }
                    
                } else {
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
                            .font(.system(.headline, design: .rounded))
                            .foregroundColor(.white)
                            .bold()
                        
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
                                    .font(.system(.caption, design: .rounded))
                                    .foregroundColor(.purple)
                                    .bold()
                                    .multilineTextAlignment(.center)
                                
                                Button(action: {
                                    coordinator.disconnect()
                                }) {
                                    Text("취소")
                                        .font(.system(.footnote, design: .rounded))
                                        .foregroundColor(.red)
                                        .bold()
                                }
                            }
                            .padding(.top, 10)
                            
                        } else {
                            Button(action: {
                                guard inputRoomId.count >= 4 else { return }
                                coordinator.connect(roomId: inputRoomId.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
                            }) {
                                Text("연결 시작")
                                    .font(.system(.headline, design: .rounded))
                                    .foregroundColor(.white)
                                    .bold()
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
                                    .font(.system(.caption, design: .rounded))
                                    .foregroundColor(.red)
                                    .bold()
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
