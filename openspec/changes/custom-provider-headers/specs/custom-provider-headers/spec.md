## ADDED Requirements

### Requirement: User can manage custom headers for Custom AI Provider
When Custom AI Provider is selected, the user SHALL be able to add, edit, and delete arbitrary HTTP headers (key-value pairs) that will be sent with every LLM request to the custom endpoint.

#### Scenario: Add a custom header
- **WHEN** user selects "Custom" as AI Provider
- **AND** user clicks "Add Header" button
- **AND** user enters key "X-API-Key" and value "abc123"
- **THEN** the new header appears in the headers list
- **AND** the header key "X-API-Key" with value "abc123" is persisted across app restarts

#### Scenario: Edit a custom header value
- **WHEN** user has an existing custom header "X-Org: org-1"
- **AND** user changes the value to "org-2"
- **THEN** the header value is updated to "org-2"
- **AND** the change is persisted

#### Scenario: Remove a custom header
- **WHEN** user has an existing custom header "X-Debug: true"
- **AND** user clicks the delete button on that header
- **THEN** the header is removed from the list
- **AND** it is no longer sent with API requests

#### Scenario: Add multiple custom headers
- **WHEN** user adds header "X-Org: org-1"
- **AND** user adds another header "X-Region: us-east"
- **THEN** both headers are displayed and persisted
- **AND** both headers are sent with every LLM API request

#### Scenario: Header with empty key is not saved
- **WHEN** user leaves the header key field empty
- **AND** user attempts to save
- **THEN** the empty header is ignored and not added to the list

#### Scenario: Header with reserved key shows warning
- **WHEN** user enters "Authorization" as header key
- **AND** user enters any value
- **THEN** a warning is shown that this header may override the standard Authorization header

### Requirement: Custom headers are sent with LLM requests
When a custom provider is selected and custom headers are configured, the system SHALL include all configured custom headers in the HTTP request to the LLM endpoint, in addition to the standard Content-Type and Authorization headers.

#### Scenario: Custom headers included in request
- **WHEN** user has header "X-Org: org-1" configured
- **AND** user performs an AI enhancement
- **THEN** the HTTP request includes the header "X-Org: org-1"
- **AND** the standard "Content-Type: application/json" is still present
- **AND** the standard "Authorization: Bearer <apiKey>" is still present

#### Scenario: Empty headers list sent unchanged
- **WHEN** user has no custom headers configured
- **AND** user performs an AI enhancement
- **THEN** the request is sent with only standard headers (Content-Type, Authorization)

### Requirement: Custom headers are included in backup and restore
When the user exports a backup, custom provider headers SHALL be included. When restoring a backup, custom provider headers SHALL be restored.

#### Scenario: Headers exported in backup
- **WHEN** user has custom headers "X-Org: org-1" configured
- **AND** user exports a backup
- **THEN** the backup file contains the custom headers under general settings

#### Scenario: Headers restored from backup
- **WHEN** user imports a backup containing custom headers
- **THEN** the headers are restored
- **AND** they appear in the Custom provider UI
- **AND** they are sent with subsequent LLM requests
