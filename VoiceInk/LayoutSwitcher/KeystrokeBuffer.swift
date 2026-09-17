import Foundation

/// One physical key press, kept as a key code so the same word can be rendered in either
/// layout of the pair through UCKeyTranslate.
struct TypedKey: Equatable {
    let keyCode: UInt16
    let shift: Bool
    let caps: Bool
    /// Character produced under the layout active at the moment this key was pressed.
    /// Stored at type time so a mid-word layout switch can't corrupt the reconstruction.
    var char: Character?
    init(keyCode: UInt16, shift: Bool, caps: Bool, char: Character? = nil) {
        self.keyCode = keyCode; self.shift = shift; self.caps = caps; self.char = char
    }
}

/// What the user typed since the last context reset. The engine feeds it from the event tap
/// and asks it for the last word; it never touches the screen itself.
struct KeystrokeBuffer: Equatable {
    private(set) var currentWord: [TypedKey] = []
    private(set) var previousWord: [TypedKey] = []
    /// Spaces typed after `previousWord`; 0 while `currentWord` is being typed.
    private(set) var boundaryCount = 0

    mutating func append(_ key: TypedKey) {
        currentWord.append(key)
        previousWord = []
        boundaryCount = 0
    }

    /// The word the space just completed, or nil when the space only widens an existing gap.
    mutating func space() -> [TypedKey]? {
        defer { currentWord = [] }
        guard !currentWord.isEmpty else {
            if !previousWord.isEmpty { boundaryCount += 1 }
            return nil
        }
        previousWord = currentWord
        boundaryCount = 1
        return currentWord
    }

    /// Backspace inside the current word drops its last key. Backspace across a word boundary
    /// makes the model unreliable, so it resets and returns false.
    @discardableResult
    mutating func backspace() -> Bool {
        guard !currentWord.isEmpty else {
            reset()
            return false
        }
        currentWord.removeLast()
        return true
    }

    mutating func reset() {
        currentWord = []
        previousWord = []
        boundaryCount = 0
    }

    /// What the manual trigger converts: the word being typed, else the last completed word
    /// together with the spaces after it (they are deleted and retyped as-is).
    var manualTarget: (keys: [TypedKey], trailingSpaces: Int)? {
        if !currentWord.isEmpty { return (currentWord, 0) }
        if !previousWord.isEmpty { return (previousWord, boundaryCount) }
        return nil
    }
}
