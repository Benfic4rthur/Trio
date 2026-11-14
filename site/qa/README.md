# Trio website QA

Local-only, isolated headless Microsoft Edge. No native application automation,
user browser profiles, pointer lock/capture, or system clipboard writes.

`browser.mjs` provides the browser lifecycle, diagnostics, section sampling and
contact-sheet generation. Every browser context receives pointer-lock rejection
and no-op pointer-capture methods before any site script executes. Copy controls
use an isolated virtual clipboard and their payload can be verified.

Runtime: `npm ci --prefix site/qa` installs playwright-core only; the installed
Microsoft Edge binary supplies the browser. No downloaded browser, paid API or
GitHub Actions is used.

The site server belongs to the main task and must remain running after QA.
Default URL: `http://localhost:4178`; override with `TRIO_QA_URL` if instructed.
Before execution, confirm the server is serving the current Trio package.

Required coverage:

- Desktop 1440×1000, phone 390×844, compact 360×640 and reduced motion.
- Opening, intermediate and exit states sampled within actual page sections.
- Native-looking demo wave hover/tap, close/reopen, minimize/restore,
  maximize/restore and manual reset.
- Portuguese, English and Spanish, including persisted `allm4.language.v1`.
- Dialog keyboard/Escape, visible focus, complete reduced-motion copy.
- Console/request errors, broken images/fonts, missing anchors and overflow.
- Download response 200 and actual ZIP entries containing app + installer.
- Release metadata fallback and parser checks are owned by the release agent;
  this harness verifies the final browser-visible result and download.

Screenshots and reports are preserved per run under `site/qa/artifacts/`.
A rerun must name the earlier failure it supersedes. Headless phone-sized Edge
is responsive evidence, not physical iOS/Safari/hardware verification.

The DOM-specific runner is added after the actual template/selectors are ready;
QA never guesses control labels or routes that are not present in the source.
