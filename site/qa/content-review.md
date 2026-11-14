# Content review — Trio local website

Reviewed `site/content.mjs` (PT/EN/ES), the local build/download metadata flow, installation guide, app UI strings, and `docs/PIPELINE-VALIDATION.md`. Read-only review; no native applications were opened or activated, and no fixture tests were run.

## Finding

### P2 — Translated instructions quote app labels that do not exist

- `site/content.mjs:151`: English instructions quote **Hide Trio** and **Quit Trio**.
- `site/content.mjs:195`: English instructions say to choose **Open Trio** from the app's context menu.
- `site/content.mjs:253`: Spanish instructions quote **Ocultar Trio** and **Salir de Trio**.

The native app currently exposes Portuguese labels, without localization: **Abrir Trio**, **Esconder Trio**, **Encerrar Trio** in `Sources/Trio/main.swift:145-149` / `:161-164`; settings also use **Encerrar Trio** and **Esconder Trio** in `Sources/Trio/Settings.swift:200-201`; the overlay context menu uses **Abrir Trio** in `Sources/Trio/Engine.swift:781`.

Minimal correction: keep the explanatory sentences translated, but quote the real native labels. For example, EN: `"Esconder Trio" keeps the controls running; "Encerrar Trio" stops the helper.` and `choose "Abrir Trio"`; ES: `"Esconder Trio" mantiene los controles activos; "Encerrar Trio" detiene el auxiliar.` The browser demo's translated `runtimeCopy.openTrio` labels should remain translated because they describe its own interface.

## Checks without findings

- All three locales have the same 80 content keys and 36 runtime keys, with no missing or extra translations. Wording is understandable and broadly natural in PT/EN/ES.
- The content accurately describes the local preview, local signing, lack of Apple notarization, Accessibility approval, prebuilt ZIP, preserved previous installation, and normal macOS approval flow.
- Universal architecture is distinguished from physical compatibility testing: the download note identifies untested Intel hardware, and FAQ answers also identify older macOS versions as untested.
- Scope is limited to compatible foreground windows using public APIs, with fallback to original controls when the safe area is unavailable.
- Default 1.5×, configurable maximum 5× subject to window space, minimize, maximize/restore without full screen, and close forwarding match the supplied app facts and validation record.
- The build 7 record validates the real red-button path with SmartClose on the disposable fixture, and records the limitations of synthetic drag coverage. The website does not claim universal validation.
- The build consumes a real ZIP and matching checksum/metadata, and the runtime labels distinguish an available local preview from a public release. No public publication or notarization success is inferred by this review.

No content or shared app/site source files were edited.
