# AntiSleep.spoon

`caffeinate` + 키 입력 시뮬레이션으로 macOS 잠자기를 방지하는 Hammerspoon Spoon입니다. MDM 유휴 감지 우회에 유용합니다.

## 기능

- **Caffeinate 통합**: 시스템, 디스플레이, 유휴 잠자기 방지
- **키 입력 시뮬레이션**: 주기적으로 Shift 키를 눌러 MDM 유휴 감지 우회
- **화면 어둡게**: 시간이 지나면 점점 화면을 어둡게 (전력 절약, 자연스러움)
- **Claude 트래픽 감지**: Claude Code가 유휴 상태면 자동 종료 (Anthropic API 트래픽 모니터링)
- **메뉴바 아이콘**: 상태 표시 (☕ ON / 💤 OFF) 클릭으로 토글

## 설치

### 방법 1: Spoons 폴더에 직접 클론

```bash
git clone https://github.com/yourusername/AntiSleep.spoon.git ~/.hammerspoon/Spoons/AntiSleep.spoon
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
```

Hammerspoon 설정 리로드 후 사용.

## 설정

```lua
hs.loadSpoon("AntiSleep")

-- 키 입력 설정
spoon.AntiSleep.keystrokeInterval = 60      -- 초 (기본값: 60)

-- 화면 어둡게 설정
spoon.AntiSleep.enableDimming = true        -- 화면 어둡게 활성화 (기본값: true)
spoon.AntiSleep.dimStartDelay = 300         -- 5분 후 시작 (기본값: 300)
spoon.AntiSleep.dimInterval = 60            -- 60초마다 어둡게 (기본값: 60)
spoon.AntiSleep.dimStep = 5                 -- 5%씩 감소 (기본값: 5)
spoon.AntiSleep.dimMinBrightness = 20       -- 최소 밝기 % (기본값: 20)

-- 트래픽 모니터링 설정
spoon.AntiSleep.enableTrafficWatch = true   -- 유휴시 자동 종료 (기본값: true)
spoon.AntiSleep.trafficGracePeriod = 1200   -- 유예 기간 20분 (기본값: 1200)
spoon.AntiSleep.trafficCheckInterval = 60   -- 60초마다 체크 (기본값: 60)
spoon.AntiSleep.idleThreshold = 2           -- N회 연속 유휴시 종료 (기본값: 2)
spoon.AntiSleep.minTrafficBytes = 100       -- 활성 판단 최소 바이트 (기본값: 100)

-- UI 설정
spoon.AntiSleep.showMenubar = true          -- 메뉴바 아이콘 표시 (기본값: true)
spoon.AntiSleep.showAlerts = true           -- ON/OFF 알림 표시 (기본값: true)

spoon.AntiSleep:bindHotkeys({toggle = {{"shift", "cmd"}, "k"}})
```

## 작동 방식

### 1. Caffeinate
`/usr/bin/caffeinate -dims` 실행:
- `-d` 디스플레이 잠자기 방지
- `-i` 유휴 잠자기 방지
- `-m` 디스크 잠자기 방지
- `-s` 시스템 잠자기 방지

### 2. 키 입력 시뮬레이션
60초마다 Shift 키 누름/뗌을 시뮬레이션하여 MDM 유휴 감지 우회.

### 3. 화면 어둡게
5분 후부터 매분 5%씩 화면을 어둡게 하여 최소 20%까지. 종료시 원래 밝기 복원.

### 4. Claude 트래픽 감지

`netstat -b`로 Anthropic API (`160.79.104.*`)로의 실제 바이트 전송량 모니터링:

```bash
# Anthropic API 트래픽 바이트 확인
netstat -b 2>/dev/null | grep '160.79.104'

# 출력 예시:
tcp4  0  0  yourhost.60085  160.79.104.10.https  ESTABLISHED  13380  40408
                                                              ↑      ↑
                                                          recv_bytes send_bytes
```

| 상태 | 바이트 변화량 |
|------|--------------|
| **대화 중** (Claude 응답 중) | +수십 KB/초 |
| **대기 중** (사용자 타이핑) | ~0 |
| **완전 유휴** | 0 |

**로직:**
- 20분 유예 기간 (무조건 유지)
- 유예 기간 후: 60초마다 체크
- 바이트 변화량 >= 100 bytes → 계속 유지
- 바이트 변화량 < 100 bytes 2회 연속 → 자동 종료

**디버그 로그:**
```bash
# 터미널에서 실시간 로그 확인
tail -f /tmp/antisleep.log

# 또는 Hammerspoon Console: 메뉴바 아이콘 → Console
```

로그 출력 예시:
```
21:30:00 [AntiSleep] Traffic check: total=12345, delta=500, idle=0/2
21:31:00 [AntiSleep] Traffic check: total=12345, delta=0, idle=1/2
21:32:00 [AntiSleep] No traffic detected, stopping
```

## API

| 메서드 | 설명 |
|--------|------|
| `:start()` | 잠자기 방지 시작 |
| `:stop()` | 잠자기 방지 중지 |
| `:toggle()` | ON/OFF 토글 |
| `:isRunning()` | 활성 상태면 `true` 반환 |
| `:bindHotkeys(mapping)` | 단축키 바인딩 |

## 작동 확인

```bash
# caffeinate 실행 중인지 확인
pgrep caffeinate

# 잠자기 방지 assertion 확인
pmset -g assertions | grep -E "PreventUserIdleSystemSleep|PreventUserIdleDisplaySleep"

# Anthropic API 트래픽 확인 (수동)
netstat -b 2>/dev/null | grep '160.79.104' | awk '{sum += $(NF-1) + $NF} END {print sum}'
```

## 라이선스

MIT
