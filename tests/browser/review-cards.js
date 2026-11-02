// Isolated frontend smoke: synthetic API, no backend or shared DATA access.
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const { chromium } = require('playwright');
const root = path.resolve(__dirname, '../../app/frontend');
const user = { username: 'preview', displayName: 'Aperçu', role: 'superAdmin', employeeCode: null, mustChangePassword: false };
const projects = [{ projectCode: 'ALPHA', projectName: 'Modernisation', colorKey: 'mint', admins: [], backupAdmins: [] }];
const base = { employeeCode: '000000001', employeeName: 'Camille Tremblay', date: '2026-10-05', punchIn: '17:00:00', punchOut: '18:30:00', overtime: '01:30:00', projectCode: 'ALPHA', overtimeCode: '260', paymentOption: 'cash', workSchedule: 'regular', canModify: true, canApprove: true };
const approvals = [
  ...Array.from({ length: 6 }, (_, i) => ({ ...base, entryId: `pending-${i}`, status: 'pending', ...(i === 0 ? { workComment: 'Justification détaillée '.repeat(12), message: 'Note du superviseur' } : {}) })),
  { ...base, entryId: 'warning', status: 'pending', employeeName: 'Alexandre-Nicolas Très-Long-Nom-De-Famille', hasReviewIssues: true, reviewIssues: [{ code: 'shortOvertime' }], overtime: '00:00:00', workSchedule: 'unconfirmed' },
  { ...base, entryId: 'approved', status: 'approved', canModify: false },
  { ...base, entryId: 'rejected', status: 'rejected' },
];
const requests = [];
const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://localhost');
  requests.push({ method: req.method, path: url.pathname });
  const data = url.pathname === '/auth/me' ? user
    : url.pathname === '/sync/status' ? { version: 1, changeId: 'preview', category: 'history' }
      : url.pathname === '/review/bootstrap' ? { approvals, projects } : undefined;
  if (data !== undefined) { res.setHeader('Content-Type', 'application/json'); res.end(JSON.stringify(data)); return; }
  const file = path.resolve(root, `.${url.pathname === '/' ? '/index.html' : url.pathname}`);
  if (!file.startsWith(root + path.sep) || !fs.existsSync(file) || !fs.statSync(file).isFile()) { res.statusCode = 404; res.end('Not found'); return; }
  res.setHeader('Content-Type', ({ '.html': 'text/html', '.js': 'application/javascript', '.css': 'text/css', '.woff2': 'font/woff2' })[path.extname(file)] || 'application/octet-stream');
  res.end(fs.readFileSync(file));
});

(async () => {
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const origin = `http://127.0.0.1:${server.address().port}`;
  const chromePath = process.env.SAPHIR_CHROME_PATH || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
  const browser = await chromium.launch({ headless: true, ...(fs.existsSync(chromePath) ? { executablePath: chromePath } : {}) });
  try {
    const page = await browser.newPage({ viewport: { width: 1600, height: 1100 } });
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    await page.addInitScript(({ origin, user }) => {
      localStorage.setItem('saphirAppApiUrl', origin + '/');
      localStorage.setItem('saphirAppSession', JSON.stringify({ token: 'preview', user }));
      localStorage.setItem('activeView', 'adminView');
      localStorage.setItem('saphirAppLanguage', 'fr');
      localStorage.setItem('saphirAppTheme', 'dark');
    }, { origin, user });
    await page.goto(origin);
    await page.waitForSelector('#pendingContainer .review-card');
    const grid = page.locator('#pendingContainer .review-card-grid');
    const columns = () => grid.evaluate(el => getComputedStyle(el).gridTemplateColumns.split(' ').length);
    assert.equal(await columns(), 3, 'Wide review should show three cards per row.');
    assert.equal(await grid.locator('.review-card').count(), 7);
    assert.equal(await grid.locator('.approvals-approve-button').count(), 7);
    assert.equal(await grid.locator('.approvals-edit-button').count(), 7);
    assert.equal(await grid.locator('.approvals-jump-button').count(), 7);
    await page.locator('#approvalsSection').screenshot({ path: '/tmp/saphir-review-cards-desktop.png' });
    await page.setViewportSize({ width: 1050, height: 1000 });
    assert.equal(await columns(), 2, 'Medium review should show two cards per row.');
    await page.locator('#attention-tab').click();
    await page.waitForSelector('#attentionContainer .review-card-attention');
    assert.equal(await page.locator('#attentionContainer .review-card').count(), 1);
    for (const theme of ['light', 'dark']) {
      await page.evaluate(theme => applyAppTheme(theme), theme);
      await page.setViewportSize({ width: 390, height: 900 });
      await page.locator('#approvalsSection').screenshot({ path: `/tmp/saphir-review-cards-${theme}-mobile.png` });
      assert.equal(await page.locator('#attentionContainer .review-card-grid').evaluate(el => getComputedStyle(el).gridTemplateColumns.split(' ').length), 1);
      assert(!await page.locator('#approvalsSection').evaluate(el => el.scrollWidth > el.clientWidth + 1), `Review overflowed on mobile: ${JSON.stringify(await page.locator('#approvalsSection').evaluate(el => [...el.querySelectorAll('*')].filter(child => child.getBoundingClientRect().right > el.getBoundingClientRect().right + 1).map(child => child.className).slice(0, 12)))}`);
      assert(!await page.locator('#attentionContainer .review-card').evaluate(el => el.scrollWidth > el.clientWidth + 1), 'Warning card overflowed on mobile.');
    }
    await page.locator('#approved-tab').click();
    await page.waitForSelector('#approvedContainer .review-card');
    assert.equal(await page.locator('#approvedContainer .approvals-approve-button').count(), 0);
    assert.equal(await page.locator('#approvedContainer .approvals-edit-button').count(), 0);
    await page.locator('#rejected-tab').click();
    await page.waitForSelector('#rejectedContainer .review-card');
    assert.equal(await page.locator('#rejectedContainer .approvals-reject-button').count(), 0);
    await page.locator('#pending-tab').click();
    await page.locator('#approvalsSearchInput').fill('no-matching-employee');
    assert.equal(await grid.count(), 0, 'Empty search should replace the grid with its empty state.');
    assert.equal(requests.filter(r => r.path === '/review/bootstrap').length, 1, 'Layout changes must not fetch review data again.');
    assert(!requests.some(r => r.path.includes('history')), 'Review must not eagerly load history.');
    assert(!requests.some(r => r.method !== 'GET'), 'Preview must not write data.');
    assert.deepEqual(errors, []);
    console.log('Review cards browser smoke passed: 3/2/1 columns, four tabs, permissions/actions, warnings, filtering, light/dark, no overflow or extra requests.');
  } finally {
    await browser.close();
    await new Promise(resolve => server.close(resolve));
  }
})().catch(error => { console.error(error); server.close(); process.exitCode = 1; });
