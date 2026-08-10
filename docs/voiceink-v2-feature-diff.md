# VoiceInk 2.0 (upstream Beingpax) — диф новых фич vs текущий форк

Дата: 2026-07-18
Сравнение: форк `~/WebDev/VoiceInk` (branch `main`) ↔ upstream `~/WebDev/VoiceInkBeingpax` (tag «Release VoiceInk 2.0», commit `69ed170`).

Цель: фичи, которые есть в v2 и отсутствуют в форке, с оценкой полезности (1–5) и сложности порта (S/M/L). Метод — параллельный анализ по подсистемам (Modes, Dashboard, AI-Assistant, misc services), каждая находка сверена с исходником форка на предмет реального отсутствия.

## Ключевой архитектурный нюанс

Значительная часть «вкусных» фич v2 висит на новом движке v2: `VoiceInkEngine` + `TranscriptionPipeline` + `TranscriptionDelivery`. Форк этого слоя не имеет. Поэтому у движко-связанных фич «port L» фактически означает «тащить кусок движка v2» — высокий риск. Чисто-портируемые фичи (читают только `SessionMetric` / `UserDefaults` / собственный UI) выделены как ✅ низкая связность.

---

## Tier A — супер-полезное

| # | Фича | Что даёт юзеру | Польза | Сложность | Связность с движком |
|---|------|----------------|:---:|:---:|---|
| 1 | **Custom Command output mode** | Режим гонит транскрипт в произвольную shell-команду (`/bin/zsh -lc`, `$VOICEINK_TRANSCRIPT`/stdin, timeout + process-tree kill) вместо вставки — paste+Tab, append в журнал, web search, что угодно | **5** | L | ⚠️ высокая (delivery) + entitlements/sandbox (спавнит произвольный shell) |
| 2 | **Trigger-word голосовое переключение режимов** | Говоришь ключевое слово (в начале/конце) → авто-switch на нужный режим, слово вырезается из транскрипта. Longest-word-wins matching | **4** | M | ⚠️ хук в pipeline (`VoiceInkEngine`, `triggerWordModeSelection`) |
| 3 | **Trigger template catalog + trigger groups** | Один тап добавляет курированные бандлы app+website (AI/Email/Messaging/Writing, сотни bundle ID) в auto-switch режима — без ручного вылавливания bundle ID; picker popover с матчингом установленных приложений | **4** | M | ✅ низкая (config + UI) |
| 4 | **CustomAIProviderManager (мульти-провайдеры)** | Несколько произвольных OpenAI-совместимых AI-эндпоинтов (`{name, baseURL, models[], selectedModel}` + ключ в keychain). Сейчас в форке **один** слот. Есть миграция со старых ключей форка | **4** | M | ✅ низкая, self-contained (UserDefaults + APIKeyManager + `.custom` case + UI) |
| 5 | **CustomModelConnectionTester** | Кнопка «Test connection» для кастомных cloud-моделей: транскрипция шлёт 1KB junk WAV, трактует коды 200/400/415/422 как успех, 401/403 = ключ, 404 = эндпоинт; enhancement через `verifyAPIKey`; форсит HTTPS (HTTP только localhost) | **4** | S | ✅ низкая |
| 6 | **FluidAudio Nemotron + Unified streaming** | Два новых **локальных** streaming-ASR бэкенда: `StreamingNemotronMultilingualAsrManager` (Nvidia Nemotron multilingual) и `StreamingUnifiedAsrManager` (Parakeet unified) + `PCMAudioConverter` | **4** | M–L | ⚠️ упирается в версию FluidAudio SDK (нужны эти manager-классы) |
| 7 | **Dashboard: Insights + Productivity chart + Peak hours** | Селектор периода (Today/7d/30d/Year/All-Time), линейный график слов во времени с непрерывным hover-tooltip (слова + ±% дельта к предыдущей точке, цветная), 24-барная гистограмма пиковых часов с подсветкой busiest 2h-окна | **4** | M–L | ✅ низкая (только `SessionMetric`, полный скан → кэш на диск) |

---

## Tier B — полезное, но нишевое/инкрементальное

| # | Фича | Что даёт | Польза | Сложность | Связность |
|---|------|----------|:---:|:---:|---|
| 8 | **Respond/Assistant output mode + chat в рекордере** | Мини голосовой ChatGPT в notch (панель 320px): ответ LLM остаётся в рекордере как чат-бабл, follow-up голосом (повторная запись) или текстом, вся история пересылается каждый ход, каждый ход сохраняется как `Transcription`. `AssistantSession` — in-memory `ObservableObject`, НЕ SwiftData; персистятся только отдельные ходы | **2–4** ⚡спорно | L | ⚠️⚠️ очень высокая (весь recorder-рефактор v2: `VoiceInkEngine+Assistant`, `TranscriptionPipeline`, `RecorderUIManager`, 3 recorder-вью) |
| 9 | **RecordingContextSnapshot** | На старте записи параллельными Task снимает clipboard + выделенный текст + screen-OCR → в AI-контекст. В форке только screen, on-demand через toggle | **3** | M | ⚠️ движок (`activeRecordingContextStore` → pipeline → `AIEnhancementService`) |
| 10 | **ScreenCapture robustness** | AX-таргетинг нужного окна среди нескольких окон приложения (frame-distance + title match), timeout 3с через task group, clamp масштаба (`maximumCaptureDimension 2800`). Тот же OCR-core, но точнее контекст для AI | **3** | M | ✅ низкая |
| 11 | **Starter mode templates** | 5 готовых режимов (Dictation/Enhancement/Email/Rewrite/Assistant) с иконками/промптами/context-флагами, ставятся в онбординге | **3** | M | ⚠️ онбординг + зависит от #1/#8 (Assistant-темплейт нужен respond-mode) |
| 12 | **Model Usage panel** | Распределение по моделям: транскрипция по est. audio-времени, enhancement по est. токенам, share-бары + provider-иконки. В форке есть только performance (скорость/латентность) | **3** | M | ✅ (токен-половина требует нового поля `SessionMetric.enhancementEstimatedTokenCount`) |
| 13 | **Per-mode realtime/context тумблеры** | `isRealtimeTranscriptionEnabled`, `useClipboardContext`, `useSelectedTextContext` на **каждый** режим (в форке глобально) | **3** | S | ✅ (поля + Codable-миграция) |
| 14 | **Time-Saved per-period + hero book-benchmarks** | «Сэкономлено X за выбранный период = N рабочих дней», hero сравнивает lifetime word count с книгами («Война и мир ×2»), lock-state до 30 мин использования | **3** | S | ✅ (форматирование над существующими тоталами; v2 берёт 40 WPM baseline vs форк 35) |

---

## Tier C — косметика / низкий приоритет

- **App appearance theme switch** (2, S) — System/Light/Dark override через `NSApplication.appearance`. В форке только пассивный `@Environment(\.colorScheme)`.
- **App language динамический список** (2, S) — v2 авто-обнаруживает языки из `Bundle.main.localizations` (+de/zh-Hans). Форк: хардкод 3 (system/en/ru), но с авто-relaunch (у v2 relaunch нет). Ни один не делает live-switch.
- **AppSidebar редизайн** (2, M) — hand-built sidebar с цветными icon-tile. Косметика поверх реструктуризации `ViewType` (v2 схлопывает enhancement+powerMode+permissions+audioInput в «modes»).
- **SF-Symbol иконки режимов** (2, S) — `ModeIcon` = symbol или emoji vs форк emoji-only.
- **Dictionary dedup** (2, S) — `removeExactDuplicateContent`: дедуп `VocabularyWord`+`WordReplacement` (keeps earliest by `dateAdded`).
- **EstimatedTokenCounter** (2, S) — наивный `(chars+3)/4` оценщик токенов.
- **Editable имя + time-of-day greeting** на дашборде (2, S).
- **Recent transcripts на дашборде** (2, S) — дублирует History.

---

## ⚠️ Обратные пробелы — что теряешь, если тащить v2 целиком

- **WPM card** + **Keystrokes-Saved card** — v2-дашборд их не показывает. У форка есть (`MetricsContent.metricsSection`).
- **Promotions / Help секции** на metrics-экране — только у форка (`DashboardPromotionsSection`).
- `InterfaceLanguage` форка умеет авто-relaunch; v2-версия — нет.
- Streaks нет ни у кого (только мягкая копирайт-фраза «on a roll this week» в v2).

Уникальные фичи форка, которых v2 не знает (не трогаем): re-transcribe по языку, keyboard-layout language, paste in chunks, emotion annotation, i18n/Russian.

---

## Рекомендация по ROI

**Максимальный ROI при низком риске** (движок не трогаем): **#3 trigger templates, #4 мульти-AI-провайдеры, #5 connection tester, #7 dashboard-аналитика**. Все ✅ низкая связность, читают только config/UserDefaults/SessionMetric.

**Highest raw power, но дорого:** #1 shell output mode (L + entitlements/sandbox).

**Дорогие из-за архитектурного расхождения** (требуют движка v2): #8 Assistant chat, #9 RecordingContextSnapshot, #2 trigger-word hook.
