🇰🇷 한국어 · [🇺🇸 English](connection-guide.en.md)

# cmux Remote 연결 가이드

> iPhone 앱이 Mac에 연결되지 않을 때, **누구나 따라 할 수 있는** 설치 +
> 문제 해결 안내입니다. 명령은 전부 **Mac에서** 실행합니다. 위에서부터
> 한 줄씩 그대로 복사해 붙여넣으면 됩니다.

cmux Remote는 두 부분으로 동작합니다.

- **Mac**: cmux 옆에서 `cmux-relay`(작은 백그라운드 서비스)가 돌면서
  iPhone의 요청을 받습니다.
- **iPhone**: cmux Remote 앱이 Tailscale 너머로 그 relay에만 붙습니다.

iPhone이 연결되려면 **① cmux 실행 + ② relay 실행 + ③ 같은 Tailnet** 세
가지가 동시에 만족돼야 합니다. 연결이 안 되면 거의 항상 이 셋 중 하나가
빠진 것입니다.

---

## 0. 준비물 (한 번만)

```bash
cmux --version       # cmux가 설치돼 있고 실행 중이어야 함
tailscale status     # Tailscale에 로그인 + 온라인이어야 함
swift --version      # Swift 5.10+ (Xcode 15.3 이상)
```

- `cmux`가 없다면 → [cmux](https://github.com/manaflow-ai/cmux)를 먼저 설치하고 실행하세요.
- `tailscale`이 없다면 → [Tailscale](https://tailscale.com/download)을 Mac과 iPhone **양쪽**에 설치하고 같은 계정으로 로그인하세요.
- `swift`가 없다면 → App Store에서 Xcode를 설치하세요(또는 `xcode-select --install`).

---

## 1. 설치 (Mac)

```bash
git clone https://github.com/NewTurn2017/cmux-remote.git
cd cmux-remote
sudo ./scripts/install-launchd.sh
```

이 한 줄이 알아서:

1. relay를 릴리스 모드로 빌드하고 (`/usr/local/lib/cmux-remote/bin/`)
2. 설정 파일이 없으면 기본값으로 만들고 (`~/.cmuxremote/relay.json`)
3. 부팅 시 자동 시작되는 root 백그라운드 데몬으로 등록합니다 (포트 80).

로그는 `~/.cmuxremote/log/`에 쌓입니다.

> 빌드는 처음 한 번은 몇 분 걸릴 수 있습니다. `swift` 또는 `launchctl`이
> 없다는 에러가 나면 위 **준비물**을 다시 확인하세요.

---

## 2. relay가 떴는지 확인 (Mac)

```bash
curl -s http://$(tailscale ip -4):80/v1/health
```

`{"ok":true,"version":"0.1.0"}` 가 나오면 **relay 정상**입니다.

cmux 소켓에도 붙었는지 한 번 더 확인:

```bash
./scripts/cmux-probe.sh
# {"id":"probe-1","result":{...}}  ← 이렇게 result가 나오면 OK
```

둘 다 정상이면 3단계(페어링)로 넘어가세요. 응답이 없으면 **4. 연결이
안 될 때**로.

---

## 3. iPhone 페어링

Mac의 주소를 먼저 확인합니다.

```bash
tailscale ip -4      # 예: 100.101.102.103  ← 이 IP를 앱에 입력
tailscale status     # MagicDNS 이름(예: my-mac)을 쓰고 싶을 때
```

iPhone에서 cmux Remote 앱을 열고:

1. **Add Mac** 탭
2. 위 IP(또는 MagicDNS 이름) 입력, 포트는 **`80`**
3. Mac 메뉴바에 뜨는 페어링 요청을 **승인**

연결되면 작업공간 목록이 보입니다.

---

## 3.5. 웹 브라우저에서 접속 (Windows / Linux / 모든 기기)

iPhone 앱 없이도, **Tailscale에 로그인된 어떤 기기의 브라우저**에서나
cmux 터미널을 볼 수 있습니다. relay 하나가 iPhone 앱과 웹 브라우저를
동시에 지원합니다 — 별도 설치 없이.

1. 접속하려는 기기(Windows PC, Linux, 다른 Mac, Android 태블릿 등)에서
   **Tailscale**을 켜고 Mac과 **같은 Tailnet(같은 계정)** 에 로그인합니다.
2. 브라우저(Chrome, Edge, Safari, Firefox) 주소창에 relay 주소를 입력:
   ```
   http://<mac-tailscale-ip>:80/
   ```
   예: `http://100.101.102.103:80/`
3. 같은 Tailnet에 있으면 relay가 자동으로 신원을 확인하고 페어링합니다.
   터미널이 바로 보이고 키 입력도 전송됩니다.

> **iPhone 앱과 충돌하나요?** 아닙니다. relay가 여러 기기를 동시에
> 지원합니다. iPhone은 앱으로, Windows PC는 브라우저로 — 둘 다 같은
> relay에 붙어 같은 작업공간을 봅니다.
>
> **인터넷 연결이 필요한가요?** xterm.js 렌더링 라이브러리를 CDN에서
> 불러오므로 처음 접속 시 인터넷이 필요합니다. Tailnet 자체는 인터넷과
> 무관하게 동작합니다.

---


## 4. 연결이 안 될 때 (체크리스트)

위에서부터 한 줄씩 확인하세요. **대부분 ①~②에서 해결됩니다.**

```bash
SERVICE="system/com.genie.cmuxremote"
```

### ① cmux가 켜져 있나?

cmux 앱이 꺼져 있으면 relay가 화면을 읽지 못합니다.

```bash
cmux --version
# cmux 앱을 켠 다음:
sudo launchctl kickstart -k "$SERVICE"
```

### ② relay가 살아 있나?

```bash
curl -s http://$(tailscale ip -4):80/v1/health
```

- 응답이 없으면 재시작: `sudo launchctl kickstart -k "$SERVICE"`
- 그래도 안 되면 재설치: `sudo ./scripts/install-launchd.sh`
- 상태 확인: `sudo launchctl print "$SERVICE" | grep -E "state|pid|last exit"`

### ③ 로그가 정상인가?

```bash
tail -n 40 ~/.cmuxremote/log/stderr.log
```

정상이면 아래 3줄이 보입니다:

```
starting cmux-relay on 0.0.0.0:80
listening …
cmux event stream attached
```

로그에 따라:

| 로그 메시지 | 뜻 | 조치 |
|---|---|---|
| `cmux event stream unavailable: socketMissing` | cmux가 꺼져 있음 | cmux 앱을 켜고 `sudo launchctl kickstart -k "$SERVICE"` |
| `Connection refused` 반복 | cmux 재시작으로 소켓 이름이 바뀜 | `sudo launchctl kickstart -k "$SERVICE"`, 그래도면 `sudo ./scripts/install-launchd.sh` 재실행 |
| 3줄 정상인데 앱만 못 붙음 | 네트워크/주소 문제 | ④⑤ 확인 |

### ④ Tailscale이 양쪽 다 온라인인가?

```bash
tailscale status
```

- Mac과 iPhone이 **같은 Tailnet(같은 계정)** 에 로그인돼 있어야 합니다.
- iPhone의 Tailscale 앱에서 연결이 켜져 있는지 확인하세요.

### ⑤ 앱에 입력한 주소가 맞나?

```bash
tailscale ip -4
```

- 앱에 이 **IP**와 포트 **`80`** 를 정확히 입력했는지 확인하세요.
- MagicDNS 이름을 썼다면 `tailscale status`의 이름과 철자가 같아야 합니다.

### 그래도 안 되면

이전에 페어링했던 기기 토큰이 막혀 있을 수 있습니다.

```bash
/usr/local/lib/cmux-remote/bin/cmux-relay devices list     # 등록된 기기 확인
# 필요하면 해당 기기 제거 후 앱에서 다시 페어링:
# /usr/local/lib/cmux-remote/bin/cmux-relay devices revoke <device-id>
```

---

## 자주 묻는 질문

**Q. cmux를 재시작했더니 다시 연결이 끊겨요.**
cmux는 재시작할 때 내부 소켓 이름이 바뀔 수 있습니다. relay를 다시
붙이는 가장 빠른 방법:

```bash
sudo launchctl kickstart -k "system/com.genie.cmuxremote"
```

**Q. 같은 Wi-Fi인데도 안 돼요.**
이 앱은 Wi-Fi가 아니라 **Tailscale**로 연결합니다. 둘 다 Tailscale에
로그인돼 있어야 하고, 앱에는 `tailscale ip -4`로 나온 IP를 넣어야 합니다.

**Q. 알림이 안 와요.**
현재 알림은 *로컬* 알림이라 앱이 켜져 있거나 백그라운드에서 연결이
살아있을 때만 도착합니다. 앱을 완전히 종료하면 알림이 오지 않습니다
(진짜 푸시는 v1.1 예정).

**Q. 매번 직접 켜야 하나요?**
아니요. relay는 launchd 서비스라 **Mac 로그인 시 자동 시작**되고 죽으면
다시 뜹니다. 단, **cmux 앱은 직접 실행**해야 합니다.

**Q. Mac을 재부팅해도 relay가 자동으로 켜지나요?**
네. launchd 서비스가 `RunAtLoad` + `KeepAlive`로 등록돼 있어 Mac
로그인 시 자동 시작하고, 비정상 종료 시 5초 간격(`ThrottleInterval`)으로
재시작합니다. 재부팅 후 로그인하면 relay가 곧바로 떠 있습니다. 단,
**cmux 앱은 직접 실행**해야 합니다.

**Q. relay가 두 개 뜨나요? (포트 충돌 / 로그 중복)**
relay는 시작 시 `~/.cmuxremote/relay.lock` 파일 lock으로 **단일 인스턴스**를
강제합니다. 두 번째 인스턴스는 즉시 exit하므로 포트 충돌이나 로그 중복이
발생하지 않습니다. 만약 두 개가 떠 있는 것 같다면
`sudo ./scripts/install-launchd.sh` 재실행으로 정리됩니다.

---

## 사용자에게 보낼 짧은 안내문

연결이 안 된다는 사람에게 아래를 그대로 전달하세요:

> **cmux Remote 연결 체크 (Mac에서 실행)**
>
> 1. cmux 앱이 켜져 있는지 확인하세요.
> 2. 터미널에 붙여넣기:
>    ```bash
>    SERVICE="system/com.genie.cmuxremote"
>    sudo launchctl kickstart -k "$SERVICE"
>    curl -s http://$(tailscale ip -4):80/v1/health
>    ```
>    → `{"ok":true,...}` 가 나오면 relay 정상입니다.
> 3. 앱(iPhone)과 Mac이 **같은 Tailscale 계정**으로 로그인돼 있는지
>    확인하세요.
> 4. 앱에는 `tailscale ip -4` 로 나온 IP와 포트 `80` 를 입력하세요.
>
> 그래도 안 되면 `tail -n 40 ~/.cmuxremote/log/stderr.log` 결과를
> 알려주세요.
