## ADDED Requirements

### Requirement: Отсутствие крашей на принудительном развёртывании

Код SHALL не аварийно завершаться при пустых коллекциях, nil-значениях или несовпадении типов. Принудительные операции (`!`, `as!`, `try!`, индексация `[0]`, `.first!`) на значениях, которые могут быть пустыми/nil/иного типа, MUST быть заменены безопасными вариантами (`guard let`, `as?`, `.first`, проверка `isEmpty`).

#### Scenario: Пустой аудиобуфер
- **WHEN** `AudioFileProcessor` обрабатывает пустой массив `int16Samples`
- **THEN** функция возвращает результат или ошибку без обращения к `baseAddress!` на nil-указателе

#### Scenario: Пустой список промптов
- **WHEN** `AIEnhancementService` выбирает активный промпт при пустом `allPrompts`
- **THEN** используется дефолтный fallback без `allPrompts.first!`

#### Scenario: Модель не найдена при онбординге
- **WHEN** `OnboardingModelDownloadView` ищет модель и совпадение отсутствует
- **THEN** код безопасно обрабатывает nil вместо `as! WhisperModel`

#### Scenario: Пустой результат FileManager.urls
- **WHEN** `VoiceInkEngine` инициализируется и `FileManager.urls` вернул пустой массив
- **THEN** инициализация не падает на индексе `[0]`

### Requirement: Корректная изоляция конкурентности

Доступ к `@Published`/`@MainActor`-изолированным свойствам SHALL происходить на main-акторе. Общая изменяемая память, доступная из произвольных потоков (event monitor'ы, задачи), MUST синхронизироваться (actor, `@MainActor`, lock).

#### Scenario: Изменение @Published в error-пути
- **WHEN** `AudioFileTranscriptionService` ловит ошибку и сбрасывает `isTranscribing`/`currentError`
- **THEN** изменение выполняется внутри `await MainActor.run`, как в success-путях

#### Scenario: Конкурентная загрузка моделей FluidAudio
- **WHEN** `getOrLoadModels()` вызывается параллельно
- **THEN** доступ к `loadingTask` синхронизирован и дедупликация загрузок не ломается

#### Scenario: Доступ к полям из global event monitor
- **WHEN** замыкание `addGlobalMonitorForEvents` в `RecordingShortcutManager` читает `@MainActor`-свойства
- **THEN** доступ бриджится через `MainActor.run`/`Task @MainActor`

### Requirement: Гарантированная пропагация ошибок

Ошибки операций сохранения и создания SHALL не проглатываться молча. `try?` на критичных операциях (`modelContext.save()`) MUST быть заменён на do/catch. `fatalError` в recoverable-путях MUST быть заменён на брошенную ошибку.

#### Scenario: Сбой сохранения транскрипции
- **WHEN** `modelContext.save()` в `VoiceInkEngine` завершается ошибкой
- **THEN** ошибка логируется/пробрасывается, а уведомление об успехе НЕ постится

#### Scenario: Невозможность создать провайдера
- **WHEN** `StreamingTranscriptionService.createProvider()` не может создать провайдера
- **THEN** бросается ошибка, а не вызывается `fatalError`

### Requirement: Освобождение ресурсов и наблюдателей

Объекты, регистрирующие `NotificationCenter`-наблюдателей или системные мониторы, SHALL снимать их при деаллокации или завершении сессии. Объект MUST иметь `deinit`/`removeObserver` либо симметричную регистрацию/снятие.

#### Scenario: Деаллокация VoiceInkEngine
- **WHEN** экземпляр `VoiceInkEngine` деаллоцируется
- **THEN** все зарегистрированные observer'ы сняты, и уведомление не вызывает обращение к мёртвому объекту

#### Scenario: Симметрия observer в PowerMode-сессии
- **WHEN** `PowerModeSessionManager` начинает повторную сессию
- **THEN** observer `AppSettingsDidChange` зарегистрирован для каждой сессии, симметрично снятию

### Requirement: Согласованность состояния в путях отмены и повторного входа

Флаги и поля состояния SHALL сбрасываться во всех путях завершения, включая отмену и ранние return. Состояние MUST не «протекать» между сессиями/записями.

#### Scenario: Отмена записи
- **WHEN** запись отменяется в состоянии `.transcribing`/`.enhancing`
- **THEN** `shouldCancelRecording` сбрасывается в `false`, и следующая запись не прерывается stale-значением

#### Scenario: Отменённая транскрипция
- **WHEN** вызывается `markAsCanceledTranscription()`
- **THEN** поля `powerModeName`/`powerModeEmoji` обнуляются, и UI не показывает Power Mode

#### Scenario: Ранний return при валидации лицензии
- **WHEN** `LicenseViewModel` получает пустой ключ и делает ранний return
- **THEN** `isValidating` сброшен в `false`, и UI не зависает в состоянии загрузки

### Requirement: Корректность логических операций

Условия, сравнения и операции трансформации SHALL давать семантически верный результат. Сопоставление доменов MUST учитывать границы; редундантные/no-op операции MUST быть устранены; пустые входные значения MUST отсекаться.

#### Scenario: Матч URL по домену
- **WHEN** PowerMode сопоставляет URL с правилом `example.com`
- **THEN** `myexample.com` НЕ считается совпадением (сравнение по границе домена, не `contains()`)

#### Scenario: Пустой URL в конфиге
- **WHEN** пользователь добавляет website-правило и `cleanURL()` вернул пустую строку
- **THEN** запись не добавляется в `websiteConfigs`

#### Scenario: Carbon hot key down-state
- **WHEN** срабатывает Carbon hot key с ненулевым `onShortcutPressed`
- **THEN** `state.isDown` выставлен в `true` до раннего return, и release-событие обрабатывается
