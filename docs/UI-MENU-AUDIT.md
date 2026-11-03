# UI menu and presentation audit

## Guidance

Reviewed against Apple's [Menus](https://developer.apple.com/design/human-interface-guidelines/menus), [Settings](https://developer.apple.com/design/human-interface-guidelines/settings), and [Segmented controls](https://developer.apple.com/design/human-interface-guidelines/segmented-controls) guidance: concise action labels, related command groups, shallow navigation, standard controls, and task-specific options near their task.

## Examined surfaces

- Main navigation and Settings/Library switching (`MainWindow.swift`).
- Setup overview, section navigation, model/voice/permission settings (`OnboardingView.swift`, `SetupPage.swift`, `ModelsSection.swift`).
- Home attention, current work, automatic services, results (`TodayView.swift`).
- Connections, catalogue, setup forms, trusted-sender review and whitelist (`ConnectorsView.swift`, `ConnectionSetupSheet.swift`).
- Routine list and editor (`CommandRoutinesView.swift`).
- Knowledge source/index/retrieval controls and Memory tabs/editors (`KnowledgeView.swift`, `MemoryView.swift`).
- History, provenance, activity dock, status popovers, operation details and saved conversations (`ActivityView.swift`, `ActivityDockViews.swift`, `ActivityMonitoringViews.swift`).
- Capture setup, settings, retained recordings and audio details (`CaptureViews.swift`, `CaptureSettingsView.swift`, `CaptureAudioViews.swift`).
- Archived News topic editor and preferences (`NewsView.swift`).
- App menu and menu-bar entry (`AitvarasApp.swift`).

This is a source-level audit, not a claim that every state has been visually exercised. Chat/provider/context changes are reviewed separately by the main task.

## Changed in this audit

- Routine introduction uses a short summary; the original learning, data and safety explanation remains in a disclosure.
- Focus setup uses a short summary with separate disclosures for detailed behavior/privacy and optional macOS Focus setup.
- Capture settings replace the setup surface inline instead of opening another sheet. Returning reloads saved capture settings, retaining the existing consent-reset rules.
- Retained-audio storage and recording detail navigate inline with explicit Back controls. Retention, deletion confirmations, model downloads, transcription and export actions are unchanged.
- Saved conversations replace operation details inline with a Back control instead of opening a second sheet.
- Home's approval action is labeled “Approve” rather than “Do it”.
- Capture settings show one-sentence section summaries with the complete transcription, processing and second-pass explanations available in disclosures.
- Settings is available through the standard app menu and Command-comma, uses native pane tabs and restores the last pane. Setup's nine custom pills are replaced by one native section menu.
- Activity popovers show operation details inline with Back rather than opening another sheet.
- Chat provider settings use one tabbed panel opened on the selected backend; the context panel uses brief rows and optional detail disclosures.

## Remaining recommendations

- Library/Memory view switches can receive a further native-pane navigation pass; main Settings now uses native tabs.
- Sender trust and audio deletion intentionally retain explicit destructive/security confirmations. Do not remove these to reduce presentation depth; consider inline confirmation only with equivalent clarity and safeguards.
- Continue visual verification at minimum window sizes, especially capture settings' inline retained-audio list, keyboard focus/Back behavior, and long localized labels.

No live services were accessed for this audit, and no execution, permission, consent or retention defaults were changed.
