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
