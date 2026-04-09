# Filter Sweep Mode Implementation Plan

## Context

Vinyl 다음 6번째 모드로 "Filter Sweep" 추가. 시스템 오디오에 주파수 필터를 걸어 맥북 덮개 각도로 실시간 제어하는 모드.
- 닫으면 "잠수함" (Low-Pass), 중간이면 "라디오" (Band-Pass), 열면 "드랍 빌드업" (High-Pass)
- 선택적으로 다이나믹 컴프레서도 각도 제어 가능

기존 AudioEngine에 biquad 필터가 이미 구현되어 있지만 **render 루프에서 한 번도 호출된 적 없음** (dead code). 이를 확장하여 3가지 필터 타입 + 컴프레서를 구현.

## Architecture

Filter Sweep = **시스템 오디오 패스스루 프로세서**. 기존 모드들(신스 생성)과 달리, 시스템에서 재생 중인 음악을 캡처 → 필터링 → 출력하는 구조.

- `SystemAudioCapture.readSamples()` → 링 버퍼에서 실시간 오디오 읽기
- 전용 biquad 필터 (LP/BP/HP 전환 가능) 적용
- 선택적 컴프레서 적용
- 출력

## Changes

### 1. Models.swift — enum 추가

- `SynthMode`에 `.filter` case 추가 (Vinyl 다음)
- `FilterType` enum 신규: `.lowPass`, `.bandPass`, `.highPass`
- `angleToFilterCutoff()` 헬퍼 함수 (디스플레이용)

### 2. L10n.swift — 다국어 문자열

- `modeFilter`, `filterCutoff`, `filterCompressor`, `filterActive` 등 Ko/En/Ja

### 3. AudioEngine.swift — 핵심 오디오 로직

**새 상태 변수:**
- `filterType: FilterType` — 현재 필터 타입
- `fsB0/fsB1/fsB2/fsA1/fsA2` — Filter Sweep 전용 biquad 계수
- `fsX1/fsX2/fsY1/fsY2` — Filter Sweep 전용 biquad 상태
- `compressorEnabled: Bool`

**새 메서드:**
- `setFilterType(_:)` — 필터 타입 변경 + 계수 재계산
- `updateFilterSweep(cutoff:)` — LP/BP/HP별 biquad 계수 계산 (Audio EQ Cookbook)
- `applyFilterSweep(_:)` — 단일 샘플에 biquad 적용
- `applyCompressor(_:angle:)` — 각도 기반 소프트 니 컴프레서

**render() 변경:**
- Vinyl 블록 직후, 리듬 클럭 전에 `.filter` 전용 early-return 블록 추가
- `readSamples()` → `applyFilterSweep()` → (optional) `applyCompressor()` → 출력
- `setFilterAngle()` 수정: filter 모드일 때 sweep 계수도 업데이트
- `setMode(.filter)` 시 필터 상태 초기화

### 4. ContentView.swift — UI + tick 로직

**새 State:**
- `filterType: FilterType`, `compressorEnabled: Bool`, `filterCutoffDisplay: Double`

**UI:**
- 모드 버튼 추가 (icon: `line.3.horizontal.decrease`)
- `filterSection`: 필터 타입 셀렉터 (3버튼), 컷오프 주파수 표시, 컴프레서 토글, 시스템 오디오 상태
- filter 모드에서 악기 셀렉터 숨기기 (패스스루이므로 불필요)
- songInfoSection에서 filter 모드일 때 악기 대신 필터 타입 표시

**tick() 로직:**
- `.filter` case: `filterCutoffDisplay` 업데이트, MIDI CC 전송
- `currentFreq = filterCutoffDisplay` (컷오프를 주파수로 표시)

**모드 전환:**
- Command 홀드 오버레이: filter 모드에서 비활성화

**onChange 바인딩:**
- `filterType` → `audioEngine.setFilterType()`
- `compressorEnabled` → `audioEngine.setCompressorEnabled()`

## Filter Coefficients (Audio EQ Cookbook)

| Type | b0 | b1 | b2 |
|------|----|----|-----|
| Low-Pass | (1-cos)/2 | 1-cos | (1-cos)/2 |
| Band-Pass | alpha | 0 | -alpha |
| High-Pass | (1+cos)/2 | -(1+cos) | (1+cos)/2 |

공통: `a0=1+alpha`, `a1=-2cos`, `a2=1-alpha`, Q=0.707(LP/HP), Q=3.0(BP)

## Implementation Order

1. Models.swift (enum)
2. L10n.swift (strings)
3. AudioEngine.swift (core audio)
4. ContentView.swift (UI + wiring)
5. Build & test

## Verification

1. `swift build` 성공 확인
2. 앱 실행 → Filter 모드 선택
3. 시스템에서 음악 재생 → 소리가 필터링되어 나오는지 확인
4. 덮개 각도 (또는 데모 슬라이더) 변경 → 컷오프 실시간 변화
5. LP/BP/HP 전환 시 각각 다른 필터 특성 확인
6. 컴프레서 토글 on/off 차이 확인
7. 다른 모드 전환 후 돌아왔을 때 정상 동작
