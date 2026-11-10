# upstream-scout: anomalyco/hex

Проверено до: `3e69978` · 2026-11-10
История: `3e69978` (2026-11-10) — первый проход

Hex — локальная диктовка для macOS/Windows/Linux, Rust (~357k строк), MIT. Общей истории и общего
языка с форком нет: переносить можно только идеи. Инвентарь собран по `docs/features/*.md`, по
находкам ниже код Hex прочитан выборочно (`src/paste/return_to_app.rs`,
`src/dictation/spoken_*.rs`, `src/transcription/model_benchmarks.rs`). Замера у находок нет.

## Находки

| # | Фича | Что даёт | Польза | Порт | Связность | Куда ляжет |
|---|------|----------|:---:|:---:|---|---|
| 1 | **Return to app** (Labs, `src/paste/return_to_app.rs`) | Вставка идёт в приложение, где началась запись. Если за время диктовки вылезло другое окно, Hex активирует исходное, ждёт до 500 мс; не дождался — не вставляет, текст доступен через Paste last. В форке вставка уходит в то, что впереди в момент вставки (`Paste/CursorPaster.swift:125`), исходное приложение не запоминается | 3 | S (~100) | низкая | `Transcription/Engine/TranscriptionPipeline.swift` (pid на старте записи), `Paste/CursorPaster.swift` |
| 2 | **Хвост после отпускания** (`src/recognition.rs`, finish_dictation) | Запись длится 200 мс после отпускания клавиши и до 600 мс, пока идёт речь: последнее слово не обрезается. В форке остановка сразу (`Recorder.swift:189`). Обрезка в форке — гипотеза, не замерял | 3 | S | низкая | `Recorder.swift`, `Shortcuts/RecordingShortcutManager.swift` |
| 3 | **Отсев тишины до распознавания** (`src/dictation.rs`, `src/transcription/speech_detector.rs`) | Запись, у которой самый громкий отрезок 30 мс тише −50 dBFS, выбрасывается без инференса; Silero (порог 0.4, ≥160 мс речи) отсеивает громкий не-голос. Случайное нажатие не вставляет мусор. В форке проверки перед пакетным распознаванием нет; Silero уже есть для Whisper (`Transcription/Whisper/VADModelManager.swift`) | 2 | S (dBFS) / M (Silero) | низкая | `Transcription/Engine/TranscriptionPipeline.swift` |
| 4 | **Определение звонка → предложение записать встречу** (`src/meeting/detection.rs`, `src/microphone_activity.rs`) | Кто держит микрофон (Zoom, Meet, Telegram…) → капсула «Записать?», правило Ask/Always/Never по сервису; Labs: стоп через 30 с после конца звонка. В форке встречи запускаются только руками, детекта нет | 3, если встречи в ходу | M–L | средняя — `Meetings/` форка | `Meetings/MeetingRecorder.swift`, новый наблюдатель Core Audio по процессам |
| 5 | **Тёплый микрофон с pre-roll 450 мс** (`src/dictation/audio.rs`) | Первые слоги не теряются на старте. Цена — индикатор микрофона macOS горит постоянно. Форк создаёт AUHAL на каждый старт (`CoreAudioRecorder.swift:103`) | 2 | M | средняя | `CoreAudioRecorder.swift`, `Recorder.swift` |
| 6 | **Голосовое форматирование** (Labs, `src/dictation/spoken_formatting.rs`, `spoken_symbols.rs`) | «new line», «new paragraph», «open quote», «comma», «underscore» → символы. Только английский и испанский: для русского («новая строка», «новый абзац», «открыть кавычки») список писать самому, взять можно лишь схему склейки с соседями | 2 | S | низкая | `Transcription/Processing/TranscriptionOutputFilter.swift` |

## Решения

- **Взято (2026-11-10, версия 1.84.0, план `docs/superpowers/plans/2026-11-10-hex-port.md`):**
  #1 Return to app (`d65a1d83`, выключено по умолчанию, тумблер в «Экспериментальных»), #2 хвост
  после отпускания (`599a368a`), #3 отсев тишины, только порог dBFS, без Silero (`10895a9c`;
  фикс `67968253`: ExtAudioFile пишет чанк `FLLR`, данные WAV начинаются с байта 4096, а не 44).
  Попутно «вставить/скопировать последнюю» пропускают неудачные и отменённые записи (`6fe0e195`).
  - Руками не проверено: активация исходного приложения из фона на macOS 27 (#1), замер обрезки
    последнего слова на 10 диктовках (#2). Если обрезка меньше чем в 3 из 10, откатить `599a368a`.
- **Отклонено:**
  - GigaAM v3 (рекомендован Hex для ru): его же прогон FLEURS ru даёт 5,37 % WER против 6,52 % у
    Parakeet v3; Ultra по FluidAudio на 1,3 п.п. лучше v3, то есть ≈5,2 % (харнессы разные, это
    оценка). Выигрыша нет, а нужен рантайм GGUF/transcribe.cpp, которого в форке нет.
  - Удаление слов-паразитов: только английские um/uh, в форке свой `FillerWordManager`.
  - Фильтр титров (`subtitle_credits.rs`): ловит галлюцинации Whisper, пользователь на Parakeet.
  - `hex mcp` над встречами: встречи форка лежат файлами (`Meetings/MeetingStore.swift`,
    `summary.md`), Claude Code читает их и без MCP.
  - Personal commands на QuickJS, OpenCode rewrite: у форка есть Local CLI и PowerMode.
  - Переключение модели по раскладке: в форке одна мультиязычная модель, язык берётся из раскладки
    (`Services/KeyboardLayoutLanguageService.swift`).
  - Control CLI и локальный HTTP API: в форке есть AppIntents, потребности не заявлено.
  - Caps Lock dictation, chord breaker: Caps Lock и одиночные модификаторы уже заняты
    переключателем раскладки форка.
  - Annotate, Screenshots, Voice Filter, HUD, Linux/Windows: вне задачи форка.
- **Уже есть в форке:** режимы шортката (hold/toggle/hybrid/double tap), восстановление буфера,
  Paste last, режимы по приложению и сайту (PowerMode), mute/pause media, переподнятие event tap,
  встречи с саммари.

## Обратные пробелы

Есть у форка и нет у Hex: Auto Learn словаря, переключатель раскладки, re-transcribe в языке
раскладки, улучшение выделенного текста, Paste in chunks, Quick History.
