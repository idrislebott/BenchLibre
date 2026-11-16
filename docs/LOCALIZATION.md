# Languages — BenchLibre 0.3.2

English is the default application language, including on a Mac whose system language is French. French is an explicit, optional choice. The application remembers its own language preference; changing it does not change macOS or other applications.

The language selector changes labels and explanatory text in the open interface. Number and date formatting use the selected application's locale rather than silently inheriting the system locale. A language change must not recreate the benchmark window or cancel an active session.

The selector is available in the sidebar, the Language menu and application settings. The headless modes accept `--language en` or `--language fr`, default to English and do not change the saved GUI language preference.

## Resources and message formatting

The local BenchCore resource bundle contains English and French string tables:

- `Core.strings`: benchmark progress, validation and core messages.
- `Interface.strings`: result cards, explanations, history and measurement context.
- `App.strings`: application commands, settings and application status.

English source keys remain readable fallback text when an entry is missing. Templates use named tokens such as `{count}` and `{reason}`. Formatting treats values as text; values are not recursively substituted and percent characters are not C format directives. Catalog validation checks matching keys, matching named tokens and duplicate decoded keys.

Localization resources come from the application's own embedded resource bundle. Production code does not select resources through environment variables, the working directory or SwiftPM's development-path fallbacks.

## Reports and comparability

The benchmark workloads, counted work, checksums and timing definitions do not depend on the display language. The suite identifier and JSON schema remain compatible.

Machine-readable identifiers and units are canonical. In particular, the historical `Go/s` and `ns/accès` unit strings remain unchanged in JSON so existing reports keep their meaning and validation rules. The English interface explains them as GB/s and nanoseconds per access.

Persisted reports may contain human-readable text in the language in which they were produced. Historical details are retained as recorded; switching the interface language does not rewrite an old report or pretend to translate arbitrary persisted content. The interface identifies original report text where it displays it. Hardware condition values also remain canonical in reports and are translated for display. New OS metadata is assembled from the numeric Foundation version and the public `kern.osversion` build identifier, avoiding a localized system description. Comparison recognizes the historical French `assemblage` label and an omitted zero patch component without discarding real version or build differences. Unknown descriptions remain exact comparisons. System error text may still originate from macOS itself.

## Development checks

Localization tests exercise packaged English/French lookups, default English behavior, independent language instances, readable fallback text, named-token safety, locale-specific decimal formatting, matching catalog keys/tokens and duplicate decoded-key detection. Existing numerical and resource-boundary tests retain their measurement and memory-safety assertions; only English-facing message expectations change.

The language selector and remembered preference also need verification in the signed macOS application, including switching languages while a result is open and reopening the app with the selected preference. Tests of formatting are not performance measurements.
