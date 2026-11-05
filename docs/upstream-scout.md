# upstream-scout: Beingpax/VoiceInk

Проверено до: 5c95ff97 · 2026-11-04
История: v2.0 (2026-07-16) → v2.1 (2026-07-27) → v2.11 (2026-08-12) → v2.13 (2026-08-27) → `8f089cb` (2026-09-03) → v2.20 (2026-09-19) → `d7b528aa` (2026-09-22) → v2.22 (2026-10-01) → `5c95ff97` (v2.25 + 2 коммита, 2026-11-04)

Раскладка исходников апстрима (`16b61ac`, 2026-08-31, `Services/*` → `Infrastructure/*`,
`Views/*` → `Features/<Feature>/Views/*`) по-прежнему расходится с форком: портировать руками по
содержимому, не cherry-pick.

## Находки (проход 2026-11-05)

62 коммита после `c09cc1f6`, релиз v2.25. Сверено с форком и настройками пользователя: Parakeet Ultra,
ru, встроенный одноканальный микрофон, улучшение через Local CLI. Подошло 2 находки, замера нет ни у
одной: в логах за 14 дней нашлось лишь 2 старта записи, частоту сбоев по ним не посчитать.

| # | Фича | Что даёт | Польза | Порт | Связность | Куда ляжет |
|---|------|----------|:---:|:---:|---|---|
| 1 | **Понятная ошибка зависшего coreaudiod** (`bfbb9fc5`, `bdbc7742`) | `AudioOutputUnitStart` с `kAudioHardwareNotRunningError` даёт сообщение и кнопку «Restart Audio» (`killall coreaudiod` с паролем администратора). В форке статус теряется: `Recorder.swift:156` сводит всё к `couldNotStartRecording` | 3 | S (~50) | низкая | `VoiceInk/Recorder.swift`, `VoiceInk/CoreAudioRecorder.swift`, показ ошибки записи |
| 2 | **Direct Typing** (`62ca0e72`, пейсинг из `f648d27c`) | Метод вставки без буфера обмена: текст идёт Unicode-событиями клавиатуры. Конкретных приложений апстрим не называет, в RDP Unicode-ввод не работает (PR #758). В форке буфер и так восстанавливается, поэтому не брать. Ядро есть (`LayoutSwitcher/DirectTyper.swift`, `typeUnicode` приватный) | 1 | S | низкая — ветка в `CursorPaster` рядом с chunks и Auto Learn | `Paste/PasteMethod.swift`, `Paste/CursorPaster.swift`, настройки, бэкап |

Не подходит форку:

- Smart Punctuation (`ffb65bd2`): `SmartPunctuation.adjusted` возвращает текст как есть, если в нём
  или вокруг курсора есть не-ASCII буквы. На русском не работает.
- Автокоррекция по словарю (`e43058fb`): `VocabularyPhonetics` и `PhoneticVocabularyMatcher` берут
  только a–z. Кириллические термины отбрасываются, сам код заявлен как English-oriented.
- Локальный ревьюер Auto Learn (`0a7d1d99`, `416c227f`): служебные слова и формы только английские.
  Предложение «Learn this correction?» с подтверждением связано с этой переделкой.
- Починка после удаления слов-паразитов (`9b2dd5a0`): список пользователя целиком английский. Кроме
  того, `\b` апстрима режет «ну-ка», форк это уже обходит (`TranscriptionOutputFilter.swift:82`).
- Пустые записи после смены формата (`f52a4c33`, `5628765e`): баг кэша подготовленного AUHAL. Форк
  создаёт AUHAL на каждый старт (`CoreAudioRecorder.swift:103`), кэша нет.
- Выбор канала на устройстве (`005a6574`): у пользователя один канал входа.
- Очередь вставок и восстановление буфера (`3db8ad12`, `e757df7e`): в форке уже есть
  (`queuedPasteSession`, `inFlightUserClipboard`, `a2349e86`).
- Триггеры сайтов (`298025c1`): форк уже сравнивает точно или по префиксу. Разница только в поддоменах.
- Per-mode Auto Send (`9090f25c`): в форке есть.

Открыто, без симптома у пользователя:

- Восстановление шорткатов (`f648d27c`, `6297f741`, ~1,8k строк): отдельный поток для event tap и
  поиск пропущенного отпускания. Форк при отключении tap сбрасывает нажатия и шлёт key-up
  (`ShortcutMonitor.swift:166`, `:451`), но tap живёт на main run loop.
- Свой захват выделения вместо SelectedTextKit (`def80de8`, `c1cf6ae2`, `fefc558e`): запасной шорткат
  копирования. В форке только AX и пункт меню (`SelectedTextService.swift:9`).
- ZIPFoundation с защитой распаковки (`98f410ea`, `9b61467e`): касается только Core ML для Whisper.

Пропущено: Remote Desktop Typing (нужен только при работе по RDP), Voxtral 3, Soniox V6, Mistral
Large 4, Claude Sonnet 5.5 и Haiku 5.5 (пользователь на Parakeet Ultra и Local CLI, цифр по русскому
нет), японская локализация, `ba58dab9` (прогрев Unified-модели, не разбирал: у пользователя
`parakeet-ultra`), диагностика режимов (`be9ae87d`), обвязка обновлений Sparkle.

## Находки (проход 2026-10-03)

21 коммит после `d7b528aa`, релизы v2.21 и v2.22 (диагностическая сборка под зависания Parakeet).
Поведение — 7 находок, крупных фич нет. Большая часть пунктов release notes v2.21 (double tap,
Auto Send, дублирование режимов, local CLI в Auto Learn, custom model IDs, OpenRouter-транскрипция)
вошла в прошлый проход до `d7b528aa`. Остальное — обвязка: редизайн Insights и удаление графика
продуктивности, объединение UI History/Quick History, пропуск онбординга, диагностические логи
(`e8f4dd0c`, `c09cc1f6`), `ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES` (`0206b606`), дефолты моделей
улучшения (`ba16d143`), appcast.

| # | Фича | Что даёт | Польза | Порт | Связность | Куда ляжет |
|---|------|----------|:---:|:---:|---|---|
| 1 | **Текст ошибки улучшения не выдаётся за результат** (`44d3013a`) | Апстрим фильтрует `enhancedText` с префиксом «Enhancement failed:» в истории. В форке тот же класс бага шире: `TranscriptionPipeline.swift:163` и `AudioFileTranscriptionManager.swift:208` пишут ошибку в `enhancedText`, после чего ↵ в Quick History (`QuickHistoryController.swift:118` → `preferredHistoryText`), «скопировать последнюю» (`LastTranscriptionService.swift:34`) и «вставить последнее улучшение» (`:89`) отдают в чужое приложение строку «Enhancement failed: …» вместо транскрипта | 3 | S | низкая | чинить у себя в корне (не хранить ошибку в `enhancedText` или один фильтр в общем аксессоре), префикс-фильтр апстрима не копировать |
| 2 | **Возобновление медиа после записи** (`af772a81`) | Владение паузой по сессии записи: вторая запись, начатая до возобновления, не теряет «мы поставили на паузу»; перед play ждёт до 2 с, пока адаптер пришлёт событие паузы, и перечитывает живое состояние. В форке `PlaybackController.pauseMedia()` отменяет ожидающий `resumeTask` и сбрасывает `wasPlayingWhenRecordingStarted` — музыка остаётся на паузе, но только при `audioResumptionDelay` > 0 (дефолт 0). Второй сценарий (короткая запись, событие паузы ещё не пришло → resume пропущен) — гипотеза, не воспроизводил. Mute-часть коммита форк уже закрывает (`mutedDeviceID`, `muteGeneration`) | 2 | M (~190) | низкая | `VoiceInk/PlaybackController.swift`, `VoiceInk/Recorder.swift` |
| 3 | **Parakeet Ultra** (`593fadbe`, `7fdc5c39`) | Parakeet V3, дообученный Moondream, 640 МБ, мультиязычный | 2 | S + bump FluidAudio `50aa0719` → `762baf67` (`AsrModelVersion.ultra`) | низкая | `Transcription/FluidAudio/FluidAudioModelManager.swift`, реестр моделей. Брать только с замером на русском против текущей модели |
| 4 | **VAD для FluidAudio везде** (`6985c4b5`) | VAD на любой длине батча и в стриминге (сегменты со смещением таймстампов). В форке VAD только в батче от 20 с (`FluidAudioTranscriptionService.swift:131`) | 1 | M | средняя — стриминг форка | `Transcription/FluidAudio/`, `Transcription/Streaming/FluidAudioStreamingProvider.swift` |
| 5 | **AssemblyAI Universal 3.6 Pro, ElevenLabs Scribe V2 Medical** (`4798ce0e`, `f657a783`) | Новые облачные модели | 1 | S | bump LLMkit `bbfbf5c4` → `37100b22` — вместе с #5/#8 прошлого прохода | `Transcription/Cloud/AssemblyAIProvider.swift`, `ElevenLabsProvider.swift` |
| 6 | **Свои звуки записи на полной громкости** (`880502b3`) | `volume: 1.0` вместо 0.3 (в форке 0.4) | 1 | S (1 строка) | нет | `VoiceInk/SoundPlaybackEngine.swift:64-65` |
| 7 | **Слияние правил замены с одной целью** (`d217463a`) | «a → X» и «b → X» сводятся в одну строку «a, b → X» при старте и импорте; удаление одного источника из пилюли | 1 | M | низкая | `Services/Dictionary*`, `Views/Dictionary/` |

Не нужно: case-only циклы (`82bbaede`) и local CLI в Auto Learn (`57c12c9a`) — в форке уже есть;
Return-to-send после custom command (`d4d718bc`) — в форке нет доставки через команду.

## Находки (проход 2026-09-23)

| # | Фича | Что даёт | Польза | Порт | Связность | Куда ляжет |
|---|------|----------|:---:|:---:|---|---|
| 1 | **Dictionary Auto Learn** (v2.20) | После вставки 60 с читает поле через AX; правки пользователя диффом превращаются в кандидатов «было → стало», LLM отбирает фонетические исправления и пишет их в словарь (замена и/или vocabulary). По умолчанию включено и применяется сразу, без подтверждения | 4 | L (~4.6k строк) | средняя — хук в `CursorPaster`, новый метод в `AIService`, `WordReplacementVariants`; AX-чтение и очередь автономны | новая `VoiceInk/Services/AutoLearn/`, `Paste/CursorPaster.swift`, `Services/AIEnhancement/AIService.swift`, `Views/Dictionary/` |
| 2 | **Импорт/экспорт словаря** (v2.20) | JSON `voiceink.dictionary` v1: vocabulary + replacements; превью с дублями, конфликтами и циклами; режимы merge/replace | 3 | M (~930) | низкая — те же SwiftData-модели `VocabularyWord`/`WordReplacement`, что в форке | новые `Services/Dictionary{Archive,ImportExportService}.swift`, `Views/Dictionary/DictionarySettingsPanel.swift` |
| 3 | **Quick History** (v2.20) | Плавающая `NSPanel` 680×470 с поиском по 30 последним транскрипциям; ↵ вставляет в предыдущее приложение, ⌘↵ — детали (перезапуск с другим режимом/промптом, аудио в Finder). Глобальный хоткей настраивается, по умолчанию не задан | 3 | M (~1.5k) | низкая для списка и вставки; средняя для действий в деталях (Modes апстрима ≈ PowerMode форка) | `Views/History/`, `Shortcuts/ShortcutAction.swift`, `Shortcuts/RecordingShortcutManager.swift`, меню-бар |
| 4 | **Шорткаты не работают на заблокированном экране** (`8d66da18`) | `CGSessionCopyCurrentDictionary` → `CGSSessionScreenIsLocked`: пока сессия заблокирована, монитор шорткатов молчит — запись не стартует с экрана блокировки | 3 | S (~55) | низкая | `Shortcuts/ShortcutMonitor.swift` + новый `Services/UserSessionInputPolicy.swift` |
| 5 | **Deepgram: отказ от обучения на данных** (LLMkit `f35a17ad`) | `mip_opt_out=true` в пакетных и стриминговых запросах Deepgram | 2 | S | низкая, но только через bump LLMkit `bbfbf5c4` → `f35a17ad`, а он тянет новые Gemini/OpenRouter-клиенты — проверить компиляцию | `Package.resolved`, `project.pbxproj` |
| 6 | **Double tap — режим шортката записи** (`b593e10a`, `173d1eb7`) | Двойное нажатие модификатора включает/выключает запись | 2 | S (~80) | средняя — стек шорткатов форка разошёлся | `Shortcuts/RecordingShortcutManager.swift` |
| 7 | **Word agreement: пунктуация** (`e72fad54`) | Стриминг FluidAudio: смена точки/вопроса больше не замораживает и не сбрасывает подтверждённые слова | 2 | S (~30) | низкая | `Transcription/Streaming/WordAgreementEngine.swift` |
| 8 | **Grok Voice Transcribe 2.0 + custom vocabulary** (`f948f4ae`) | Новая модель xAI и передача словаря в запрос | 2 | S | низкая, но нужен bump LLMkit (параметр `customVocabulary`) | `Transcription/Cloud/XAIProvider.swift`, `Transcription/Streaming/XAIStreamingProvider.swift` |
| 9 | **Отмена загрузки моделей** (`0a4eb723`, `d34e702c`) | Кнопка отмены, удаление недокачанного, убрана анимация прогресса | 1 | S | низкая | `Transcription/Whisper/WhisperModelManager.swift` и карточки моделей |

## Решения

- **Взято (2026-11-05):** #1 coreaudiod, версия 1.83.1. Показ через уведомление форка на 15 с, потому что
  `AudioInputFailurePresentation` апстрима в форке нет. Остальное из прохода пропущено. Прошлый #2
  (возобновление медиа) пользователя не касается: `isPauseMediaEnabled` выключен.
- **Взято (2026-10-03):** #1 — фикс в корне форка (`f2cc27b4`, аксессор
  `Transcription.successfulEnhancedText`). #3 Parakeet Ultra (`d634d6d7`, FluidAudio → `762baf67`)
  — по замеру FluidAudio (FLEURS ru −1,3 п.п. WER, `Documentation/ASR/ParakeetUltra.md`), первая в
  рекомендуемых, V3 оставлена запасной; VAD-файлы из `7fdc5c39` не нужны — VAD форка качается сам.
- **Открыто:** #2, #4–#7. #5 — вместе с bump LLMkit.
- **Взято (2026-09-24, план `docs/superpowers/plans/2026-09-23-upstream-v2.20-port.md`):**
  #1 Auto Learn (`1045870c` + фиксы `8b0cd3c2`, `38fd9caf`, `8ef9d9d8`), #2 импорт/экспорт словаря
  (`7a308543`, `0ab2c43b`), #3 Quick History (`67f1e89c`, `b1c73c1b`), #4 блокировка экрана
  (`c8848553`), #6 double tap (`ca9420ca`, `99223fb2`), #7 word agreement (`fe6c32f9`), #9 отмена
  загрузки (`94a700b8`, `a9f649ba`).
  - Отступления от апстрима:
    - Auto Learn без явного выбора берёт только провайдер улучшения, который один раз запоминается
      при запуске. Запасного «первый провайдер с ключом» нет.
    - Ревью закрывает наблюдение до замены текста при re-transcribe и при улучшении выделенного
      текста.
    - Таймаут ревью не меньше 30 с.
    - Правила, меняющие только регистр (github → GitHub), не считаются циклом.
  - Не перенесено:
    - режимы и перезапуск в деталях Quick History (вместо них «Re-enhance»);
    - дизайн-система апстрима.
  - Известно, не правилось: зажатый push-to-talk в момент блокировки экрана продолжает запись до
    следующего нажатия после разблокировки. Апстрим ведёт себя так же; отпускание на экране
    блокировки вставило бы текст в поле пароля.
- **Рекомендую следующим:** #5 и #8 — оба упираются в bump LLMkit.
- **Не нужно:** шорткаты мыши (`22431293`) — в форке свои (`afa46271`). Auto Send глобально
  (`ac4b13e8`) — в форке есть per-PowerMode. Gemini 3.8 / Qwen 3.8 — обновление списка моделей.
- **Отклонено:** французская локализация, дашборд-календарь (`4c8a4b8e`), changelog-окно,
  дублирование режимов (`0da59d1f`), Comet-браузер (`d7b528aa`), OpenRouter-транскрипция
  (`19f27f65`) и custom model IDs (`7929145d`) — не используется в форке.
- **Прошлые проходы (2026-09-06):** порт не запускался; transcribe.cpp (SenseVoice/Cohere),
  clamshell mic routing, Gemini 3.5 Transcribe — открыты, брать только с замером против
  текущей модели. VoiceInk Refine — отложено (XPC + MLX-стек). Star prompt, release-пайплайн,
  Sparkle с дашборда — отклонено.

## Найдено в форке по ходу прохода

- Ручной триггер переключателя раскладки на одиночном модификаторе (Right Option) срабатывает и
  на отпускании после сочетания (⌥⇧- для «—», ⌥←): `RecordingShortcutManager.swift:229-239`
  помечает прерывание только для шорткатов записи, а отпускание в `ShortcutMonitor` его не
  проверяет. Апстрим закрыл тот же класс бага для toggle-записи в `ee6cf208`.

## Расхождение зависимостей

| Пакет | Апстрим | Форк |
|---|---|---|
| llmkit | `37100b22` (Deepgram opt-out, Gemini/OpenRouter клиенты, Universal 3.6 Pro) | `bbfbf5c4` |
| fluidaudio | `762baf67` | `762baf67` (с 2026-10-03) |
| transcribe-cpp-swift | есть | нет |
| mlx-swift / mlx-swift-lm / swift-transformers / swift-huggingface / swift-jinja | есть | нет |
| launchatlogin-modern | нет (свой `LaunchAtLoginManager.swift`) | есть |

## Обратные пробелы

Что есть у форка и чего нет у апстрима — при портировании не затереть:

- Переключатель раскладки (`VoiceInk/LayoutSwitcher/`, шорткат `convertLayout`) — при порте
  #3/#6 не потерять его запись в `ShortcutAction`/`ShortcutValidator`/`BackupTypes`, а при
  порте #4 — отсечку `KeystrokeTap.flushMarker` в `ShortcutMonitor`.
- Русская локализация и `InterfaceLanguage` с авто-relaunch.
- Re-transcribe последней записи в языке текущей раскладки.
- Paste in chunks, emotion annotation — хук Auto Learn стоит в пути вставки форка (один вызов на
  весь текст после всех чанков); `CursorPaster` апстрима не переносить.
- Всё, что вставляет поверх уже вставленного (re-transcribe, улучшение выделенного текста), сначала
  закрывает наблюдение Auto Learn через `recordingDidStart()`.
- WPM-карточка и Keystrokes-Saved на метриках.
- `launchatlogin-modern` вместо самописного менеджера автозапуска.
- Тесты словаря на комбинирующие диакритики и тесты переключателя раскладки (`VoiceInkTests`).
