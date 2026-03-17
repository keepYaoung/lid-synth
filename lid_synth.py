#!/usr/bin/env python3
"""
LidSynth - MacBook 덮개 각도 → 신디사이저
  Glide  : 연속 피치 변화 (테레민)
  Scale  : 음계 스텝 + ADSR 엔벨로프
  Rhythm : BPM 클럭으로 박자에 맞춰 트리거
"""

import sys, time, math, threading
import tkinter as tk
from tkinter import ttk
import numpy as np
import sounddevice as sd

try:
    from pybooklid import LidSensor
except ImportError:
    print("pip install pybooklid 후 실행해주세요")
    sys.exit(1)

# ══════════════════════════════════════════════════════════
# 상수
# ══════════════════════════════════════════════════════════
SAMPLE_RATE = 44100
BLOCK_SIZE  = 512
ANGLE_MIN   = 15
ANGLE_MAX   = 175
BASE_MIDI   = 48    # C3

SCALES = {
    "Pentatonic": [0, 2, 4, 7, 9],
    "Major":      [0, 2, 4, 5, 7, 9, 11],
    "Minor":      [0, 2, 3, 5, 7, 8, 10],
    "Blues":      [0, 3, 5, 6, 7, 10],
}

INSTRUMENTS = {
    "Theremin": [0.55, 0.25, 0.12, 0.06, 0.02],
    "Flute":    [0.85, 0.10, 0.04, 0.01],
    "Organ":    [0.40, 0.38, 0.30, 0.20, 0.12, 0.06, 0.03],
    "String":   [0.45, 0.35, 0.25, 0.15, 0.08, 0.04],
    "Brass":    [0.35, 0.05, 0.30, 0.05, 0.25, 0.05, 0.15, 0.05, 0.08],
}
for _k in INSTRUMENTS:
    _t = sum(INSTRUMENTS[_k])
    INSTRUMENTS[_k] = [a / _t for a in INSTRUMENTS[_k]]

# ADSR (블록당 속도)
_SPB         = BLOCK_SIZE / SAMPLE_RATE
ATTACK_RATE  = _SPB / 0.04    # 40ms attack
DECAY_RATE   = _SPB / 0.15    # 150ms decay
SUSTAIN_LVL  = 0.72
RELEASE_RATE = _SPB / 0.10    # 100ms release

# 크로스페이드: 노트 전환 시 이전 음을 짧게 페이드아웃해서 클릭 제거
XFADE_N          = 256        # ~5.8ms @ 44100Hz
_xfade_pos       = XFADE_N    # >= XFADE_N → 비활성
_xfade_old_phase = 0.0
_xfade_old_freq  = 0.0
_xfade_old_env   = 0.0

# ══════════════════════════════════════════════════════════
# 공유 오디오 상태 (GIL로 원자적 r/w 보장)
# ══════════════════════════════════════════════════════════
_target_freq  = 0.0
_smooth_freq  = 0.0
_phase        = 0.0
_volume       = 0.22
_harmonics    = list(INSTRUMENTS["Theremin"])

_env_level    = 0.0
_env_phase    = "idle"     # idle | attack | decay | sustain | release
_note_trigger = False      # 센서 스레드 → 오디오 콜백
_note_release = False      # 각도가 무음 영역 진입 시

_mode         = "glide"    # glide | scale | rhythm
_scale_name   = "Pentatonic"
_bpm          = 120.0
_rhythm_phase = 0.0
_beat_flash   = False      # 박자 시각 피드백용


# ══════════════════════════════════════════════════════════
# 피치 변환
# ══════════════════════════════════════════════════════════
def angle_to_freq_glide(angle: float) -> float:
    if angle < ANGLE_MIN:
        return 0.0
    r = min((angle - ANGLE_MIN) / (ANGLE_MAX - ANGLE_MIN), 1.0)
    return 130.81 * (1046.50 / 130.81) ** r


def angle_to_midi(angle: float, scale_name: str):
    """각도 → 스케일 내 MIDI 노트 (3옥타브, C3~C6)"""
    if angle < ANGLE_MIN:
        return None
    scale = SCALES[scale_name]
    r     = min((angle - ANGLE_MIN) / (ANGLE_MAX - ANGLE_MIN), 1.0)
    total = len(scale) * 3
    step  = int(r * (total - 1) + 0.5)
    return BASE_MIDI + (step // len(scale)) * 12 + scale[step % len(scale)]


def midi_to_freq(midi: int) -> float:
    return 440.0 * (2 ** ((midi - 69) / 12))


def freq_to_note(freq: float) -> str:
    if freq < 20:
        return "---"
    notes = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]
    n = round(12 * math.log2(freq / 440.0)) + 69
    return f"{notes[n % 12]}{(n // 12) - 1}"


# ══════════════════════════════════════════════════════════
# 오디오 콜백
# ══════════════════════════════════════════════════════════
def _make_wave(harmonics, phases):
    w = np.zeros(len(phases))
    for i, amp in enumerate(harmonics, 1):
        w += amp * np.sin(i * phases)
    return w


def audio_callback(outdata, frames, time_info, status):
    global _smooth_freq, _phase
    global _env_level, _env_phase, _note_trigger, _note_release
    global _rhythm_phase, _beat_flash
    global _xfade_pos, _xfade_old_phase, _xfade_old_freq, _xfade_old_env

    mode = _mode
    t    = np.arange(frames, dtype=np.float64)

    # ── Rhythm: BPM 클럭 ─────────────────────────────────
    if mode == "rhythm":
        _rhythm_phase += _bpm / 60.0 * frames / SAMPLE_RATE
        if _rhythm_phase >= 1.0:
            _rhythm_phase -= 1.0
            if _target_freq > 20:
                _note_trigger = True
                _beat_flash   = True

    # ── 노트 이벤트 처리 ──────────────────────────────────
    if mode != "glide":
        if _note_release:
            _note_release = False
            _env_phase    = "release"

        if _note_trigger:
            _note_trigger = False
            # 이전 음이 울리고 있으면 크로스페이드로 부드럽게 소거
            if _env_level > 0.001 and _smooth_freq > 20:
                _xfade_old_phase = _phase
                _xfade_old_freq  = _smooth_freq
                _xfade_old_env   = _env_level
                _xfade_pos       = 0
            # 새 음 초기화 (위상 리셋 + 엔벨로프 0부터 시작)
            _smooth_freq = _target_freq
            _phase       = 0.0
            _env_level   = 0.0
            _env_phase   = "attack"

    # ── 주파수 업데이트 ──────────────────────────────────
    if mode == "glide":
        _smooth_freq += (_target_freq - _smooth_freq) * 0.04
    else:
        _smooth_freq = _target_freq

    # ── ADSR 엔벨로프: 블록 내 선형 램프 ────────────────
    #    스칼라 대신 np.linspace로 블록 경계 계단 노이즈 제거
    env_start = _env_level
    if mode != "glide":
        if _env_phase == "attack":
            _env_level = min(1.0, _env_level + ATTACK_RATE)
            if _env_level >= 1.0: _env_phase = "decay"
        elif _env_phase == "decay":
            _env_level = max(SUSTAIN_LVL, _env_level - DECAY_RATE)
            if _env_level <= SUSTAIN_LVL: _env_phase = "sustain"
        elif _env_phase == "release":
            _env_level = max(0.0, _env_level - RELEASE_RATE)
            if _env_level <= 0.0: _env_phase = "idle"
        env = np.linspace(env_start, _env_level, frames)  # 샘플별 부드러운 램프
    else:
        env = 1.0

    # ── 출력 버퍼 초기화 ─────────────────────────────────
    outdata[:] = 0.0

    # ── 새 음 파형 생성 ───────────────────────────────────
    active = _smooth_freq >= 20 and (
        mode == "glide" or not (env_start < 0.001 and _env_level < 0.001)
    )
    if active:
        phases = _phase + 2.0 * np.pi * _smooth_freq * t / SAMPLE_RATE
        _phase = float(phases[-1]) % (2.0 * np.pi)
        outdata[:, 0] = _make_wave(_harmonics, phases) * env * _volume
    elif mode == "glide":
        _phase = 0.0

    # ── 크로스페이드: 이전 음 페이드아웃 믹스인 ──────────
    #    새 음이 0에서 올라오는 동안 이전 음이 부드럽게 사라짐
    if _xfade_pos < XFADE_N:
        n   = min(XFADE_N - _xfade_pos, frames)
        p_x = _xfade_old_phase + 2.0 * np.pi * _xfade_old_freq * np.arange(n) / SAMPLE_RATE
        _xfade_old_phase = float(p_x[-1]) % (2.0 * np.pi)
        fade = _xfade_old_env * np.linspace(
            1.0 - _xfade_pos / XFADE_N,
            1.0 - (_xfade_pos + n) / XFADE_N,
            n
        )
        outdata[:n, 0] += _make_wave(_harmonics, p_x) * fade * _volume
        _xfade_pos += n

    # ── 최종 클립 ─────────────────────────────────────────
    outdata[:, 0] = np.clip(outdata[:, 0], -1.0, 1.0).astype(np.float32)


# ══════════════════════════════════════════════════════════
# GUI
# ══════════════════════════════════════════════════════════
BG       = "#0f0f1a"
PANEL    = "#16213e"
ACCENT   = "#00d4aa"
TEXT_DIM = "#556080"
TEXT_MID = "#8899bb"
TEXT_HI  = "#ddeeff"
BTN_UNSEL = "#1e2d50"
BTN_DIS   = "#131c30"

GAUGE_W = 680   
GAUGE_H = 380
CX, CY  = GAUGE_W // 2, GAUGE_H - 20
RADIUS  = 290


def _angle_to_canvas_rad(lid_angle: float) -> float:
    return math.radians(180 - max(0, min(lid_angle, 180)))


class LidSynthApp:
    def __init__(self, root: tk.Tk):
        self.root       = root
        self.root.title("JakdangSynth")
        self.root.configure(bg=BG)
        self.root.resizable(False, False)

        self._running   = True
        self._angle     = 0.0
        self._prev_midi = None
        self._sensor    = LidSensor()

        self._build_ui()
        self._start_threads()

    # ── UI 구성 ────────────────────────────────────────────
    def _build_ui(self):
        # 헤더
        hdr = tk.Frame(self.root, bg=BG)
        hdr.pack(fill="x", padx=20, pady=(16, 0))
        tk.Label(hdr, text="JakdangSynth", font=("Helvetica Neue", 20, "bold"),
                 bg=BG, fg=TEXT_HI).pack(side="left")
        tk.Label(hdr, text="맥북 각도 신디", font=("Helvetica Neue", 11),
                 bg=BG, fg=TEXT_DIM).pack(side="left", padx=10, pady=4)

        # 게이지
        self.canvas = tk.Canvas(self.root, width=GAUGE_W, height=GAUGE_H,
                                bg=BG, highlightthickness=0)
        self.canvas.pack(pady=(8, 0))
        self._draw_gauge_static()

        # 음정 + 비트 표시
        info = tk.Frame(self.root, bg=BG)
        info.pack(pady=(4, 8))

        self.note_lbl = tk.Label(info, text="---",
                                  font=("Helvetica Neue", 42, "bold"),
                                  bg=BG, fg=ACCENT, width=5, anchor="e")
        self.note_lbl.pack(side="left")

        sub = tk.Frame(info, bg=BG)
        sub.pack(side="left", padx=(4, 0))
        self.freq_lbl  = tk.Label(sub, text="  0.0 Hz", font=("Courier", 13),
                                   bg=BG, fg=TEXT_MID, anchor="w")
        self.freq_lbl.pack(anchor="w")
        self.angle_lbl = tk.Label(sub, text="  0.0°", font=("Courier", 13),
                                   bg=BG, fg=TEXT_DIM, anchor="w")
        self.angle_lbl.pack(anchor="w")

        # 비트 인디케이터 (리듬 모드 시각 피드백)
        beat_frame = tk.Frame(info, bg=BG)
        beat_frame.pack(side="left", padx=(16, 0))
        self._beat_canvas = tk.Canvas(beat_frame, width=20, height=20,
                                       bg=BG, highlightthickness=0)
        self._beat_canvas.pack()
        self._beat_dot = self._beat_canvas.create_oval(2, 2, 18, 18,
                                                        fill=BTN_UNSEL, outline="")

        # ── 구분선 ──
        tk.Frame(self.root, bg=PANEL, height=1).pack(fill="x", padx=20, pady=(0, 10))

        # ── MODE ──
        self._build_section("MODE", self.root)
        mode_row = tk.Frame(self.root, bg=BG)
        mode_row.pack(padx=20, anchor="w", pady=(0, 8))
        self._mode_btns = {}
        for m in ("Glide", "Scale", "Rhythm"):
            b = tk.Button(mode_row, text=m, font=("Helvetica Neue", 11),
                          relief="flat", bd=0, padx=14, pady=6, cursor="hand2",
                          command=lambda v=m.lower(): self._select_mode(v))
            b.pack(side="left", padx=3)
            self._mode_btns[m.lower()] = b

        # ── SCALE ──
        self._build_section("SCALE", self.root)
        scale_row = tk.Frame(self.root, bg=BG)
        scale_row.pack(padx=20, anchor="w", pady=(0, 8))
        self._scale_btns = {}
        for s in SCALES:
            b = tk.Button(scale_row, text=s, font=("Helvetica Neue", 11),
                          relief="flat", bd=0, padx=10, pady=6, cursor="hand2",
                          command=lambda v=s: self._select_scale(v))
            b.pack(side="left", padx=3)
            self._scale_btns[s] = b
        self._scale_row = scale_row

        # ── BPM (리듬 모드 전용, 기본 숨김) ──
        self._bpm_frame = tk.Frame(self.root, bg=BG)
        self._build_section("BPM", self._bpm_frame)
        bpm_ctrl = tk.Frame(self._bpm_frame, bg=BG)
        bpm_ctrl.pack(padx=20, anchor="w", pady=(0, 8))

        style = ttk.Style()
        style.theme_use("clam")
        style.configure("Synth.Horizontal.TScale",
                         background=BG, troughcolor=PANEL,
                         sliderrelief="flat", sliderthickness=14)

        self._bpm_var = tk.DoubleVar(value=120.0)
        self._bpm_lbl = tk.Label(bpm_ctrl, text="120", font=("Courier", 13, "bold"),
                                  bg=BG, fg=ACCENT, width=4)
        self._bpm_lbl.pack(side="right")
        ttk.Scale(bpm_ctrl, from_=40, to=240, variable=self._bpm_var,
                  orient="horizontal", style="Synth.Horizontal.TScale",
                  command=self._on_bpm, length=220).pack(side="left")

        # ── 구분선 ──
        tk.Frame(self.root, bg=PANEL, height=1).pack(fill="x", padx=20, pady=(0, 10))

        # ── INSTRUMENT ──
        self._build_section("INSTRUMENT", self.root)
        inst_row = tk.Frame(self.root, bg=BG)
        inst_row.pack(padx=20, anchor="w", pady=(0, 8))
        self._inst_btns = {}
        for name in INSTRUMENTS:
            b = tk.Button(inst_row, text=name, font=("Helvetica Neue", 11),
                          relief="flat", bd=0, padx=10, pady=6, cursor="hand2",
                          command=lambda n=name: self._select_inst(n))
            b.pack(side="left", padx=3)
            self._inst_btns[name] = b

        # ── VOLUME ──
        vol_row = tk.Frame(self.root, bg=BG)
        vol_row.pack(fill="x", padx=20, pady=(0, 16))
        tk.Label(vol_row, text="VOL", font=("Helvetica Neue", 9, "bold"),
                 bg=BG, fg=TEXT_DIM, width=5, anchor="w").pack(side="left")
        self._vol_var = tk.DoubleVar(value=0.22)
        ttk.Scale(vol_row, from_=0, to=0.6, variable=self._vol_var,
                  orient="horizontal", style="Synth.Horizontal.TScale",
                  command=self._on_vol).pack(side="left", fill="x", expand=True)

        # 초기 선택
        self._select_mode("glide", init=True)
        self._select_scale("Pentatonic", init=True)
        self._select_inst("Theremin")

    def _build_section(self, label: str, parent):
        tk.Label(parent, text=label, font=("Helvetica Neue", 9, "bold"),
                 bg=BG, fg=TEXT_DIM).pack(padx=20, anchor="w", pady=(0, 4))

    # ── 게이지 ────────────────────────────────────────────
    def _draw_gauge_static(self):
        c, r = self.canvas, RADIUS

        c.create_arc(CX-r, CY-r, CX+r, CY+r,
                     start=0, extent=180, style="arc", outline=PANEL, width=18)

        for i in range(180):
            t = i / 179
            gg = int(150 + t * 105)
            bb = int(220 - t * 100)
            c.create_arc(CX-r, CY-r, CX+r, CY+r,
                         start=i, extent=1.2, style="arc",
                         outline=f"#00{gg:02x}{bb:02x}", width=18)

        for deg in range(0, 181, 30):
            a = math.radians(deg)
            for ir, or_, w, col in [(r-22,r-8,2,"#334466"),(r-8,r+2,1,TEXT_DIM)]:
                c.create_line(CX+ir*math.cos(a), CY-ir*math.sin(a),
                              CX+or_*math.cos(a), CY-or_*math.sin(a), fill=col, width=w)
            lr = r + 18
            c.create_text(CX+lr*math.cos(a), CY-lr*math.sin(a),
                          text=f"{180-deg}°", font=("Courier", 8), fill=TEXT_DIM)

        arc_start = 180 - ANGLE_MIN
        c.create_arc(CX-r, CY-r, CX+r, CY+r, start=arc_start, extent=ANGLE_MIN,
                     style="arc", outline="#2a1a2e", width=18)

        self._needle = c.create_line(CX, CY, CX-r+22, CY,
                                      fill="#ff4466", width=3, capstyle="round")
        c.create_oval(CX-6, CY-6, CX+6, CY+6, fill="#ff4466", outline=BG, width=2)
        c.create_rectangle(0, CY, GAUGE_W, GAUGE_H, fill=BG, outline="")

    def _move_needle(self, angle: float):
        a  = _angle_to_canvas_rad(angle)
        nr = RADIUS - 22
        self.canvas.coords(self._needle, CX, CY,
                           CX + nr*math.cos(a), CY - nr*math.sin(a))

    # ── 선택 핸들러 ────────────────────────────────────────
    def _select_mode(self, mode: str, init=False):
        global _mode, _rhythm_phase, _env_level, _env_phase
        global _note_trigger, _note_release

        _mode         = mode
        _rhythm_phase = 0.0
        _env_level    = 0.0
        _env_phase    = "idle"
        _note_trigger = False
        _note_release = False
        self._prev_midi = None

        for m, b in self._mode_btns.items():
            if m == mode:
                b.config(bg=ACCENT, fg=BG, font=("Helvetica Neue", 11, "bold"))
            else:
                b.config(bg=BTN_UNSEL, fg=TEXT_MID, font=("Helvetica Neue", 11))

        # Scale 버튼: Glide에선 비활성
        scale_enabled = (mode != "glide")
        for b in self._scale_btns.values():
            b.config(state="normal" if scale_enabled else "disabled",
                     bg=BTN_DIS if not scale_enabled else
                        (ACCENT if b.cget("text") == _scale_name else BTN_UNSEL),
                     fg=TEXT_DIM if not scale_enabled else
                        (BG if b.cget("text") == _scale_name else TEXT_MID))

        # BPM 섹션: Rhythm 전용
        if mode == "rhythm":
            self._bpm_frame.pack(fill="x", after=self._scale_row)
        else:
            self._bpm_frame.pack_forget()

    def _select_scale(self, scale: str, init=False):
        global _scale_name
        _scale_name     = scale
        self._prev_midi = None
        for s, b in self._scale_btns.items():
            if s == scale:
                b.config(bg=ACCENT, fg=BG, font=("Helvetica Neue", 11, "bold"))
            else:
                b.config(bg=BTN_UNSEL, fg=TEXT_MID, font=("Helvetica Neue", 11))

    def _select_inst(self, name: str):
        global _harmonics
        _harmonics = list(INSTRUMENTS[name])
        for n, b in self._inst_btns.items():
            if n == name:
                b.config(bg=ACCENT, fg=BG, font=("Helvetica Neue", 11, "bold"))
            else:
                b.config(bg=BTN_UNSEL, fg=TEXT_MID, font=("Helvetica Neue", 11))

    def _on_bpm(self, _=None):
        global _bpm
        _bpm = self._bpm_var.get()
        self._bpm_lbl.config(text=f"{int(_bpm)}")

    def _on_vol(self, _=None):
        global _volume
        _volume = self._vol_var.get()

    # ── 센서 스레드 ────────────────────────────────────────
    def _sensor_loop(self):
        global _target_freq, _note_trigger, _note_release
        while self._running:
            try:
                angle = self._sensor.read_angle()
                self._angle = angle
                mode = _mode

                if mode == "glide":
                    _target_freq    = angle_to_freq_glide(angle)
                    self._prev_midi = None
                else:
                    midi = angle_to_midi(angle, _scale_name)
                    if midi is not None:
                        _target_freq = midi_to_freq(midi)
                        if mode == "scale" and midi != self._prev_midi:
                            _note_trigger = True
                        self._prev_midi = midi
                    else:
                        _target_freq = 0.0
                        if self._prev_midi is not None:
                            _note_release = True
                        self._prev_midi = None
            except Exception:
                pass
            time.sleep(0.04)

    def _start_threads(self):
        threading.Thread(target=self._sensor_loop, daemon=True).start()
        self._update_ui()

    # ── UI 갱신 루프 ──────────────────────────────────────
    def _update_ui(self):
        global _beat_flash

        angle = self._angle
        freq  = _smooth_freq
        note  = freq_to_note(freq)

        self._move_needle(angle)
        self.note_lbl.config(text=note, fg=ACCENT if freq > 20 else TEXT_DIM)
        self.freq_lbl.config(text=f"{freq:>7.1f} Hz")
        self.angle_lbl.config(text=f"{angle:>6.1f}°")

        # 비트 인디케이터
        if _beat_flash:
            _beat_flash = False
            self._beat_canvas.itemconfig(self._beat_dot, fill=ACCENT)
            self.root.after(120, lambda: self._beat_canvas.itemconfig(
                self._beat_dot, fill=BTN_UNSEL))

        self.root.after(40, self._update_ui)

    def on_close(self):
        self._running = False
        self.root.destroy()


# ══════════════════════════════════════════════════════════
# 진입점
# ══════════════════════════════════════════════════════════
def main():
    root = tk.Tk()
    app  = LidSynthApp(root)
    root.protocol("WM_DELETE_WINDOW", app.on_close)

    with sd.OutputStream(
        samplerate=SAMPLE_RATE,
        channels=1,
        callback=audio_callback,
        blocksize=BLOCK_SIZE,
        dtype="float32",
    ):
        root.mainloop()


if __name__ == "__main__":
    main()
