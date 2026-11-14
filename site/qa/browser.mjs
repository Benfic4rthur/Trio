import { chromium } from 'playwright-core';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';

export const EDGE = '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge';
export const BASE_URL = process.env.TRIO_QA_URL || 'http://localhost:4178';
export const viewports = {
  desktop: { width: 1440, height: 1000 },
  phone: { width: 390, height: 844 },
  compact: { width: 360, height: 640 },
};

export async function createSafePage({ viewport = viewports.desktop, reducedMotion = false, touch = false, locale = 'pt-BR' } = {}) {
  const profile = await mkdtemp(path.join(tmpdir(), 'trio-site-qa-'));
  const context = await chromium.launchPersistentContext(profile, {
    executablePath: EDGE,
    headless: true,
    viewport,
    deviceScaleFactor: 1,
    isMobile: touch,
    hasTouch: touch,
    locale,
    colorScheme: 'light',
    reducedMotion: reducedMotion ? 'reduce' : 'no-preference',
    args: ['--no-first-run', '--no-default-browser-check', '--disable-background-networking', '--disable-sync'],
  });
  const guards = () => {
    // The QA browser must never acquire native pointer lock or capture.
    Object.defineProperty(Element.prototype, 'requestPointerLock', {
      configurable: true,
      value() { return Promise.reject(new DOMException('Native pointer lock disabled in isolated QA', 'NotAllowedError')); },
    });
    for (const name of ['setPointerCapture', 'releasePointerCapture']) {
      Object.defineProperty(Element.prototype, name, { configurable: true, value() {} });
    }
    // Exercise copy controls without overwriting the user's system clipboard.
    Object.defineProperty(navigator, 'clipboard', {
      configurable: true,
      value: {
        async writeText(text) { window.__trioQAClipboard = String(text); },
        async readText() { return window.__trioQAClipboard || ''; },
      },
    });
    window.__trioQASafety = { pointerLock: "rejected", pointerCapture: "no-op", clipboard: "virtual" };
  };
  await context.addInitScript(guards);
  const page = context.pages()[0] || await context.newPage();
  // Also protect the already-created blank document used for contact sheets.
  await page.evaluate(guards);
  page.setDefaultTimeout(8000);
  page.setDefaultNavigationTimeout(25000);
  const activity = { console: [], errors: [], requestsFailed: [], httpErrors: [] };
  page.on('console', message => {
    if (['error', 'warning'].includes(message.type())) activity.console.push({ type: message.type(), text: message.text(), location: message.location() });
  });
  page.on('pageerror', error => activity.errors.push(error.message));
  page.on('requestfailed', request => activity.requestsFailed.push({ url: request.url(), failure: request.failure()?.errorText }));
  page.on('response', response => {
    if (response.status() >= 400) activity.httpErrors.push({ status: response.status(), url: response.url() });
  });
  return {
    context, page, activity,
    async close() {
      await context.close();
      await rm(profile, { recursive: true, force: true });
    },
  };
}

export async function auditPage(page) {
  return page.evaluate(async () => {
    await document.fonts.ready;
    const root = document.documentElement;
    const visible = element => {
      const style = getComputedStyle(element), rect = element.getBoundingClientRect();
      return style.display !== 'none' && style.visibility !== 'hidden' && Number(style.opacity) > 0 && rect.width > 0 && rect.height > 0;
    };
    return {
      title: document.title,
      lang: root.lang,
      url: location.href,
      viewport: { width: innerWidth, height: innerHeight },
      scroll: { width: root.scrollWidth, height: root.scrollHeight, horizontalOverflow: root.scrollWidth > innerWidth + 1 },
      fonts: { status: document.fonts.status, body: getComputedStyle(document.body).fontFamily, heading: document.querySelector('h1') ? getComputedStyle(document.querySelector('h1')).fontFamily : null },
      headings: [...document.querySelectorAll('h1,h2,h3')].map(element => ({ level: element.tagName, text: element.textContent.trim() })),
      brokenImages: [...document.images].filter(image => image.complete && !image.naturalWidth).map(image => image.currentSrc || image.src),
      anchorsMissingTargets: [...document.querySelectorAll('a[href^="#"]')].filter(link => link.hash.length > 1 && !document.getElementById(decodeURIComponent(link.hash.slice(1)))).map(link => link.getAttribute('href')),
      sections: [...document.querySelectorAll('main > section, section[data-sc-act]')].map(section => ({ id: section.id, top: section.getBoundingClientRect().top + scrollY, height: section.getBoundingClientRect().height })),
      visibleInteractive: [...document.querySelectorAll('a,button,input,select,textarea,[tabindex]')].filter(visible).map(element => {
        const rect = element.getBoundingClientRect();
        return { tag: element.tagName, role: element.getAttribute('role'), name: element.getAttribute('aria-label') || element.textContent.trim().slice(0,100), width: rect.width, height: rect.height, tabIndex: element.tabIndex };
      }),
    };
  });
}

export async function captureSectionSamples(page, directory, { samples = [0, 0.25, 0.5, 0.75, 1] } = {}) {
  await mkdir(directory, { recursive: true });
  const sections = await page.locator('main > section, section[data-sc-act]').evaluateAll(elements => elements.map((element, index) => ({
    id: element.id || `section-${index + 1}`,
    top: element.getBoundingClientRect().top + scrollY,
    height: element.getBoundingClientRect().height,
  })));
  const viewport = page.viewportSize();
  const maximum = await page.evaluate(() => Math.max(0, document.documentElement.scrollHeight - innerHeight));
  const captures = [];
  for (const section of sections) {
    const first = Math.max(0, section.top - viewport.height * 0.25);
    const last = Math.min(maximum, Math.max(first, section.top + section.height - viewport.height * 0.65));
    for (const progress of samples) {
      const y = Math.round(first + (last - first) * progress);
      await page.evaluate(y => scrollTo({ top: y, behavior: 'instant' }), y);
      await page.waitForTimeout(180);
      const file = path.join(directory, `${section.id.replace(/[^a-z0-9_-]/gi,'-')}-${Math.round(progress*100)}.png`);
      await page.screenshot({ path: file });
      captures.push({ file, section: section.id, progress, y });
    }
  }
  return captures;
}

export async function contactSheet(captures, destination, { columns = 3, width = 1440 } = {}) {
  const session = await createSafePage({ viewport: { width, height: 900 } });
  const escape = value => String(value).replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;');
  try {
    const cards = [];
    for (const capture of captures) {
      const data = await readFile(capture.file);
      cards.push(`<figure><figcaption>${escape(capture.label || `${capture.section || ''} ${capture.progress ?? ''}`)}</figcaption><img src="data:image/png;base64,${data.toString('base64')}"></figure>`);
    }
    await session.page.setContent(`<!doctype html><meta charset="utf-8"><style>*{box-sizing:border-box}body{margin:0;padding:18px;background:#e7e7e7;color:#121212;font:14px system-ui}main{display:grid;grid-template-columns:repeat(${columns},1fr);gap:16px}figure{margin:0;background:white;border:1px solid #ccc}figcaption{padding:9px 11px;font-weight:600}img{display:block;width:100%;height:auto}</style><main>${cards.join('')}</main>`);
    await session.page.locator('img').evaluateAll(images => Promise.all(images.map(image => image.decode())));
    await session.page.screenshot({ path: destination, fullPage: true });
  } finally { await session.close(); }
}

export async function saveJSON(file, value) {
  await mkdir(path.dirname(file), { recursive: true });
  await writeFile(file, JSON.stringify(value, null, 2) + '\n');
}
