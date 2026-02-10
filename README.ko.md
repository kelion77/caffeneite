# AntiSleep.spoon

[English Version](README.md)

Claude Code 및 Cursor 세션을 위한 스마트 잠자기 관리 Hammerspoon Spoon입니다. 사용자 활동 + AI API 트래픽을 모니터링하고, 둘 다 유휴 상태일 때 잠자기를 트리거합니다.

## 기능

- **스마트 자동 잠자기**: 사용자와 AI 도구 모두 유휴 상태일 때 시스템 잠자기 트리거
- **Wake 알림**: 자동 잠자기에서 복귀 시 알림 표시 (언제/얼마나)
- **Claude 트래픽 감지**: Anthropic API 트래픽 모니터링 (`160.79.104.*`)
- **Cursor 트래픽 감지**: Cursor API 트래픽 모니터링 (공식 도메인: `*.cursor.sh`, `*.cursor-cdn.com`)
- **화면 어둡게**: 대기 중 점진적으로 화면을 어둡게 (전력 절약)
- **메뉴바 아이콘**: 상태 표시 (👁 모니터링 / 💤 OFF) 클릭으로 토글

## 설치

### 방법 1: Spoons 폴더에 직접 클론

```bash
git clone https://github.com/kelion77/caffeneite.git ~/.hammerspoon/Spoons/AntiSleep.spoon
```

### 방법 2: 다운로드 후 복사

```bash
cp -r AntiSleep.spoon ~/.hammerspoon/Spoons/
```

## 사용법

`~/.hammerspoon/init.lua`에 추가:

```lua
hs.loadSpoon("AntiSleep")
spoon.AntiSleep:bindHotkeys({toggle = {{"shift", "cmd"}, "k"}})
spoon.AntiSleep:start()
```

Hammerspoon 설정 리로드 후 사용.

## 설정

```lua
hs.loadSpoon("AntiSleep")

-- 잠자기 트리거 설정
spoon.AntiSleep.sleepIdleMinutes = 2            -- X분 유휴 후 잠자기 (기본값: 2)
spoon.AntiSleep.enableAutoSleep = true          -- 자동 잠자기 활성화 (기본값: true)
spoon.AntiSleep.idleCheckInterval = 60          -- X초마다 체크 (기본값: 60)
spoon.AntiSleep.minTrafficBytes = 50000         -- Claude 활성 판단 최소 바이트 (기본값: 50KB)
spoon.AntiSleep.minCursorTrafficBytes = 500000  -- Cursor 활성 판단 최소 바이트 (기본값: 500KB)
spoon.AntiSleep.userIdleThreshold = 120         -- X초 후 사용자 유휴 (기본값: 120)
spoon.AntiSleep.maxPreventionMinutes = 60       -- 화면 잠금 후 X분 경과 시 강제 잠자기 (기본값: 60)

-- 화면 어둡게 설정
spoon.AntiSleep.enableDimming = true        -- 화면 어둡게 활성화 (기본값: true)
spoon.AntiSleep.dimStartDelay = 300         -- 5분 후 시작 (기본값: 300)
spoon.AntiSleep.dimInterval = 60            -- 60초마다 어둡게 (기본값: 60)
spoon.AntiSleep.dimStep = 5                 -- 5%씩 감소 (기본값: 5)
spoon.AntiSleep.dimMinBrightness = 20       -- 최소 밝기 % (기본값: 20)

-- UI 설정
spoon.AntiSleep.showMenubar = true          -- 메뉴바 아이콘 표시 (기본값: true)
spoon.AntiSleep.showAlerts = true           -- ON/OFF 알림 표시 (기본값: true)

spoon.AntiSleep:bindHotkeys({toggle = {{"shift", "cmd"}, "k"}})
spoon.AntiSleep:start()
```

## 작동 방식

### 1. 활동 모니터링

사용자와 AI 도구 활동을 모두 모니터링:
- **사용자 활동**: 마우스 움직임, 클릭, 스크롤, 키보드 입력
- **Claude 활동**: Anthropic API 트래픽 (`160.79.104.*`)
- **Cursor 활동**: Cursor API 트래픽 (공식 도메인 기반 특정 IP)

#### Cursor IP 감지

[Cursor 공식 네트워크 설정](https://cursor.com/docs/enterprise/network-configuration) 기반으로 트래픽 감지:
- `*.cursor.sh` → `100.51.*`, `100.52.*`
- `*.cursor-cdn.com` → `104.26.8.*`, `104.26.9.*`, `172.67.71.*`

### 2. 스마트 잠자기 트리거

**중요**: 화면이 잠금 상태이거나 꺼져 있을 때만 잠자기가 트리거됩니다.

```
매 60초마다:
├─ 화면 잠금/꺼짐?
├─ Claude 유휴? (API 트래픽 delta < 50KB)
├─ Cursor 유휴? (API 트래픽 delta < 500KB)
├─ 최대 방지 시간 초과? (잠금 후 > 60분)
│
├─ 화면 잠금 + (둘 다 유휴 또는 최대 시간 초과) → idle 카운터 증가
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

### 3. 잠자기 방지 (caffeinate)

Claude 또는 Cursor가 활성일 때:
- `caffeinate -i`가 시작되어 유휴 시스템 잠자기 방지
- 디스플레이 잠자기는 허용 (화면 잠금 가능)
- 둘 다 유휴 상태가 되면 caffeinate 중지

### 4. Wake 알림

자동 잠자기에서 복귀 시:
- 시스템 알림으로 잠자기 시간과 지속 시간 표시
- 화면 알림: "Woke from auto-sleep (X min)"
- `/tmp/antisleep.log`에 기록

### 5. 화면 어둡게

5분 후부터 매분 5%씩 화면을 어둡게 하여 최소 20%까지. 활동 감지 시 원래 밝기 복원.

## 디버그 로그

```bash
# 실시간 로그 확인
tail -f /tmp/antisleep.log

# 또는 Hammerspoon Console: 메뉴바 아이콘 → Console
```

로그 출력 예시:
```
07:41:36 [AntiSleep] Check: screen=UNLOCKED, Claude=525.2 KB, Cursor=1.2 MB, caffeinate=ON, idle=0s/120s
07:42:36 [AntiSleep] Check: screen=UNLOCKED, Claude=0 B, Cursor=0 B, caffeinate=OFF, idle=0s/120s
07:43:00 [AntiSleep] Event: screensDidLock
07:45:00 [AntiSleep] Auto-sleep triggered (ran for 45 min)
08:30:00 [AntiSleep] Woke from auto-sleep (duration: 45 min)
```

## API

| 메서드 | 설명 |
|--------|------|
| `:start()` | 스마트 잠자기 모니터링 시작 |
| `:stop()` | 모니터링 완전히 중지 (sleepWatcher 포함) |
| `:pause()` | 모니터링 일시정지 (sleepWatcher는 유지하여 자동 재시작 가능) |
| `:toggle()` | ON/OFF 토글 |
| `:isRunning()` | 활성 상태면 `true` 반환 |
| `:bindHotkeys(mapping)` | 단축키 바인딩 |

## 작동 확인

```bash
# Claude (Anthropic) API 트래픽 확인
netstat -b 2>/dev/null | grep '160.79.104' | awk '{sum += $(NF-1) + $NF} END {print sum}'

# Cursor API 트래픽 확인
netstat -b 2>/dev/null | grep -E '100.51|100.52|104.26.8|104.26.9' | awk '{sum += $(NF-1) + $NF} END {print sum}'

# 잠자기 로그 확인
pmset -g log | grep -i "sleep" | tail -5
```

## 라이선스

MIT
