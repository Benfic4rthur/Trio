# Opening screenshots — independent visual review

Reviewed only the supplied `desktop-hero.png` (1440×1000) and `phone-hero.png` (390×844) in `site/qa/artifacts/opening-2026-11-14T22-00-57-869Z/`. No browser/native applications were opened, and no shared sources were edited.

## Findings

### P3 — Mobile supporting copy is too small to read comfortably

In `phone-hero.png`, the platform note under the CTAs (around y=393) and the two-line browser-demo disclosure (around y=745–760) appear about 8–9 pixels tall. The disclosure is useful context because the window looks like app UI, but it is substantially harder to read than the main body copy.

Minimal correction: give these two real supporting-text elements a readable mobile size (approximately 11–12 CSS px or larger) and adequate line spacing. Keep the mock window's ornamental interface text smaller if needed; it does not carry the same explanatory role.

## Touch concern requiring hit-box confirmation

The three colored demo controls in the phone image are roughly 21–22 pixels across and almost touch. The language choices also look compact. Pixels alone do not establish their actual clickable bounds, so this is **not a confirmed hit-target failure**. Confirm that each interactive control has sufficient nonoverlapping touch area; expanding invisible bounds must not overlap adjacent controls. The main download CTA appears comfortably sized.

## Composition and clipping

- No visible text clipping, horizontal overflow, or overlapping content in either supplied screenshot.
- Desktop hierarchy is clear: title, explanation, primary download CTA, secondary demo CTA, then the window illustration. The lower window continuation beyond the desktop viewport reads as scrollable content rather than a broken crop.
- The mobile headline breaks cleanly into two lines, both CTAs fit on one row, and the mock window is fully visible inside the viewport. Decorative rear planes reach the side edges without obstructing text or actions.
- Main heading/body/CTA contrast and legibility look good. No visual blocker found in these opening states.

This review covers only the two opening screenshots, not scrolling, hover, focus, other languages, or interaction behavior.
