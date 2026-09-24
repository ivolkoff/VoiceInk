# upstream-scout: Beingpax/VoiceInk

Проверено до: `d7b528aa` (upstream/main, 2026-09-22, после v2.20) · 2026-09-23
История: v2.0 (2026-07-16) → v2.1 (2026-07-27) → v2.11 (2026-08-12) → v2.13 (2026-08-27) → `8f089cb` (2026-09-03) → v2.20 (2026-09-19) → `d7b528aa` (2026-09-22)

Проход 2026-09-23: 95 коммитов после `8f089cb`. Поведение — 9 находок, из них три крупные фичи
v2.20. Остальное — обвязка: французская локализация (`Localizable.xcstrings` +14791/-3786),
changelog-окно, дашборд-календарь активности, рефакторинги UI, релизные коммиты.

Раскладка исходников апстрима (`16b61ac`, 2026-08-31, `Services/*` → `Infrastructure/*`,
`Views/*` → `Features/<Feature>/Views/*`) по-прежнему расходится с форком: портировать руками по
содержимому, не cherry-pick.

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
    - настройки Auto Learn в бэкапе;
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
| llmkit | `f35a17ad` (Deepgram opt-out, Gemini/OpenRouter клиенты) | `bbfbf5c4` |
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
