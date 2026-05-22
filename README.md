# 🖥️ Jump Desktop Clone (맥미니-아이패드 초저지연 무선 원격 제어 프로그램)

본 프로젝트는 중국 내 네트워크 장벽(GFW) 및 VPN 운영 환경에 완벽 대응하여, 모니터가 연결되지 않은 맥미니(Host) 화면과 소리를 아이패드(Client)에서 초저지연으로 스트리밍하고 원격 제어하는 솔루션입니다.

---

## 🛠️ 1. 기술 스택 & 구성 요소

| 컴포넌트 | 대상 환경 | 핵심 기술 및 프레임워크 |
| --- | --- | --- |
| **Host App** | macOS 12+ | Swift, ScreenCaptureKit (비디오/오디오 루프백 캡처), CoreGraphics Private APIs (가상 디스플레이 구동 및 CGEvent 입력 주입), stasel/WebRTC |
| **Client App** | iPadOS 15+ | Swift, SwiftUI, Metal (RTCMTLVideoView 고속 비디오 렌더링), AVFoundation (오디오 재생), stasel/WebRTC |
| **Signaling Server** | Node.js | TypeScript, ws (WebSocket over WSS), jsonwebtoken (JWT HS256 보안 인증) |
| **Network (P2P)** | WebRTC | Coturn (TURNS / TLS over TCP 443), SCTP (DataChannel 입력 및 클립보드 초저지연 동기화) |

---

## 🌐 2. 중국 GFW 및 Astrill VPN 대응 핵심 전략

중국 내에서 맥미니에 **Astrill VPN**이 항시 켜져 있을 때 발생하는 **Hairpinning(트래픽 해외 우회로 인한 300ms+ 지연)** 현상을 극복하기 위한 설계가 반영되어 있습니다.

```
[권장] 3단계 지연율 최적화 연결 (Latency-Optimized Tiers)
🥇 Tier 1: 동일 Wi-Fi 로컬 P2P 연결 ➔ 지연 시간 < 5ms (VPN 무관)
🥈 Tier 2: 외부망 P2P + VPN 분할 터널링 ➔ 지연 시간 10~30ms (직접 매핑)
🥉 Tier 3: 홍콩 TLS TURN 릴레이 (TCP 443 포트HTTPS 위장) ➔ 지연 시간 30~80ms
```

### 🔧 VPN 분할 터널링 설정 방법 (맥미니 필수 적용)
1. 맥미니에서 **Astrill VPN** 앱을 엽니다.
2. **Settings** ➔ **Application Filter** 메뉴로 이동합니다.
3. 모드를 **"Exclude these apps"** (지정 앱 제외)로 설정합니다.
4. 목록에 빌드된 **HostApp.app**을 추가하고 적용(OK)합니다.
5. *결과*: HostApp의 WebRTC 직접 연결 통신만 VPN 터널을 우회하여 중국 공인 IP를 직접 타므로 10~30ms 수준의 최적 지연율(RTT)을 보장합니다.

---

## 🚀 3. 테스트 및 구축 가이드

### 1단계: 로컬 네트워크 테스트 (동일 Wi-Fi 내부)
가장 쉽고 빠르게 전체 기능(스트리밍, 입력 제어, 양방향 클립보드)을 검증할 수 있는 방법입니다.

1. **맥미니 로컬 IP 확인**: 맥미니 `시스템 설정 > 네트워크` 또는 터미널 `ifconfig`로 IP(예: `192.168.0.15`)를 확인합니다.
2. **클라이언트 주소 설정**: `client/Sources/UI/DashboardView.swift` 파일의 `serverURL`을 맥미니 IP로 변경합니다.
   ```swift
   let serverURL = URL(string: "wss://192.168.0.15:8443")!
   ```
3. **서버 실행**: 맥미니 터미널에서 `server/` 디렉토리로 이동하여 의존성 설치 후 구동합니다.
   ```bash
   npm install && npm run build && npm run start
   ```
4. **호스트 실행**: 맥미니 `host/HostApp.xcodeproj`를 빌드 및 실행합니다.
   - **중요**: macOS 팝업이 뜨면 **화면 기록(ScreenCaptureKit)** 및 **손쉬운 사용(Accessibility - CGEvent)** 권한을 반드시 수락해 주어야 합니다.
5. **클라이언트 실행**: 아이패드 `client/ClientApp.xcodeproj`를 실제 기기에 빌드/설치하고 실행한 뒤, 호스트의 **8자리 Room ID**를 입력해 연결을 테스트합니다.

---

### 2단계: 시놀로지(Synology) NAS Docker로 상시 구동 서버 구축
가정에 24시간 켜져 있는 시놀로지 NAS를 중계(Signaling) 서버로 만들어 비용 없이 상시 접속 환경을 구성합니다.

#### 1. 코드 업로드
- 프로젝트 내 `server/` 폴더를 zip으로 압축합니다.
- 시놀로지 DSM **File Station**을 통해 적절한 경로(예: `docker/jumpdesktop-server`)에 올린 뒤 압축을 풉니다.

#### 2. Docker 이미지 빌드 (SSH 1회 실행)
- 시놀로지 `제어판 > 터미널 및 SNMP`에서 **SSH 서비스 활성화**를 체크합니다.
- 맥미니의 터미널에서 시놀로지 터미널로 접속합니다.
  ```bash
  ssh 시놀로지계정@시놀로지IP주소
  ```
- 업로드한 폴더 경로로 이동하여 이미지를 빌드합니다.
  ```bash
  cd /volume1/docker/jumpdesktop-server
  sudo docker build -t jumpdesktop-server:latest .
  ```

#### 3. Docker GUI 앱에서 실행
- 시놀로지 DSM에서 **Docker(또는 Container Manager)** 앱을 엽니다.
- **이미지(Image)** 탭으로 가보면 방금 빌드된 `jumpdesktop-server:latest` 이미지가 나타납니다.
- 이미지를 선택하고 **실행(Launch)** 버튼을 누릅니다.
- 포트 설정에서 **로컬 포트 `8443`**, **컨테이너 포트 `8443`**으로 TCP 연결 포트를 수동 지정한 후 컨테이너를 구동합니다.

#### 4. 포트포워딩 및 외부 도메인 등록
- **무료 DDNS 설정**: 시놀로지 DSM `제어판 > 외부 액세스 > DDNS`에서 무료 Synology 도메인(예: `mychina.synology.me`)을 등록합니다.
- **공유기 포트포워딩**: 가정 내 메인 공유기 설정에서 외부 포트 `8443`을 시놀로지의 로컬 IP의 `8443` 포트로 포스팅 연결해 줍니다.
- **아이패드 설정 변경**: `client/Sources/UI/DashboardView.swift` 파일의 `serverURL` 주소를 발급받은 도메인 주소로 변경하면 전 세계 어디서든 무선 제어가 가능합니다.
  ```swift
  let serverURL = URL(string: "wss://mychina.synology.me:8443")!
  ```

---

## 📊 4. Phase 5 고기능 모듈 세부 사항

* **가상 디스플레이 백업 (`VirtualDisplayManager.swift`)**: 모니터가 없는 Headless 상태의 맥미니에서도 `CGVirtualDisplay` CoreGraphics 비공개 API를 활용해 아이패드 비율(4:3)에 최적화된 백업 가상 캔버스를 로드합니다.
* **양방향 클립보드 연동**: 아이패드의 `UIPasteboard`와 macOS의 `NSPasteboard`를 전용 데이터 채널로 실시간 연동하며, 순환 버퍼 루프 방지를 위해 `lastSyncedClipboardText` 대조 코드를 탑재했습니다.
* **실시간 Latency RTT HUD Overlay**: 연결과 동시에 2초 주기로 핑퐁 통신을 구동해 RTT를 역산하고, 상단 HUD 오버레이에 상태 피드백을 제공합니다 (50ms 미만 녹색, 100ms 미만 주황색, 100ms 이상 빨간색 점등).
