import Foundation

/// Frequent two-letter words. NSSpellChecker accepts almost any two letters as a word, so at
/// this length conversion needs a positive signal: the converted form must be listed here and
/// the typed form must not be. Real English tokens whose ЙЦУКЕН image is a frequent Russian word
/// (vs→«мы», dj→«во», …) sit in both lists, which vetoes them in both directions.
/// Port of RuSwitcher ShortWords.swift (MIT, © Rashns).
enum ShortWords {
    private static let ru: Set<String> = [
        "не", "ты", "на", "он", "мы", "вы", "да", "но", "за", "бы", "же", "из",
        "ну", "по", "то", "от", "их", "ее", "её", "со", "ли", "ни", "об", "ей",
        "во", "им", "ко", "те", "та", "уж", "ок", "эй",
    ]
    private static let en: Set<String> = [
        "to", "it", "of", "is", "in", "we", "me", "he", "my", "on", "do", "no",
        "be", "so", "go", "if", "up", "at", "as", "an", "us", "or", "by", "am",
        "ok", "hi", "oh", "ah", "um", "mr", "ya",
        "vs", "dj", "kb", "jr", "bp", "ye", "ds",
    ]

    static func common(_ lang: String) -> Set<String>? {
        switch String(lang.prefix(2)) {
        case "ru": return ru
        case "en": return en
        default: return nil
        }
    }
}
