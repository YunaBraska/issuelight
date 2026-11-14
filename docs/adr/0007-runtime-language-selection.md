# ADR 0007: Runtime language selection

Status: Accepted

Date: 2026-11-14

## Context

macOS already lets a user choose a language per application. IssueLight also
needs an immediately available choice in Settings because it may be operated
in a language different from the current system language.

The selection must not create a second presentation implementation. It must
also handle right-to-left layout, persist without storing personal data, and
keep language names recognizable when the current UI language is unfamiliar.

## Decision

- One Xcode String Catalog is the source of localized application text.
- The selector offers System Default plus 21 explicit languages. Language
  names are always shown in their native form.
- The built-in languages are English,
  Simplified Chinese, Hindi, Spanish, Arabic, French, Bengali, Portuguese,
  Indonesian, Urdu, Russian, German, Japanese, Nigerian Pidgin, Marathi,
  Vietnamese, Telugu, Swahili, Hausa, Turkish, and Swedish.
- System Default follows the current macOS locale and layout direction.
  Explicit Arabic and Urdu selections use right-to-left layout immediately.
- The selected language identifier is stored in `UserDefaults`. The privacy
  manifest declares Apple's `CA92.1` required-reason entry for that use.
- Menu, windows, accessibility labels, validation, and provider-facing app
  messages all receive the same selected locale.

## Consequences

Changing the language does not require an application restart. macOS-owned
dialogs may still use the system language. Every catalog change must pass the
catalog completeness, placeholder, protected-term, and repetition checks.
Arabic and Urdu screenshots remain part of the rendered UI evidence.
