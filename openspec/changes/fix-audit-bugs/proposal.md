## Why

Сабагентный аудит кода ([CODE_AUDIT.md](../../../CODE_AUDIT.md)) нашёл 28 подтверждённых дефектов: краши на force-unwrap, гонки данных на `@MainActor`-полях, проглоченные ошибки сохранения (потеря данных), утечки observer'ов и stale-state в путях отмены. Часть из них — пользовательские краши и тихая потеря транскрипций, поэтому их нужно устранить до следующего релиза.

## What Changes

- Устранение всех крашей на принудительном развёртывании: `!`, `as!`, `try!`, индекс `[0]`/`.first!` без guard (6 находок).
- Исправление concurrency-дефектов: доступ к `@Published`/`@MainActor`-полям вне MainActor и гонки данных в общих изменяемых полях (6 находок).
- Корректная пропагация ошибок: `try? save()` → do/catch (потеря данных), `fatalError` в recoverable-путях → throw (2 находки + 1 краш-путь).
- Устранение утечек памяти: добавление `deinit`/`removeObserver` там, где наблюдатели не снимаются (4 находки).
- Очистка stale-state: сброс флагов отмены и полей PowerMode/таймеров в путях отмены и повторного входа (3 находки).
- Исправление логических ошибок: URL-матч по границе домена вместо `contains()`, no-op `max(a,a)`, пустые записи в конфиге, ранние return без сброса флагов (5 находок).
- **Non-goal**: рефакторинг архитектуры, новые фичи, изменение публичного поведения сверх исправления дефектов.

## Capabilities

### New Capabilities
- `code-correctness`: Требования корректности кодовой базы — отсутствие крашей на принудительном развёртывании, корректная изоляция конкурентности, гарантированная пропагация ошибок, освобождение ресурсов и наблюдателей, согласованность состояния в путях отмены.

### Modified Capabilities
<!-- В openspec/specs/ нет существующих spec-файлов — модифицировать нечего. -->

## Impact

Затронутые файлы (по аудиту):

- **Transcription/Engine**: `VoiceInkEngine.swift` (строки 45, 108, 313-317, 456-468), `AudioFileProcessor.swift:170`
- **Transcription/Streaming**: `StreamingTranscriptionService.swift` (225-231, 212-214)
- **Transcription/FluidAudio**: `FluidAudioTranscriptionService.swift` (46-79)
- **Services**: `AudioFileTranscriptionService.swift` (79, 191), `AIEnhancement/AIEnhancementService.swift:220`, `ScreenCaptureService.swift:37`
- **PowerMode**: `PowerModeSessionManager.swift:73`, `PowerModeConfig.swift:251`, `PowerModeConfigView.swift:615`
- **Shortcuts**: `ShortcutMonitor.swift` (270-297), `RecordingShortcutManager.swift:66`
- **Paste**: `CursorPaster.swift` (223-224), `ClipboardManager.swift:23`
- **Models**: `Transcription.swift` (64-83), `LicenseViewModel.swift` (96-101), `LanguageDictionary.swift` (48-50)
- **Views**: `Onboarding/OnboardingPermissionsView.swift` (330, 351), `Onboarding/OnboardingModelDownloadView.swift:13`, `Common/CopyIconButton.swift` (20-26)
- **Notifications**: `AnnouncementManager.swift:83`
- **Root**: `SoundManager.swift` (14-19)

Зависимости/API не меняются. Риск регрессии низкий — изменения локальные и точечные.
