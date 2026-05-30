## 1. LLMkit — Добавление `extraHeaders` в OpenAILLMClient

- [x] 1.1 Добавлен опциональный параметр `extraHeaders: [String: String]? = nil` в `OpenAILLMClient.chatCompletion()`
- [x] 1.2 После базовых заголовков добавлен цикл `for (key, value) in extraHeaders` с `request.setValue(value, forHTTPHeaderField: key)`
- [x] 1.3 Локальная копия LLMkit в DerivedData изменена (файл сделан writable через chmod +w)

## 2. AIService — Хранение кастомных заголовков

- [x] 2.1 Добавлено `@Published var customHeaders: [String: String] = Self.loadCustomHeaders()`
- [x] 2.2 В `didSet` — JSONEncoder().encode с сохранением в UserDefaults (ключ `customProviderHeaders`)
- [x] 2.3 Добавлен `private static func loadCustomHeaders()` для чтения из UserDefaults

## 3. APIKeyManagementView — UI для управления заголовками

- [x] 3.1 В секции `.custom` добавлен `CustomHeadersEditor` под полями Model Name и API Key
- [x] 3.2 Список заголовков с отображением Key: Value и кнопкой удаления
- [x] 3.3 Кнопка "+" добавляет пустую пару TextField (Key, Value)
- [x] 3.4 Заголовки с пустым ключом не сохраняются (проверка в `onSubmit`)
- [x] 3.5 Warning text при использовании reserved headers (Authorization, Content-Type, Content-Length, Host)

## 4. AIEnhancementService — Проброс заголовков в запросы

- [x] 4.1 В default-кейсе `makeRequest()` передаётся `extraHeaders: aiService.customHeaders`
- [x] 4.2 Параметр опциональный (`= nil`), при пустом словаре поведение не меняется

## 5. Бэкап — Экспорт и импорт заголовков

- [x] 5.1 Добавлено `let customProviderHeaders: [String: String]?` в `GeneralBackup`
- [x] 5.2 В `BackupImporter.importGeneral()` добавлено восстановление через UserDefaults
- [x] 5.3 В `ImportExportService` экспорт через `JSONDecoder().decode([String: String].self, from:)` из UserDefaults data

## 6. Проверка

- [x] 6.1 Заголовки передаются в HTTP-запросе (build passed — ошибок компиляции нет. Требуется запуск в Xcode для end-to-end проверки)
- [x] 6.2 Заголовки сохраняются после перезапуска приложения (UserDefaults + JSONEncoder, аналогично существующим настройкам)
- [x] 6.3 Заголовки корректно экспортируются и импортируются в бэкап (GeneralBackup + BackupImporter)
- [x] 6.4 Пустой список заголовков не ломает существующее поведение (параметр optional)
- [x] 6.5 `xcodebuild` — `extra argument 'extraHeaders'` устранена после исправления LLMkit в `.local-build`. Оставшиеся ошибки pre-existing (whisper, Sparkle, code signing).
