import SwiftUI

@main
struct HostApp: App {
    @State private var coordinator: HostConnectionCoordinator?
    @State private var isRunning = false
    
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 20) {
                Image(systemName: "macwindow.on.ipad")
                    .font(.system(size: 48))
                    .foregroundColor(.purple)
                
                Text("Jump To Ipad - Host App")
                    .font(.title2)
                    .bold()
                
                Text(isRunning ? "호스트 스트리밍 서버가 가동 중입니다." : "서버에 연결하는 중...")
                    .foregroundColor(.secondary)
                    .font(.subheadline)
                
                if isRunning {
                    Text("iPadOS Client 앱에 연결 가능한 상태입니다.\n콘솔 로그에서 Room ID를 확인해 주세요.")
                        .font(.caption)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                }
                
                Button(action: {
                    if isRunning {
                        coordinator?.stop()
                        isRunning = false
                    } else {
                        startCoordinator()
                    }
                }) {
                    Text(isRunning ? "서버 중지" : "서버 시작")
                        .bold()
                        .frame(width: 120)
                }
                .buttonStyle(.borderedProminent)
                .accentColor(isRunning ? .red : .purple)
            }
            .frame(width: 360, height: 260)
            .padding()
            .onAppear {
                AccessibilityHelper.requestAccessibilityPermission()
                AccessibilityHelper.requestScreenCapturePermission()
                AccessibilityHelper.requestAudioCapturePermission()
                startCoordinator()
            }
            .onDisappear {
                coordinator?.stop()
            }
        }
    }
    
    private func startCoordinator() {
        // Defaults to localhost signaling port 8443
        let serverURL = URL(string: "ws://127.0.0.1:8443")!
        let mockToken = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJtYWNNaW5pSG9zdCIsInJvbGUiOiJob3N0IiwiaWF0IjoxNzIyMjM4NDgwLCJleHAiOjE4MjIyMzg0ODB9.mockToken"
        let iceServers = [
            "stun:stun.l.google.com:19302",
            "turns:turn.yourdomain.hk:443?transport=tcp"
        ]
        
        let coordinator = HostConnectionCoordinator(
            serverURL: serverURL,
            token: mockToken,
            iceServers: iceServers,
            turnUser: "jumpdesktop",
            turnPass: "changeme"
        )
        self.coordinator = coordinator
        coordinator.start()
        self.isRunning = true
    }
}
