import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdir, writeFile } from 'node:fs/promises';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import path from 'node:path';
import { BASE_URL } from './browser.mjs';

const execute = promisify(execFile);

/** Read the actual local artifact. Never installs, launches or executes it. */
export async function verifyDownload(page, href, outputDirectory, expected = {}) {
  const url = new URL(href, page.url());
  assert.equal(url.origin, new URL(BASE_URL).origin, 'QA downloads only the owned local package');
  assert.equal(url.protocol, 'http:');
  const response = await page.request.get(url.href);
  assert.equal(response.status(), 200, 'Actual download must return HTTP 200');
  const bytes = await response.body();
  assert(bytes.length > 1000, 'Package cannot be an empty placeholder');
  assert.equal(bytes.subarray(0, 2).toString(), 'PK', 'Download must be a ZIP');
  const sha256 = createHash('sha256').update(bytes).digest('hex');
  if (expected.sha256) assert.equal(sha256, expected.sha256.toLowerCase(), 'Downloaded bytes must match release metadata');
  if (expected.size) assert.equal(bytes.length, expected.size, 'Downloaded size must match release metadata');
  await mkdir(outputDirectory, { recursive: true });
  const archive = path.join(outputDirectory, 'Trio-downloaded.zip');
  const binary = path.join(outputDirectory, 'Trio-downloaded.executable');
  await writeFile(archive, bytes);
  const script = String.raw`
import json, os, plistlib, stat, sys, zipfile
archive, binary = sys.argv[1:]
with zipfile.ZipFile(archive) as z:
    assert z.testzip() is None, 'Corrupt ZIP entry'
    names = [name for name in z.namelist() if not name.startswith('__MACOSX/')]
    plists = [name for name in names if name == 'Trio.app/Contents/Info.plist' or name.endswith('/Trio.app/Contents/Info.plist')]
    assert len(plists) == 1, 'Exactly one Trio.app Info.plist is required'
    info = plistlib.loads(z.read(plists[0]))
    assert info.get('CFBundleIdentifier') == 'com.allm4.Trio', 'Wrong app bundle identifier'
    executable = plists[0][:-len('Info.plist')] + 'MacOS/' + info['CFBundleExecutable']
    assert executable in names, 'App executable missing'
    installers = [name for name in names if name.rsplit('/',1)[-1] == 'Install.command']
    assert len(installers) == 1, 'Exactly one Install.command is required'
    mode = (z.getinfo(installers[0]).external_attr >> 16) & 0o777
    assert mode & 0o111, 'Installer must retain its executable permission'
    helpers = [name for name in names if '/Contents/Library/LoginItems/' in name and name.endswith('.app/Contents/Info.plist')]
    helper_info = [plistlib.loads(z.read(name)) for name in helpers]
    with open(binary,'wb') as out: out.write(z.read(executable))
    os.chmod(binary, 0o600)
    print(json.dumps({'entryCount': len(names), 'appPlist': plists[0], 'bundleIdentifier': info['CFBundleIdentifier'],
      'version': info.get('CFBundleShortVersionString'), 'build': info.get('CFBundleVersion'),
      'minimumMacOS': info.get('LSMinimumSystemVersion'), 'installer': installers[0], 'installerMode': oct(mode),
      'loginItems': [{'bundleIdentifier': item.get('CFBundleIdentifier'), 'version': item.get('CFBundleVersion')} for item in helper_info]}))
`;
  const { stdout } = await execute('python3', ['-c', script, archive, binary], { maxBuffer: 1024 * 1024 });
  const contents = JSON.parse(stdout);
  const { stdout: archOutput } = await execute('/usr/bin/lipo', ['-archs', binary]);
  const architectures = archOutput.trim().split(/\s+/).sort();
  assert(architectures.includes('arm64') && architectures.includes('x86_64'), 'Universal package must contain Apple Silicon and Intel code');
  if (expected.version) assert.equal(contents.version, String(expected.version));
  if (expected.build) assert.equal(contents.build, String(expected.build));
  return { url: url.href, status: response.status(), size: bytes.length, sha256, architectures, contents, archive };
}
