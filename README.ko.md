# CaffBar.spoon

[English Version](README.md)

Claude Code, Codex 및 Cursor 세션을 위한 Smart Awake 관리 Hammerspoon Spoon입니다. 사용자 활동 + AI API 트래픽을 모니터링하고, 둘 다 유휴 상태일 때 잠자기를 트리거합니다.

## 기능

- **스마트 자동 잠자기**: 사용자와 AI 도구 모두 유휴 상태일 때 시스템 잠자기 트리거
- **Wake 알림**: 자동 잠자기에서 복귀 시 알림 표시 (언제/얼마나)
- **Claude 트래픽 감지**: Anthropic API 트래픽 모니터링 (`160.79.104.*`)
- **Codex 트래픽 감지**: `nettop`으로 `codex` 프로세스 트래픽을 프로세스 단위 모니터링 (CLI, `codex exec`, `codex app-server`)
- **Cursor 트래픽 감지**: Cursor API 트래픽 모니터링 (공식 도메인: `*.cursor.sh`, `*.cursor-cdn.com`)
- **화면 어둡게**: 대기 중 점진적으로 화면을 어둡게 (전력 절약)
- **Smart Unlocked 모드**: AI 도구가 활성일 때 idle 화면 잠금 방지
- **메뉴바 메뉴**: 작은 모니터 상태 아이콘과 시작, 모드 전환, 종료 액션 제공

## 설치

```bash
git clone https://github.com/kelion77/caffeneite.git /tmp/caffbar-install && /tmp/caffbar-install/install.sh && rm -rf /tmp/caffbar-install && killall Hammerspoon 2>/dev/null; open -a Hammerspoon
```

이 명령은 `CaffBar.spoon`을 설치하고, Hammerspoon 로그인 실행을 켜며, CaffBar가 항상 Smart Awake 모드(`smart`)로 시작되는 startup 블록을 idempotent하게 작성합니다. `Shift+Cmd+K`로 토글합니다.

로컬 checkout에서는 다음을 실행하면 됩니다:

```bash
./install.sh
```

## 사용법

`~/.hammerspoon/init.lua`에 추가:

```lua
hs.loadSpoon("CaffBar")
spoon.CaffBar:bindHotkeys({toggle = {{"shift", "cmd"}, "k"}})
spoon.CaffBar:startMode("smart")
```

Hammerspoon 설정 리로드 후 사용.

## 설정

```lua
hs.loadSpoon("CaffBar")

-- 모드 설정
spoon.CaffBar.mode = "smart"                -- "smart" 또는 "keepUnlocked" (기본값: "smart")
spoon.CaffBar.autoLaunchHammerspoon = true  -- Hammerspoon 로그인 실행 (기본값: true)
spoon.CaffBar.preventLockPulseInterval = 55 -- Smart Unlocked 모드 user activity pulse 간격

-- 잠자기 트리거 설정
spoon.CaffBar.sleepIdleMinutes = 2            -- X분 유휴 후 잠자기 (기본값: 2)
spoon.CaffBar.enableAutoSleep = true          -- 자동 잠자기 활성화 (기본값: true)
spoon.CaffBar.idleCheckInterval = 60          -- X초마다 체크 (기본값: 60)
spoon.CaffBar.minTrafficBytes = 50000         -- Claude 활성 판단 최소 바이트 (기본값: 50KB)
spoon.CaffBar.minCursorTrafficBytes = 500000  -- Cursor 활성 판단 최소 바이트 (기본값: 500KB)
spoon.CaffBar.minCodexTrafficBytes = 50000    -- Codex 활성 판단 최소 바이트 (기본값: 50KB)
spoon.CaffBar.codexActiveCooldown = 600       -- 마지막 버스트 후 X초간 Codex 활성 유지 (기본값: 10분)
spoon.CaffBar.userIdleThreshold = 120         -- X초 후 사용자 유휴 (기본값: 120)
spoon.CaffBar.maxPreventionMinutes = 60       -- 화면 잠금 후 X분 경과 시 강제 잠자기 (기본값: 60)

-- 화면 어둡게 설정
spoon.CaffBar.enableDimming = true        -- 화면 어둡게 활성화 (기본값: true)
spoon.CaffBar.dimStartDelay = 300         -- 5분 후 시작 (기본값: 300)
spoon.CaffBar.dimInterval = 60            -- 60초마다 어둡게 (기본값: 60)
spoon.CaffBar.dimStep = 5                 -- 5%씩 감소 (기본값: 5)
spoon.CaffBar.dimMinBrightness = 20       -- 최소 밝기 % (기본값: 20)

-- UI 설정
spoon.CaffBar.showMenubar = true          -- 메뉴바 아이콘 표시 (기본값: true)
spoon.CaffBar.showAlerts = true           -- ON/OFF 알림 표시 (기본값: true)

spoon.CaffBar:bindHotkeys({toggle = {{"shift", "cmd"}, "k"}})
spoon.CaffBar:startMode("smart")
```

## 작동 방식

### 1. 모드

CaffBar에는 두 가지 모드가 있습니다:
- **Smart Awake** (`smart`): 기존 동작입니다. AI 트래픽이 있으면 Mac을 깨어 있게 유지하지만, 디스플레이 잠자기와 화면 잠금은 허용합니다. 화면이 잠긴 뒤 AI 도구가 유휴 상태가 되면 시스템 잠자기를 트리거할 수 있습니다.
- **Smart Unlocked** (`keepUnlocked`): Smart Awake과 같은 AI 트래픽 감지를 사용하되, Claude/Codex/Cursor가 활성일 때는 idle 디스플레이 잠자기/화면 잠금까지 방지합니다. 모두 유휴 상태가 되면 lock 방지는 중지됩니다.

### 2. 활동 모니터링

사용자와 AI 도구 활동을 모두 모니터링:
- **사용자 활동**: 마우스 움직임, 클릭, 스크롤, 키보드 입력
- **Claude 활동**: Anthropic API 트래픽 (`160.79.104.*`)
- **Codex 활동**: `nettop`으로 `codex` 프로세스 트래픽을 프로세스 단위 측정
- **Cursor 활동**: Cursor API 트래픽 (공식 도메인 기반 특정 IP)

#### Cursor IP 감지

[Cursor 공식 네트워크 설정](https://cursor.com/docs/enterprise/network-configuration) 기반으로 트래픽 감지:
- `*.cursor.sh` → `100.51.*`, `100.52.*`
- `*.cursor-cdn.com` → `104.26.8.*`, `104.26.9.*`, `172.67.71.*`

#### Codex 감지 (IP가 아닌 프로세스 단위)

Codex는 Cloudflare 공유 엔드포인트(`api.openai.com`, `chatgpt.com`)와 통신하며 IPv6를 자주 사용하기 때문에, IP 패턴 매칭은 트래픽을 놓치거나(IPv6) 무관한 앱을 오탐(공유 IP)할 수 있습니다. 대신 `nettop -p codex`로 프로세스 단위 트래픽을 측정하며, 다음을 커버합니다:
- `codex` CLI (대화형 및 `codex exec`)
- `codex app-server` (Codex 데스크톱 앱 로컬 작업, Claude Code Codex 플러그인, ChatGPT 리모트 컨트롤 데몬)

트래픽은 프로세스 합계가 아닌 **연결 단위**로 추적합니다: nettop은 현재 열려 있는 연결의 누적 바이트를 보고하므로, 프로세스 합계는 연결 하나가 닫힐 때마다 줄어들어 다른 연결의 실제 버스트를 가리거나 가짜 변화로 읽힐 수 있습니다. 연결별 카운터는 수명 동안 증가만 하므로: 유지 중인 연결은 양수 델타만 기여하고, 새 연결은 전체 바이트가 집계되며, 닫힌 연결은 그냥 제외됩니다.

**활성 쿨다운**: 실제 Codex 작업 중에도 조용한 구간이 존재합니다 — API 호출 사이의 로컬 빌드/테스트, 긴 서버사이드 reasoning, 연결 종료로 인한 0 델타 등. 작업 중 잠자기를 방지하기 위해 마지막 트래픽 버스트 후 `codexActiveCooldown`(기본 10분) 동안 Codex를 활성 상태로 유지합니다. 총 깨어있는 시간은 `maxPreventionMinutes`로 여전히 제한됩니다.

### 3. Smart Awake 트리거

**중요**: 화면이 잠금 상태이거나 꺼져 있을 때만 잠자기가 트리거됩니다.

```
매 60초마다:
├─ 화면 잠금/꺼짐?
├─ Claude 유휴? (API 트래픽 delta < 50KB)
├─ Codex 유휴? (프로세스 트래픽 delta < 50KB)
├─ Cursor 유휴? (API 트래픽 delta < 500KB)
├─ 최대 방지 시간 초과? (잠금 후 > 60분)
│
├─ 화면 잠금 + (모두 유휴 또는 최대 시간 초과) → idle 카운터 증가
│   └─ 2분 도달 → 모니터링 일시정지 + pmset sleepnow
│                  (타이머 중지, sleepWatcher는 유지)
│
└─ 화면 해제 또는 AI 활성 → 카운터 리셋
```

**최대 방지 시간**: AI 트래픽이 감지되더라도 화면 잠금 후 60분이 지나면 강제로 잠자기를 허용하여 백그라운드 트래픽으로 인한 배터리 소모를 방지합니다.

**잠자기 후 자동 재시작**:
- 잠자기 트리거 시 모니터링은 일시정지되지만 sleepWatcher는 활성 유지
- wake 시 (`systemDidWake` 이벤트), 모니터링이 자동으로 재시작
- wake 직후 잠자기가 반복되는 것을 방지

### 4. 잠자기 방지 (caffeinate)

Smart Awake 모드에서 Claude, Codex 또는 Cursor가 활성일 때:
- `caffeinate -is`가 시작되어 유휴/시스템 잠자기 방지
- 디스플레이 잠자기는 허용하므로 화면 잠금 가능
- 모두 유휴 상태가 되면 caffeinate 중지

Smart Unlocked 모드에서 Claude, Codex 또는 Cursor가 활성일 때:
- `caffeinate -dis`가 시작되어 디스플레이 잠자기와 시스템 잠자기 방지
- 주기적인 user activity assertion으로 idle lock/screen saver 진입 방지 보조
- 모두 유휴 상태가 되면 lock 방지와 caffeinate 중지

### 5. Wake 알림

자동 잠자기에서 복귀 시:
- 시스템 알림으로 잠자기 시간과 지속 시간 표시
- 화면 알림: "Woke from auto-sleep (X min)"
- `/tmp/caffbar.log`에 기록

### 6. 화면 어둡게

5분 후부터 매분 5%씩 화면을 어둡게 하여 최소 20%까지. 활동 감지 시 원래 밝기 복원.

## 디버그 로그

```bash
# 실시간 로그 확인
tail -f /tmp/caffbar.log

# 또는 Hammerspoon Console: 메뉴바 아이콘 → Console
```

로그 출력 예시:
```
07:41:36 [CaffBar] Check: screen=UNLOCKED, Claude=525.2 KB, Cursor=1.2 MB, Codex=3.4 MB, caffeinate=ON, idle=0s/120s
07:42:36 [CaffBar] Check: screen=UNLOCKED, Claude=0 B, Cursor=0 B, Codex=0 B, caffeinate=OFF, idle=0s/120s
07:43:00 [CaffBar] Event: screensDidLock
07:45:00 [CaffBar] Auto-sleep triggered (ran for 45 min)
08:30:00 [CaffBar] Woke from auto-sleep (duration: 45 min)
```

## API

| 메서드 | 설명 |
|--------|------|
| `:start()` | Smart Awake 모니터링 시작 |
| `:stop()` | 모니터링 완전히 중지 (sleepWatcher 포함) |
| `:pause()` | 모니터링 일시정지 (sleepWatcher는 유지하여 자동 재시작 가능) |
| `:toggle()` | ON/OFF 토글 |
| `:startMode(mode)` | 모드를 선택하고 필요하면 모니터링 시작 |
| `:setMode(mode)` | 모드를 `"smart"` 또는 `"keepUnlocked"`로 설정 |
| `:isRunning()` | 활성 상태면 `true` 반환 |
| `:bindHotkeys(mapping)` | 단축키 바인딩 |

## 작동 확인

```bash
# Claude (Anthropic) API 트래픽 확인
netstat -b 2>/dev/null | grep '160.79.104' | awk '{sum += $(NF-1) + $NF} END {print sum}'

# Cursor API 트래픽 확인
netstat -b 2>/dev/null | grep -E '100.51|100.52|104.26.8|104.26.9' | awk '{sum += $(NF-1) + $NF} END {print sum}'

# Codex 프로세스 트래픽 확인
nettop -x -l 1 -p codex -J bytes_in,bytes_out 2>/dev/null | awk '$1 ~ /^codex\./ {sum += $2 + $3} END {print sum+0}'

# 잠자기 로그 확인
pmset -g log | grep -i "sleep" | tail -5
```

## 라이선스

MIT
