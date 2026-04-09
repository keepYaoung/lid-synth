import Foundation

/// Localization helper — supports Korean, English, Japanese
enum L10n {
    private static let lang: String = {
        let preferred = Locale.preferredLanguages.first ?? "en"
        if preferred.hasPrefix("ko") { return "ko" }
        if preferred.hasPrefix("ja") { return "ja" }
        return "en"
    }()

    // MARK: - Mode names
    static var modeVinyl: String { pick("Vinyl", "Vinyl", "Vinyl") }
    static var modeGlide: String { pick("Glide", "Glide", "Glide") }
    static var modeScale: String { pick("Scale", "Scale", "Scale") }
    static var modeFader: String { pick("Fader", "Fader", "Fader") }
    static var modeRhythm: String { pick("Rhythm", "Rhythm", "Rhythm") }
    static var modeFilter: String { pick("Filter", "Filter", "Filter") }

    // MARK: - Filter
    static var filterLowPass: String { pick("Low-Pass", "Low-Pass", "Low-Pass") }
    static var filterBandPass: String { pick("Band-Pass", "Band-Pass", "Band-Pass") }
    static var filterHighPass: String { pick("High-Pass", "High-Pass", "High-Pass") }
    static var filterCutoff: String {
        pick("컷오프 주파수", "Cutoff Freq", "カットオフ周波数")
    }
    static var filterActive: String {
        pick("필터 스윕 활성", "Filter sweep active", "フィルタースイープ有効")
    }
    static var compressor: String {
        pick("컴프레서", "Compressor", "コンプレッサー")
    }

    // MARK: - Tips
    static var vinylOverlayTip: String {
        pick(
            "⌘ Command를 홀드하면 스크래치를 악기와 함께 쓸 수 있어요",
            "Hold ⌘ Command to scratch while playing an instrument",
            "⌘ Commandを押し続けると、楽器と一緒にスクラッチできます"
        )
    }

    // MARK: - Vinyl status
    static var sysAudioWarning: String {
        pick(
            "시스템 오디오 권한 필요 — 설정 > 개인정보 보호 > 화면 녹화에서 허용",
            "Screen recording permission required — Settings > Privacy > Screen Recording",
            "システムオーディオ権限が必要 — 設定 > プライバシー > 画面収録で許可"
        )
    }
    static var sysAudioActive: String {
        pick(
            "시스템 오디오 스크래치 활성",
            "System audio scratch active",
            "システムオーディオスクラッチ有効"
        )
    }

    // MARK: - Audio Source
    static var sourceSystem: String { pick("System", "System", "System") }
    static var sourceFile: String { pick("File", "File", "File") }
    static var sourceMic: String { pick("Mic", "Mic", "Mic") }
    static var loadFile: String {
        pick("파일 열기", "Load File", "ファイルを開く")
    }
    static var noFileLoaded: String {
        pick("파일을 선택하세요", "No file loaded", "ファイルを選択してください")
    }
    static var filePickerMessage: String {
        pick("오디오 파일을 선택하세요", "Select an audio file", "オーディオファイルを選択してください")
    }
    static var micRecording: String {
        pick("마이크 녹음 중", "Mic recording", "マイク録音中")
    }
    static var micInactive: String {
        pick("마이크 대기 중", "Mic inactive", "マイク待機中")
    }
    static var play: String { pick("재생", "Play", "再生") }
    static var pause: String { pick("일시정지", "Pause", "一時停止") }
    static var turntableHint: String {
        pick(
            "힌지를 움직여 스크래치",
            "Move hinge to scratch",
            "ヒンジを動かしてスクラッチ"
        )
    }

    // MARK: - Header
    static var appName: String { "hynthesizer" }
    static var cmdHold: String { "⌘ hold" }

    // MARK: - Helpers
    private static func pick(_ ko: String, _ en: String, _ ja: String) -> String {
        switch lang {
        case "ko": return ko
        case "ja": return ja
        default:   return en
        }
    }
}
