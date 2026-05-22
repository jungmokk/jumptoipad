# Coturn TURN Server with TLS (TURNS) Setup Guide
---

이 가이드는 중국 만리방화벽(GFW)의 DPI 감지를 우회하여 맥미니와 아이패드 간 초저지연 WebRTC 스트리밍을 구현하기 위한 **TURNS (TURN over TLS) on TCP 443** 서버의 TLS 인증서 발급 및 설정 방법입니다.

## 1. 개요 및 사전 준비

중국 내 네트워크 환경에서는 표준 UDP 3478 포트를 통한 TURN 연결이 불안정하거나 GFW에 의해 쉽게 차단될 수 있습니다. 따라서 **홍콩 리전(AWS, Alibaba Cloud, Tencent Cloud 등)**에 서버를 생성하고, 표준 웹 HTTPS 트래픽으로 위장하는 **TURNS (TCP 443)** 방식을 사용해야 합니다.

### 준비물
1. **홍콩 리전의 클라우드 인스턴스** (공인 IP 필요, 방화벽에서 TCP/UDP 443 포트 개방)
2. **소유하고 있는 도메인** (예: `turn.yourdomain.hk`)
3. **도메인을 홍콩 서버의 공인 IP로 가리키는 A 레코드 등록**

---

## 2. Let's Encrypt를 이용한 SSL/TLS 인증서 발급

가장 간단하고 대중적인 Let's Encrypt의 무료 와일드카드 또는 단일 도메인 SSL 인증서를 사용합니다.

### 2.1. Certbot 설치 (Ubuntu/Debian 기준)
```bash
sudo apt update
sudo apt install -y certbot
```

### 2.2. 독립 실행형(Standalone) 모드로 인증서 발급
인증서 발급 중 80번 포트를 임시로 사용하므로 기존에 구동 중인 웹 서버가 있다면 잠시 멈춰야 합니다.
```bash
sudo systemctl stop nginx || true
sudo certbot certonly --standalone -d turn.yourdomain.hk
```
이메일 입력 및 약관 동의를 완료하면 `/etc/letsencrypt/live/turn.yourdomain.hk/` 경로에 인증서 파일이 생성됩니다.

---

## 3. 인증서 복사 및 권한 설정

Docker 컨테이너가 접근할 수 있도록 인증서 파일을 프로젝트의 `certs` 디렉터리로 복사하고 Coturn이 읽을 수 있도록 소유권을 구성합니다.

```bash
# coturn 디렉터리로 이동
cd /home/jungm/project/jumpdesktop/infra/coturn

# certs 폴더 생성
mkdir -p certs

# 인증서 파일 복사 및 링크 해석 복사
sudo cp -L /etc/letsencrypt/live/turn.yourdomain.hk/fullchain.pem ./certs/cert.pem
sudo cp -L /etc/letsencrypt/live/turn.yourdomain.hk/privkey.pem ./certs/privkey.pem

# 보안 설정: non-root 계정이 읽을 수 있도록 파일 권한 조정
sudo chmod 644 ./certs/cert.pem ./certs/privkey.pem
```

---

## 4. Coturn 설정 파일 수정

`turnserver.conf`의 다음 주석들을 해제하고 본인의 정보에 맞게 채워 넣습니다.

```ini
# ─── TLS 인증서 경로 ───
cert=/etc/coturn/certs/cert.pem
pkey=/etc/coturn/certs/privkey.pem

# ─── 인증 영역(Realm) 및 공인 IP ───
realm=turn.yourdomain.hk
external-ip=YOUR_HONGKONG_SERVER_PUBLIC_IP
```

---

## 5. 서비스 시작 및 동작 확인

Docker Compose를 이용해 백그라운드로 Coturn 서비스를 실행합니다.

```bash
# 서비스 구동
docker-compose up -d

# 실시간 로깅 모니터링 (연결 시도 확인용)
docker-compose logs -f
```

### 연결 테스트 방법
[Trickle ICE 테스트 페이지](https://webrtc.github.io/samples/src/content/peerconnection/trickle-ice/)에 접속하여 아래 정보를 입력한 후 **Add Server**를 누르고 **Gather candidates**를 실행합니다.

* **STUN or TURN URI:** `turn:turn.yourdomain.hk:443?transport=tcp` 또는 `turns:turn.yourdomain.hk:443?transport=tcp`
* **Username:** `jumpdesktop` (또는 `.env` 파일에 정의한 값)
* **Password:** `changeme` (또는 `.env` 파일에 정의한 값)

결과에 `relay` 타입의 후보군(Candidate)이 정상적으로 획득되면 GFW 우회 TURN 릴레이 설정이 완벽히 성공한 것입니다.

---

## 6. 인증서 자동 갱신 (Cron 설정)

Let's Encrypt 인증서는 90일 만료 기간을 가집니다. 아래 갱신 스크립트를 주기적으로 실행해 주어야 합니다.

`/etc/cron.daily/renew-coturn` 스크립트 작성:
```bash
#!/bin/bash
certbot renew --quiet --post-hook "cp -L /etc/letsencrypt/live/turn.yourdomain.hk/fullchain.pem /home/jungm/project/jumpdesktop/infra/coturn/certs/cert.pem && cp -L /etc/letsencrypt/live/turn.yourdomain.hk/privkey.pem /home/jungm/project/jumpdesktop/infra/coturn/certs/privkey.pem && chmod 644 /home/jungm/project/jumpdesktop/infra/coturn/certs/*.pem && docker compose -f /home/jungm/project/jumpdesktop/infra/coturn/docker-compose.yml restart"
```
```bash
sudo chmod +x /etc/cron.daily/renew-coturn
```
