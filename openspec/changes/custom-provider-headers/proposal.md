## Why

Пользователи, подключающие кастомного LLM-провайдера (Custom AI Provider), не могут передавать дополнительные HTTP-заголовки, которые требуются некоторым API для аутентификации, маршрутизации или кастомной конфигурации. Например, некоторые self-hosted или прокси-серверы ожидают заголовки `X-API-Key`, `X-Organization-ID`, `X-Request-Source` и т.д. Сейчас отправляется только стандартный `Authorization: Bearer <key>`.

## What Changes

- Добавление UI в `APIKeyManagementView` для управления кастомными заголовками при выборе провайдера `.custom`
- Хранение заголовков в `AIService` как `[String: String]` с персистентностью в UserDefaults
- Проброс заголовков до `OpenAILLMClient.chatCompletion()` при вызове для кастомного провайдера
- Поддержка экспорта/импорта заголовков в бэкапе
- Добавление параметра `extraHeaders` в метод `OpenAILLMClient.chatCompletion()` (библиотека LLMkit)

## Capabilities

### New Capabilities
- `custom-provider-headers`: Управление кастомными HTTP-заголовками для Custom AI Provider — добавление, удаление, редактирование пар ключ-значение

### Modified Capabilities
<!-- Нет существующих spec-файлов для модификации -->

## Impact

- **VoiceInk/Services/AIEnhancement/AIService.swift** — новое свойство `customHeaders: [String: String]` с UserDefaults persistence
- **VoiceInk/Views/AI Models/APIKeyManagementView.swift** — UI для добавления/удаления заголовков при выборе `.custom` провайдера
- **VoiceInk/Services/AIEnhancement/AIEnhancementService.swift** — проброс заголовков в вызов OpenAILLMClient
- **LLMkit (package)** — модификация `OpenAILLMClient.chatCompletion()`: новый параметр `extraHeaders: [String: String]?`
- **VoiceInk/Services/BackupTypes.swift** — сериализация заголовков в бэкап
- **VoiceInk/Services/BackupImporter.swift** — восстановление заголовков из бэкапа
