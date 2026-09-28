import Foundation
import LaunchAtLogin
import SwiftData

enum BackupImportError: LocalizedError {
    case saveFailed(String, Error)

    var errorDescription: String? {
        switch self {
        case .saveFailed(let item, let error):
            return "Failed to save imported \(item): \(error.localizedDescription)"
        }
    }
}

enum BackupImporter {
    private static let keyIsAudioCleanupEnabled = "IsAudioCleanupEnabled"
    private static let keyIsTranscriptionCleanupEnabled = "IsTranscriptionCleanupEnabled"
    private static let keyTranscriptionRetentionMinutes = "TranscriptionRetentionMinutes"
    private static let keyAudioRetentionPeriod = "AudioRetentionPeriod"

    private static let keyIsTextFormattingEnabled = "IsTextFormattingEnabled"
    private static let keyLowercaseTranscription = "LowercaseTranscription"

    @MainActor
    static func apply(_ backup: BackupFile, categories: Set<BackupCategory>, enhancementService: AIEnhancementService, recordingShortcutManager: RecordingShortcutManager, menuBarManager: MenuBarManager, mediaController: MediaController, playbackController: PlaybackController, soundManager: SoundManager, recorderUIManager: RecorderUIManager, modelContext: ModelContext, transcriptionModelManager: TranscriptionModelManager) throws {
        if categories.contains(.dictionary) {
            try importDictionary(from: backup, modelContext: modelContext)
        }

        var rejectedShortcuts: [(action: ShortcutAction, shortcut: Shortcut)] = []
        if categories.contains(.general) {
            rejectedShortcuts = importGeneral(
                backup.generalSettings,
                recordingShortcutManager: recordingShortcutManager,
                menuBarManager: menuBarManager,
                mediaController: mediaController,
                playbackController: playbackController,
                soundManager: soundManager,
                recorderUIManager: recorderUIManager
            )
        }

        // An absent prompts/powerMode section decodes to an empty array (BackupTypes),
        // so guard on non-empty: replacing with [] on a partial or foreign import (e.g.
        // a dictionary-only export, or any JSON missing these keys) would silently wipe
        // the user's custom prompts / power-mode configs with no undo.
        if categories.contains(.prompts), !backup.customPrompts.isEmpty {
            let predefinedPrompts = enhancementService.customPrompts.filter { $0.isPredefined }
            let predefinedIds = Set(predefinedPrompts.map(\.id))
            var seenIds = predefinedIds
            // Exports never contain predefined prompts, but a hand-edited or foreign
            // file can — duplicates by id would shadow real prompts after import.
            let importablePrompts = backup.customPrompts.filter { seenIds.insert($0.id).inserted }
            enhancementService.customPrompts = predefinedPrompts + importablePrompts
            enhancementService.healSelectedPromptId()
            print("Successfully imported \(importablePrompts.count) custom prompts.")
        }

        if categories.contains(.powerMode) {
            let powerModeManager = PowerModeManager.shared

            if !backup.powerModeConfigs.isEmpty {
                // Erase local bindings only when the backup carries its own shortcut map:
                // a config-only backup used to wipe this machine's bindings for those IDs.
                if backup.powerModeShortcuts != nil {
                    for config in powerModeManager.configurations {
                        ShortcutStore.removeShortcutStorage(for: .powerMode(config.id))
                    }
                }

                powerModeManager.configurations = backup.powerModeConfigs
                let importedPowerModeIds = Set(backup.powerModeConfigs.map(\.id))

                if let shortcuts = backup.powerModeShortcuts {
                    for (idString, shortcutBackup) in shortcuts {
                        guard
                            let id = UUID(uuidString: idString),
                            importedPowerModeIds.contains(id)
                        else {
                            continue
                        }

                        ShortcutStore.setShortcut(shortcutBackup.shortcut, for: .powerMode(id))
                    }
                }

                powerModeManager.saveConfigurations()
            }

            if let customEmojis = backup.customEmojis {
                let emojiManager = EmojiManager.shared
                for emoji in customEmojis {
                    _ = emojiManager.addCustomEmoji(emoji)
                }
            }
            print("Successfully imported \(backup.powerModeConfigs.count) Power Mode configurations.")
        }

        // The general import runs before power modes, so its shortcuts can be rejected
        // by bindings this machine still had — which the power-mode import above just
        // replaced. Retry once, then surface what truly couldn't land.
        if !rejectedShortcuts.isEmpty {
            var stillRejected: [(action: ShortcutAction, shortcut: Shortcut)] = []
            for (action, shortcut) in rejectedShortcuts where !ShortcutStore.setShortcut(shortcut, for: action) {
                stillRejected.append((action, shortcut))
            }
            if !stillRejected.isEmpty {
                NotificationManager.shared.showNotification(
                    title: String.localizedStringWithFormat(
                        String(localized: "%lld shortcuts from the backup conflict with existing ones and were not imported"),
                        stillRejected.count),
                    type: .warning
                )
            }
        }

        if categories.contains(.customModels) {
            importCustomModels(backup.customCloudModels, transcriptionModelManager: transcriptionModelManager)
        }
    }

    @MainActor
    /// Returns shortcuts the validator rejected (e.g. still held by a local power-mode
    /// binding that the power-mode import frees a moment later); `apply` retries them.
    private static func importGeneral(_ general: GeneralBackup?, recordingShortcutManager: RecordingShortcutManager, menuBarManager: MenuBarManager, mediaController: MediaController, playbackController: PlaybackController, soundManager: SoundManager, recorderUIManager: RecorderUIManager) -> [(action: ShortcutAction, shortcut: Shortcut)] {
        var rejected: [(ShortcutAction, Shortcut)] = []
        guard let general else {
            print("No general settings found in the imported file.")
            return []
        }

        if let shortcut = general.primaryRecordingShortcut {
            // Only switch the UI to Custom when the store actually accepted the binding;
            // a rejected one used to leave "Custom" with no shortcut behind it.
            if ShortcutStore.setShortcut(shortcut.shortcut, for: .primaryRecording) {
                recordingShortcutManager.primaryRecordingShortcut = .custom
            } else {
                rejected.append((.primaryRecording, shortcut.shortcut))
            }
        }
        if let shortcut2 = general.secondaryRecordingShortcut {
            if ShortcutStore.setShortcut(shortcut2.shortcut, for: .secondaryRecording) {
                recordingShortcutManager.secondaryRecordingShortcut = .custom
            } else {
                rejected.append((.secondaryRecording, shortcut2.shortcut))
            }
        }
        if let pasteShortcut = general.pasteLastTranscriptionShortcut {
            if !ShortcutStore.setShortcut(pasteShortcut.shortcut, for: .pasteLastTranscription) {
                rejected.append((.pasteLastTranscription, pasteShortcut.shortcut))
            }
        }
        if let pasteEnhancementShortcut = general.pasteLastEnhancementShortcut {
            if !ShortcutStore.setShortcut(pasteEnhancementShortcut.shortcut, for: .pasteLastEnhancement) {
                rejected.append((.pasteLastEnhancement, pasteEnhancementShortcut.shortcut))
            }
        }
        if let retryShortcut = general.retryLastTranscriptionShortcut {
            if !ShortcutStore.setShortcut(retryShortcut.shortcut, for: .retryLastTranscription) {
                rejected.append((.retryLastTranscription, retryShortcut.shortcut))
            }
        }
        if let retranscribeLayoutShortcut = general.retranscribeLastInLayoutLanguageShortcut {
            if !ShortcutStore.setShortcut(retranscribeLayoutShortcut.shortcut, for: .retranscribeLastInLayoutLanguage) {
                rejected.append((.retranscribeLastInLayoutLanguage, retranscribeLayoutShortcut.shortcut))
            }
        }
        if let convertLayoutShortcut = general.convertLayoutShortcut {
            if !ShortcutStore.setShortcut(convertLayoutShortcut.shortcut, for: .convertLayout) {
                rejected.append((.convertLayout, convertLayoutShortcut.shortcut))
            }
        }
        if let quickHistoryShortcut = general.openQuickHistoryShortcut {
            if !ShortcutStore.setShortcut(quickHistoryShortcut.shortcut, for: .openQuickHistory) {
                rejected.append((.openQuickHistory, quickHistoryShortcut.shortcut))
            }
        }
        if let cancelShortcut = general.cancelRecorderShortcut {
            if !ShortcutStore.setShortcut(cancelShortcut.shortcut, for: .cancelRecorder) {
                rejected.append((.cancelRecorder, cancelShortcut.shortcut))
            }
        }
        if let historyShortcut = general.openHistoryWindowShortcut {
            if !ShortcutStore.setShortcut(historyShortcut.shortcut, for: .openHistoryWindow) {
                rejected.append((.openHistoryWindow, historyShortcut.shortcut))
            }
        }
        if let dictionaryShortcut = general.quickAddToDictionaryShortcut {
            if !ShortcutStore.setShortcut(dictionaryShortcut.shortcut, for: .quickAddToDictionary) {
                rejected.append((.quickAddToDictionary, dictionaryShortcut.shortcut))
            }
        }
        if let enhancementShortcut = general.toggleEnhancementShortcut {
            if !ShortcutStore.setShortcut(enhancementShortcut.shortcut, for: .toggleEnhancement) {
                rejected.append((.toggleEnhancement, enhancementShortcut.shortcut))
            }
        }
        if let enhanceShortcut = general.enhanceSelectedTextShortcut {
            if !ShortcutStore.setShortcut(enhanceShortcut.shortcut, for: .enhanceSelectedText) {
                rejected.append((.enhanceSelectedText, enhanceShortcut.shortcut))
            }
        }

        if let shortcutRawValue = general.primaryRecordingShortcutRawValue,
           let shortcut = RecordingShortcutManager.ShortcutSelection(rawValue: shortcutRawValue) {
            recordingShortcutManager.primaryRecordingShortcut = shortcut
        }
        if let secondaryShortcutRawValue = general.secondaryRecordingShortcutRawValue,
           let secondaryShortcut = RecordingShortcutManager.ShortcutSelection(rawValue: secondaryShortcutRawValue) {
            recordingShortcutManager.secondaryRecordingShortcut = secondaryShortcut
        }
        if let modeRawValue = general.primaryRecordingShortcutModeRawValue,
           let mode = RecordingShortcutManager.Mode(rawValue: modeRawValue) {
            recordingShortcutManager.primaryRecordingShortcutMode = mode
        }
        if let secondaryModeRawValue = general.secondaryRecordingShortcutModeRawValue,
           let secondaryMode = RecordingShortcutManager.Mode(rawValue: secondaryModeRawValue) {
            recordingShortcutManager.secondaryRecordingShortcutMode = secondaryMode
        }
        if let middleClickEnabled = general.isMiddleClickToggleEnabled {
            recordingShortcutManager.isMiddleClickToggleEnabled = middleClickEnabled
        }
        if let middleClickDelay = general.middleClickActivationDelay {
            recordingShortcutManager.middleClickActivationDelay = middleClickDelay
        }
        if let launch = general.launchAtLoginEnabled {
            LaunchAtLogin.isEnabled = launch
        }
        if let menuOnly = general.isMenuBarOnly {
            menuBarManager.isMenuBarOnly = menuOnly
        }
        if let recType = general.recorderType {
            recorderUIManager.recorderType = recType
        }

        if let transcriptionCleanup = general.isTranscriptionCleanupEnabled {
            UserDefaults.standard.set(transcriptionCleanup, forKey: keyIsTranscriptionCleanupEnabled)
        }
        if let transcriptionMinutes = general.transcriptionRetentionMinutes {
            UserDefaults.standard.set(transcriptionMinutes, forKey: keyTranscriptionRetentionMinutes)
        }
        if let audioCleanup = general.isAudioCleanupEnabled {
            UserDefaults.standard.set(audioCleanup, forKey: keyIsAudioCleanupEnabled)
        }
        if let audioRetention = general.audioRetentionPeriod {
            UserDefaults.standard.set(audioRetention, forKey: keyAudioRetentionPeriod)
        }

        if let soundFeedback = general.isSoundFeedbackEnabled {
            soundManager.isEnabled = soundFeedback
        }
        if let muteSystem = general.isSystemMuteEnabled {
            mediaController.isSystemMuteEnabled = muteSystem
        }
        if let pauseMedia = general.isPauseMediaEnabled {
            playbackController.isPauseMediaEnabled = pauseMedia
        }
        if let audioDelay = general.audioResumptionDelay {
            mediaController.audioResumptionDelay = audioDelay
        }
        if let experimentalEnabled = general.isExperimentalFeaturesEnabled {
            UserDefaults.standard.set(experimentalEnabled, forKey: "isExperimentalFeaturesEnabled")
            if experimentalEnabled == false {
                playbackController.isPauseMediaEnabled = false
            }
        }
        if let textFormattingEnabled = general.isTextFormattingEnabled {
            UserDefaults.standard.set(textFormattingEnabled, forKey: keyIsTextFormattingEnabled)
        }
        if let punctuationCleanupMode = general.punctuationCleanupMode {
            PunctuationCleanupMode.setCurrent(punctuationCleanupMode)
        } else if let removePunctuation = general.removePunctuation {
            PunctuationCleanupMode.setCurrent(removePunctuation ? .removeAll : .keep)
        }
        if let lowercaseTranscription = general.lowercaseTranscription {
            UserDefaults.standard.set(lowercaseTranscription, forKey: keyLowercaseTranscription)
        }
        if let restoreClipboard = general.restoreClipboardAfterPaste {
            UserDefaults.standard.set(restoreClipboard, forKey: "restoreClipboardAfterPaste")
        }
        if let clipboardDelay = general.clipboardRestoreDelay {
            UserDefaults.standard.set(clipboardDelay, forKey: "clipboardRestoreDelay")
        }
        if let customProviderHeaders = general.customProviderHeaders {
            if let encoded = try? JSONEncoder().encode(customProviderHeaders) {
                UserDefaults.standard.set(encoded, forKey: "customProviderHeaders")
            }
        }
        let importedReviewSchedule = general.autoLearnReviewSchedule.flatMap {
            AutoLearnReviewSchedule(rawValue: $0)
        }
        if let importedReviewSchedule {
            UserDefaults.standard.set(importedReviewSchedule.rawValue, forKey: AutoLearnSettings.reviewScheduleKey)
        }
        if let autoLearnEnabled = general.isAutoLearnDictionaryEnabled {
            UserDefaults.standard.set(autoLearnEnabled, forKey: AutoLearnSettings.isEnabledKey)
        }
        if let provider = general.autoLearnProvider {
            UserDefaults.standard.set(provider, forKey: AutoLearnSettings.providerKey)
        }
        if let model = general.autoLearnModel {
            UserDefaults.standard.set(model, forKey: AutoLearnSettings.modelKey)
        }
        if general.isAutoLearnDictionaryEnabled != nil || importedReviewSchedule != nil {
            Task {
                if let autoLearnEnabled = general.isAutoLearnDictionaryEnabled {
                    await AutoLearnService.shared.settingDidChange(isEnabled: autoLearnEnabled)
                } else {
                    await AutoLearnService.shared.reviewScheduleDidChange()
                }
            }
        }

        if let selectionVoiceEditEnabled = general.isSelectionVoiceEditEnabled {
            UserDefaults.standard.set(selectionVoiceEditEnabled, forKey: SelectionEditService.isEnabledKey)
        }

        if let promptId = general.selectedPromptId, UUID(uuidString: promptId) != nil {
            // Read by AIEnhancementService at launch; the notification lets a running
            // instance re-read it too.
            UserDefaults.standard.set(promptId, forKey: "selectedPromptId")
            NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
        }

        print("Successfully imported general settings.")
        return rejected
    }

    @MainActor
    static func importDictionary(from backup: BackupFile, modelContext: ModelContext) throws {
        var insertedWords = 0
        var insertedReplacements = 0
        var skippedInvalidReplacements = 0
        var skippedConflictingReplacements = 0

        if let words = backup.vocabularyWords {
            let descriptor = FetchDescriptor<VocabularyWord>()
            let existingWords = try modelContext.fetch(descriptor)
            var existingWordsSet = Set(existingWords.map { $0.word.lowercased() })

            for item in words {
                let word = item.word.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !word.isEmpty else { continue }

                let lowercasedWord = word.lowercased()
                if !existingWordsSet.contains(lowercasedWord) {
                    modelContext.insert(VocabularyWord(word: word))
                    existingWordsSet.insert(lowercasedWord)
                    insertedWords += 1
                }
            }
        } else {
            print("No vocabulary words found in the imported file. Existing items remain unchanged.")
        }

        if let replacements = backup.wordReplacements {
            let descriptor = FetchDescriptor<WordReplacement>()
            let existingReplacements = try modelContext.fetch(descriptor)

            var existingKeys = Set<String>()
            for existing in existingReplacements {
                existingKeys.formUnion(tokens(from: existing.originalText))
            }

            for (original, replacement) in replacements {
                let trimmedOriginal = original.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedReplacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
                let importTokens = tokens(from: trimmedOriginal)
                guard !importTokens.isEmpty, !trimmedReplacement.isEmpty else {
                    skippedInvalidReplacements += 1
                    continue
                }

                let hasConflict = importTokens.contains { existingKeys.contains($0) }

                if hasConflict {
                    skippedConflictingReplacements += 1
                } else {
                    modelContext.insert(WordReplacement(originalText: trimmedOriginal, replacementText: trimmedReplacement))
                    existingKeys.formUnion(importTokens)
                    insertedReplacements += 1
                }
            }
        } else {
            print("No word replacements found in the imported file. Existing replacements remain unchanged.")
        }

        guard insertedWords > 0 || insertedReplacements > 0 else {
            print("No new dictionary entries were imported.")
            if skippedInvalidReplacements > 0 {
                print("Skipped \(skippedInvalidReplacements) invalid word replacements from the imported file.")
            }
            return
        }

        do {
            try modelContext.save()
            print("Successfully imported \(insertedWords) vocabulary words and \(insertedReplacements) word replacements to SwiftData.")
            if skippedInvalidReplacements > 0 {
                print("Skipped \(skippedInvalidReplacements) invalid word replacements from the imported file.")
            }
            if skippedConflictingReplacements > 0 {
                NotificationManager.shared.showNotification(
                    title: String.localizedStringWithFormat(
                        String(localized: "%lld dictionary entries were skipped: their trigger words already exist"),
                        skippedConflictingReplacements),
                    type: .warning
                )
            }
        } catch {
            modelContext.rollback()
            throw BackupImportError.saveFailed("dictionary entries", error)
        }
    }

    @MainActor
    private static func importCustomModels(_ models: [CustomModelBackup]?, transcriptionModelManager: TranscriptionModelManager) {
        // An absent OR empty custom-models section must not wipe existing definitions: exports
        // always write the key (present, possibly []), so replacing unconditionally would delete a
        // user's custom models — and orphan their keychain keys — when importing a backup that had
        // none. Same guard as the prompts / power-mode import paths.
        guard let models, !models.isEmpty else {
            print("No custom models found in the imported file.")
            return
        }

        let customModelManager = CustomCloudModelManager.shared
        let importedModelIds = Set(models.map(\.id))
        for existing in customModelManager.customModels where !importedModelIds.contains(existing.id) {
            APIKeyManager.shared.deleteCustomModelAPIKey(forModelId: existing.id)
        }
        customModelManager.customModels = models.map { $0.makeModel() }
        customModelManager.saveCustomModels()
        transcriptionModelManager.refreshAllAvailableModels()
        print("Successfully imported \(models.count) custom model definitions.")
    }

    private static func tokens(from text: String) -> [String] {
        text
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }
}
