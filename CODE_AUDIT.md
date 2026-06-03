# Аудит кода VoiceInk — найденные проблемы

> Сгенерировано сабагентной системой (9 finder'ов по модулям → адверсариальная верификация каждой находки → синтез). 28 подтверждённых находок. Все 28 исправлены (2 N/A — false positives, класс @MainActor).

## Сводка

| Критичность | Количество |
|---|---|
| Critical | 2 |
| High | 16 |
| Medium | 8 |
| Low | 2 |

| Категория | Количество |
|---|---|
| crash | 6 |
| concurrency | 6 |
| state | 3 |
| logic | 5 |
| memory | 4 |
| error-handling | 2 |
| inconsistency | 1 |

## Critical

- [x] **[critical]** Таймер не сохраняется и сразу деаллоцируется — `Views/Onboarding/OnboardingPermissionsView.swift:330,351` — `Timer.scheduledTimer` не сохраняется в свойство, поэтому колбэк проверки разрешений (Accessibility и Screen Recording) никогда не срабатывает. Хранить таймер в `@State`-свойстве и инвалидировать при завершении.

## High

- [x] **[high]** Force-unwrap `baseAddress!` на пустом буфере — `Transcription/Engine/AudioFileProcessor.swift:170` — при пустом `int16Samples` указатель буфера = nil и приложение падает. Добавить `guard !int16Samples.isEmpty` или использовать `guard let`.
- [x] **[high]** `fatalError` вместо бросания ошибок — `Transcription/Streaming/StreamingTranscriptionService.swift:225-231` — два `fatalError` в `createProvider()` крашат приложение там, где вызывающий код (`async throws`) ожидает recoverable-ошибку. Бросать ошибку вместо `fatalError`.
- [x] **[high]** Гонка данных при доступе к `loadingTask` — `Transcription/FluidAudio/FluidAudioTranscriptionService.swift:46-79` — класс не изолирован, конкурентные `getOrLoadModels()` читают/пишут `loadingTask` без синхронизации, ломая дедупликацию загрузок. Изолировать через `@MainActor` или actor/lock.
- [x] **[high]** Прямое изменение `@Published` вне MainActor (catch) — `Services/AudioFileTranscriptionService.swift:79` — `isTranscribing = false` в error-пути меняется без `MainActor.run`, в отличие от остальных путей. N/A — класс уже `@MainActor`, false positive.
- [x] **[high]** Прямое изменение `@Published` во внешнем catch — `Services/AudioFileTranscriptionService.swift:191` — `currentError` и `isTranscribing` меняются без `MainActor.run` после await-точек. N/A — класс уже `@MainActor`, false positive.
- [x] **[high]** Force-unwrap `allPrompts.first!` на пустом массиве — `Services/AIEnhancement/AIEnhancementService.swift:220` — при пустом списке промптов (например после `deletePrompt`) `?? allPrompts.first!` крашит. Использовать безопасный fallback на дефолтный текст.
- [x] **[high]** Условная регистрация observer, безусловное удаление — `PowerMode/PowerModeSessionManager.swift:73` — observer регистрируется только при `loadSession() == nil`, а удаляется всегда; повторный `beginSession()` оставляет сессию без наблюдателя `AppSettingsDidChange`. Регистрировать observer для каждой сессии (или сделать идемпотентным).
- [x] **[high]** Сопоставление URL через `contains()` вместо домена — `PowerMode/PowerModeConfig.swift:251` — `cleanedURL.contains(configURL)` ошибочно матчит `myexample.com` с правилом `example.com`. Сравнивать по границам домена.
- [x] **[high]** Состояние не обновляется в Carbon hot key — `Shortcuts/ShortcutMonitor.swift:270-297` — при ненулевом `onShortcutPressed` ранний return не выставляет `isDown = true`, поэтому release-событие глушится `guard state.isDown`. Выставлять `isDown` до раннего return.
- [x] **[high]** Свойства @MainActor читаются из global event monitor — `Shortcuts/RecordingShortcutManager.swift:66` — `middleClickMonitors`/`middleClickTask` доступны из замыканий `addGlobalMonitorForEvents` на произвольных потоках — гонка данных. Бриджить доступ через `MainActor.run` / `Task @MainActor`.
- [x] **[high]** CGEvent может вернуть nil, тихий сбой авто-отправки — `Paste/CursorPaster.swift:223-224` — `enterDown/enterUp` создаются без guard; при неудаче создания нажатие Enter молча не отправляется. Добавить `guard let` с логированием, как в `pasteFromClipboard`.
- [x] **[high]** Force-cast Optional → `WhisperModel` — `Views/Onboarding/OnboardingModelDownloadView.swift:13` — `... .first { ... } as! WhisperModel` падает при инициализации, если модель не найдена/иного типа. Использовать `as?` с безопасной обработкой nil.
- [x] **[high]** Force-индекс `[0]` на результате `FileManager.urls` — `Transcription/Engine/VoiceInkEngine.swift:45` — пустой массив директорий крашит инициализацию движка. Использовать `.first` с проверкой.
- [x] **[high]** Нет removeObserver в VoiceInkEngine — `Transcription/Engine/VoiceInkEngine.swift:456-468` — два observer регистрируются, но нет `deinit`/`removeObserver`; срабатывание уведомления на деаллоцированном объекте крашит. Добавить `deinit` с удалением наблюдателей.
- [x] **[high]** Ошибка `modelContext.save()` проглатывается `try?` — `Transcription/Engine/VoiceInkEngine.swift:108` — при сбое сохранения транскрипция не персистится, но уведомление об успехе всё равно постится (потеря данных). Использовать do/catch с логированием (аналогично есть на строке 252).
- [x] **[high]** `shouldCancelRecording` не сбрасывается в пути отмены — `Transcription/Engine/VoiceInkEngine.swift:313-317` — в `.transcribing/.enhancing` флаг остаётся `true`, и новая запись может быть прервана stale-значением через guard на строке 157. Сбрасывать `shouldCancelRecording = false`.

## Medium

- [x] **[medium]** Fire-and-forget Task для disconnect провайдера — `Transcription/Streaming/StreamingTranscriptionService.swift:212-214` — Task с `disconnect()` не сохраняется и не ожидается; при завершении приложения cleanup может не доработать. Хранить/ожидать задачу или вызывать через `cleanupStreaming()`.
- [x] **[medium]** Лишний `DispatchQueue.main.async` в @MainActor-классе — `Services/ScreenCaptureService.swift:37` — в `defer` `isCapturing` сбрасывается через GCD вместо `MainActor.run`, смешивая модели конкурентности. Использовать `MainActor.run`.
- [x] **[medium]** Пустой очищенный URL добавляется в конфиг — `PowerMode/PowerModeConfigView.swift:615` — guard проверяет ввод, но не результат `cleanURL()`, поэтому `"www."`/пробелы дают пустую запись в `websiteConfigs`. Валидировать `cleanedURL` на пустоту.
- [x] **[medium]** `isValidating` не сбрасывается при пустом ключе — `Models/LicenseViewModel.swift:96-101` — ранний return не сбрасывает флаг, UI может зависнуть в состоянии загрузки. Выставить `isValidating = false` перед return.
- [x] **[medium]** Отменённая транскрипция сохраняет powerMode-поля — `Models/Transcription.swift:64-83` — `markAsCanceledTranscription()` не очищает `powerModeName`/`powerModeEmoji`, и UI показывает Power Mode у отменённой записи. Обнулить оба поля.
- [x] **[medium]** Редундантный `max()` с одинаковыми аргументами — `Notifications/AnnouncementManager.swift:83` — `max(a, a)` — no-op, логика учёта высоты панели не выполняется. Реализовать корректное сравнение высоты панели с фреймом.
- [x] **[medium]** Нет deinit/removeObserver в SoundManager — `SoundManager.swift:14-19` — singleton добавляет observer в `init()` и никогда не удаляет; станет багом при отказе от singleton. Добавить `deinit` с `removeObserver`.
- [x] **[medium]** Пустой словарь языков молча возвращает `'en'` — `Models/LanguageDictionary.swift:48-50` — `validLanguageOrFallback()` маскирует конфигурацию модели без поддерживаемых языков. Добавить assert/warning в debug при пустом словаре.

## Low

- [x] **[low]** Несогласованная обработка `setString` в ClipboardManager — `Paste/ClipboardManager.swift:23` — возврат `setString` для bundle id игнорируется, а для sessionID проверяется. Согласовать обработку либо задокументировать намеренность.
- [x] **[low]** Состояние не сбрасывается / нет отмены таймера — `Views/Common/CopyIconButton.swift:20-26` — повторные клики плодят множественные `asyncAfter`-блоки сброса `copied`. Хранить таймер и инвалидировать перед новым запуском.
