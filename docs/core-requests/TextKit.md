# Core requests from TextKit

## 1. Expose OCR languages through `TextServicing` (for PreferencesKit)
PreferencesKit cannot import TextKit, but its "Text Recognition" pane needs Vision's language list.
Proposed addition to `TextServicing` in `ShotcraftCore/Services.swift`:

```swift
/// Vision's supported recognition languages as (BCP-47 code, localized name), sorted by name.
func supportedLanguages() -> [(code: String, name: String)]
```

TextKit already implements it as `TextRecognizer.supportedLanguages()`; once the protocol has the requirement,
`TextService` will forward to it (one line). Codes are Vision's BCP-47 identifiers (`en-US`, `zh-Hans`, `de-DE`,
`nb-NO`…); TextKit also normalises legacy/loose values stored in `.ocrLanguages` (`zh-CN` → `zh-Hans`, `de` → `de-DE`).

