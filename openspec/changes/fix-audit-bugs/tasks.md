<!--
Каждый таск выполняется по схеме: СНАЧАЛА подтвердить, что баг существует в
текущем коде (искать по описанию конструкции, не по номеру строки — строки могли
сдвинуться). Если баг отсутствует/уже исправлен — отметить чекбокс и дописать
"N/A — <причина>", фикс не применять. Если валиден — исправить и отметить.
-->

## 1. Critical

- [x] 1.1 `OnboardingPermissionsView` (~330, 351): подтвердить, что `Timer.scheduledTimer` не сохраняется → хранить таймер в `@State`-свойстве, инвалидировать при завершении/disappear

## 2. High — краши (force unwrap/cast/index)

- [x] 2.1 `AudioFileProcessor` (~170): подтвердить force-unwrap `baseAddress!` на возможно пустом `int16Samples` → `guard !int16Samples.isEmpty` / `guard let`
- [x] 2.2 `AIEnhancementService` (~220): подтвердить `?? allPrompts.first!` на возможно пустом массиве → безопасный fallback на дефолтный текст
- [x] 2.3 `OnboardingModelDownloadView` (~13): подтвердить `... .first {…} as! WhisperModel` → `as?` с обработкой nil
- [x] 2.4 `VoiceInkEngine` (~45): подтвердить force-индекс `[0]` на результате `FileManager.urls` → `.first` с проверкой

## 3. High — concurrency

- [x] 3.1 `FluidAudioTranscriptionService` (~46-79): подтвердить гонку на `loadingTask` (класс не изолирован) → изолировать `@MainActor`/actor/lock, сохранить дедупликацию загрузок
- [x] 3.2 `AudioFileTranscriptionService` (~79): подтвердить изменение `isTranscribing` в catch вне MainActor → N/A — класс уже `@MainActor`, ошибка ложная
- [x] 3.3 `AudioFileTranscriptionService` (~191): подтвердить изменение `currentError`/`isTranscribing` во внешнем catch вне MainActor → N/A — класс уже `@MainActor`, ошибка ложная
- [x] 3.4 `RecordingShortcutManager` (~66): подтвердить доступ к `@MainActor`-полям (`middleClickMonitors`/`middleClickTask`) из global event monitor → бриджить через `MainActor.run`/`Task @MainActor`

## 4. High — потеря данных / error-handling

- [x] 4.1 `VoiceInkEngine` (~108): подтвердить `try? modelContext.save()` глотает ошибку при постинге success-уведомления → do/catch с логом (паттерн как на ~252), не постить успех при сбое
- [x] 4.2 `StreamingTranscriptionService` (~225-231): подтвердить два `fatalError` в `createProvider()` в `async throws`-контексте → бросать ошибку вместо `fatalError`

## 5. High — state / memory / logic

- [x] 5.1 `VoiceInkEngine` (~313-317): подтвердить, что `shouldCancelRecording` не сбрасывается в `.transcribing/.enhancing` → сброс `= false` (иначе stale-guard на ~157 прерывает новую запись)
- [x] 5.2 `VoiceInkEngine` (~456-468): подтвердить отсутствие `removeObserver` для двух observer'ов → добавить `deinit` со снятием
- [x] 5.3 `PowerModeSessionManager` (~73): подтвердить условную регистрацию observer при безусловном удалении → регистрировать для каждой сессии (симметрично) или сделать идемпотентным
- [x] 5.4 `PowerModeConfig` (~251): подтвердить `cleanedURL.contains(configURL)` → сравнение по границе домена (`example.com` ≠ `myexample.com`)
- [x] 5.5 `ShortcutMonitor` (~270-297): подтвердить, что при ненулевом `onShortcutPressed` ранний return не выставляет `isDown` → выставлять `state.isDown = true` до раннего return
- [x] 5.6 `CursorPaster` (~223-224): подтвердить `enterDown/enterUp` создаются без guard → `guard let` с логом (паттерн как в `pasteFromClipboard`)

## 6. Medium

- [x] 6.1 `StreamingTranscriptionService` (~212-214): подтвердить fire-and-forget Task с `disconnect()` → хранить/ожидать задачу либо вызывать через `cleanupStreaming()`
- [x] 6.2 `ScreenCaptureService` (~37): подтвердить `DispatchQueue.main.async` в `defer` внутри `@MainActor`-класса → `MainActor.run`
- [x] 6.3 `PowerModeConfigView` (~615): подтвердить, что guard не проверяет результат `cleanURL()` → валидировать `cleanedURL` на пустоту перед добавлением
- [x] 6.4 `LicenseViewModel` (~96-101): подтвердить, что ранний return при пустом ключе не сбрасывает `isValidating` → `isValidating = false` перед return
- [x] 6.5 `Transcription.swift` (~64-83): подтвердить, что `markAsCanceledTranscription()` не очищает `powerModeName`/`powerModeEmoji` → обнулить оба поля
- [x] 6.6 `AnnouncementManager` (~83): подтвердить `max(a, a)` no-op → реализовать корректное сравнение высоты панели с фреймом
- [x] 6.7 `SoundManager` (~14-19): подтвердить отсутствие `deinit`/`removeObserver` у singleton → добавить `deinit` со снятием observer
- [x] 6.8 `LanguageDictionary` (~48-50): подтвердить тихий fallback на `'en'` при пустом словаре → assert/warning в debug

## 7. Low

- [x] 7.1 `ClipboardManager` (~23): подтвердить несогласованную обработку результата `setString` (bundle id игнор vs sessionID проверка) → согласовать либо задокументировать намеренность
- [x] 7.2 `CopyIconButton` (~20-26): подтвердить, что повторные клики плодят `asyncAfter`-сбросы `copied` → хранить таймер, инвалидировать перед новым запуском

## 8. Финальная проверка

- [x] 8.1 Запустить `xcodebuild`, отделить новые ошибки компиляции от pre-existing (whisper/Sparkle/signing) — новых быть не должно. Итог: 2 ошибки найдены и исправлены (missing `try` на `createProvider()`, typo `accessibiltyTimer`); осталась только pre-existing provisioning profile error.
- [x] 8.2 Сверить исправленные пункты со сценариями `specs/code-correctness/spec.md` — все 17 сценариев покрыты. 2 N/A (3.2, 3.3 — false positive, класс уже @MainActor).
- [x] 8.3 Обновить `CODE_AUDIT.md`: отметить исправленные чекбоксы, пометить N/A (если были)
