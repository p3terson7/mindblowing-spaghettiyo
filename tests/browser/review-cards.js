// Isolated frontend smoke: synthetic API, no backend or shared DATA access.
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const { chromium } = require('playwright');
const root = path.resolve(__dirname, '../../app/frontend');
const user = { username: 'preview', displayName: 'Aperçu', role: 'superAdmin', employeeCode: null, mustChangePassword: false };
const projects = [{ projectCode: 'ALPHA', projectName: 'Modernisation', colorKey: 'mint', markerKey: 'square', admins: [], backupAdmins: [] }];
const base = { employeeCode: '000000001', employeeName: 'Camille Tremblay', date: '2026-10-05', punchIn: '17:00:00', punchOut: '18:30:00', overtime: '01:30:00', projectCode: 'ALPHA', overtimeCode: '260', paymentOption: 'cash', reasonCode: 'D', workSchedule: 'regular', canModify: true, canApprove: true };
const approvals = [
  ...Array.from({ length: 60 }, (_, i) => ({ ...base, entryId: `pending-${i}`, status: 'pending', ...(i === 0 ? { workComment: 'Justification détaillée '.repeat(12), message: 'Note du superviseur' } : {}), ...(i === 32 ? { canApprove: false, canModify: false } : {}) })),
  { ...base, entryId: 'warning', status: 'pending', employeeName: 'Alexandre-Nicolas Très-Long-Nom-De-Famille', hasReviewIssues: true, reviewIssues: [{ code: 'invalidPunchTimes' }], punchOut: base.punchIn, overtime: null, workSchedule: 'unconfirmed' },
  { ...base, entryId: 'approved', status: 'approved', canModify: false, entryType: 'diverse', diverseReason: 'Soutien à la formation' },
  { ...base, entryId: 'rejected', status: 'rejected' },
];
const requests = [];
let failReviewPage = false;
const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://localhost');
  requests.push({ method: req.method, path: url.pathname });
  let data = url.pathname === '/auth/me' ? user
    : url.pathname === '/sync/status' ? { version: 1, changeId: 'preview', category: 'history' }
      : undefined;
  if (url.pathname === '/review/bootstrap') {
    if (failReviewPage) {
      res.writeHead(503, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Simulated outage' }));
      return;
    }
    const tab = url.searchParams.get('tab') || 'pending';
    const page = Number(url.searchParams.get('page') || 1);
    const search = url.searchParams.get('search') || '';
    const matching = approvals.filter(e => (tab === 'attention' ? e.hasReviewIssues : e.status === tab) && (!search || e.employeeName.includes(search)));
    const eligible = tab === 'pending' ? matching.filter(e => e.canApprove) : [];
    const rows = url.searchParams.get('actionableOnly') === 'true' ? eligible : matching;
    data = url.searchParams.get('selectionOnly') === 'true'
      ? { total: eligible.length, selection: eligible.map(({entryId, employeeCode, date, punchIn}) => ({entryId, employeeCode, date, punchIn})) }
      : { approvals: rows.slice((page-1)*25, page*25), projects, employees: [{employeeCode: base.employeeCode, employeeName: base.employeeName}], tab, page, pageSize: 25, total: rows.length, totalPages: Math.max(1, Math.ceil(rows.length/25)), counts: {pending:61,attention:1,approved:1,rejected:1}, actionableCount:eligible.length };
  }
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
    assert.equal(await grid.locator('.review-card').count(), 25);
    assert.equal(await grid.locator('.approvals-approve-button').count(), 25);
    assert.equal(await grid.locator('.approvals-edit-button').count(), 25);
    assert.equal(await grid.locator('.approvals-jump-button').count(), 25);
    assert.equal(await page.locator('#approvedContainer .review-card').count(), 0, 'Hidden approved tab was rendered eagerly.');
    const firstMeta = grid.locator('.review-card-meta').first();
    assert.match(await firstMeta.locator('.review-card-entry-details').textContent(), /^260 · En espèce · D$/);
    assert.equal(await firstMeta.locator('.meta-pill').count(), 0, 'Entry code, payment and reason must not create separate pills.');
    assert(await grid.locator('.project-identity-pill').first().evaluate(pill => {
      const center = element => { const box = element.getBoundingClientRect(); return box.top + box.height / 2; };
      const iconCenter = center(pill.querySelector('.project-color-dot'));
      const labelOffset = center(pill.querySelector('.project-identity-label')) - iconCenter;
      return Math.abs(center(pill) - iconCenter) <= 0.5 && labelOffset < 0 && labelOffset > -1;
    }), 'Badge label must be optically centered with its marker.');
    await page.locator('#reviewPagination [data-review-page="2"]').click();
    await page.waitForFunction(() => document.querySelector('#reviewPagination [role="status"]')?.textContent.includes('26'));
    await page.locator('#reviewPagination [data-review-page="1"]').click();
    await page.waitForFunction(() => document.querySelector('#reviewPagination [role="status"]')?.textContent.startsWith('1'));
    await page.locator('#approvalsSection').screenshot({ path: '/tmp/saphir-review-cards-desktop.png' });
    await page.setViewportSize({ width: 1050, height: 1000 });
    assert.equal(await columns(), 2, 'Medium review should show two cards per row.');
    await page.locator('#attention-tab').click();
    await page.waitForSelector('#attentionContainer .review-card-attention');
    assert.equal(await page.locator('#attentionContainer .review-card').count(), 1);
    assert.equal(await page.locator('#attentionContainer .review-card .status-badge').textContent(), 'Heures à vérifier');
    assert(!/punch-out/i.test(await page.locator('#attentionContainer .review-card-duration').textContent()));
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
    assert.equal(await page.locator('#approvedContainer .review-card-entry-details').textContent(), 'Soutien à la formation');
    await page.locator('#rejected-tab').click();
    await page.waitForSelector('#rejectedContainer .review-card');
    assert.equal(await page.locator('#rejectedContainer .approvals-reject-button').count(), 0);
    await page.locator('#pending-tab').click();
    await page.locator('#approvalsSearchInput').fill('no-matching-employee');
    await page.waitForFunction(() => !document.querySelector('#pendingContainer .review-card-grid'));
    assert.equal(await grid.count(), 0, 'Empty search should replace the grid with its empty state.');
    assert.equal(requests.filter(r => r.path === '/review/bootstrap').length, 6, 'Only initial/page 2/three unopened tabs/search should need requests; returning to cached pages must not.');
    assert(await page.evaluate(() => window.openProjectReviewPage('ALPHA')), 'Project navigation did not load its pending page.');
    assert.equal(requests.filter(r => r.path === '/review/bootstrap').length, 7, 'Project navigation fetched an unfiltered bootstrap before its filtered page.');
    assert.equal(await grid.locator('.review-card').count(), 25);
    assert(!requests.some(r => r.path.includes('history')), 'Review must not eagerly load history.');
    assert(!requests.some(r => r.method !== 'GET'), 'Preview must not write data.');
    await page.setViewportSize({ width: 1280, height: 810 });
    const mine = page.locator('#reviewActionableToggle');
    assert.match(await mine.textContent(), /À traiter par moi \(60\)/);
    const requestBeforeMine = requests.filter(r => r.path === '/review/bootstrap').length;
    const mineResponse = page.waitForResponse(response => response.url().includes('actionableOnly=true'));
    await mine.click();
    await mineResponse;
    await page.waitForFunction(() => document.getElementById('reviewPagination').textContent.includes('60'));
    assert.equal(await mine.getAttribute('aria-pressed'), 'true');
    assert.equal(requests.filter(r => r.path === '/review/bootstrap').length, requestBeforeMine + 1);
    let confirmation;
    page.once('dialog', async dialog => { confirmation = dialog.message(); await dialog.dismiss(); });
    const selectionResponse = page.waitForResponse(response => response.url().includes('selectionOnly=true') && response.url().includes('actionableOnly=true'));
    await page.locator('#approveFilteredBtn').click();
    const selection = await (await selectionResponse).json();
    await page.waitForFunction(() => !document.getElementById('approveFilteredBtn').disabled);
    assert.equal(selection.selection.length, 60);
    assert.match(confirmation, /60 entrées admissibles, toutes pages confondues/);
    assert.match(confirmation, /À traiter par moi/);
    assert.match(confirmation, /Projet:.*(ALPHA|Modernisation)/);
    assert.match(confirmation, /Période:.*Toutes les dates/);
    assert(!requests.some(r => r.method === 'POST'), 'Cancelling the batch confirmation must not write.');
    const afterSelection = requests.filter(r => r.path === '/review/bootstrap').length;
    await mine.click();
    assert.equal(await mine.getAttribute('aria-pressed'), 'false');
    await mine.click();
    assert.equal(await mine.getAttribute('aria-pressed'), 'true');
    assert.equal(requests.filter(r => r.path === '/review/bootstrap').length, afterSelection, 'Switching back to cached filters made another request.');
    const reject = grid.locator('.approvals-reject-button').first();
    const rejectionModal = page.locator('#entryRejectionModal');
    const rejectionNote = page.locator('#entryRejectionNote');
    const rejectionSubmit = page.locator('#entryRejectionSubmit');
    const requestCountAtOpen = requests.filter(r => r.path !== '/sync/status').length;
    await reject.click();
    await rejectionModal.waitFor();
    await page.waitForFunction(() => document.activeElement.id === 'entryRejectionNote');
    assert.match(await page.locator('#entryRejectionContext').textContent(), /Camille Tremblay.*17.*18/);
    await rejectionNote.fill('   ');
    assert(await rejectionSubmit.isDisabled());
    await rejectionNote.press('Escape');
    await rejectionModal.waitFor({ state: 'hidden' });
    assert.equal(requests.filter(r => r.path !== '/sync/status').length, requestCountAtOpen, 'Opening and cancelling the rejection dialog must make no request.');

    let submitted;
    await page.route('**/employee/approval/000000001', async route => {
      submitted = route.request().postDataJSON();
      await route.fulfill({ status: 200, json: { message: 'Saved' } });
    });
    await reject.click();
    await rejectionNote.fill('  Motif du superviseur.  ');
    assert.equal(await rejectionSubmit.textContent(), 'Rejeter l’entrée');
    await rejectionSubmit.click();
    await page.waitForSelector('#toastContainer .toast.show');
    assert.equal(submitted.status, 'rejected');
    assert.equal(submitted.message, 'Motif du superviseur.');
    assert(submitted.entryId);
    await page.waitForSelector('#pendingContainer .review-card');

    failReviewPage = true;
    await page.evaluate(() => loadReviewView());
    const pageError = page.locator('#pendingContainer .view-load-error');
    await pageError.waitFor();
    assert.match(await pageError.textContent(), /Impossible de charger les approbations/);
    assert(await page.locator('#approveFilteredBtn').isDisabled());
    assert.equal(await page.locator('#pendingContainer .loading-shell').count(), 0);
    const beforeRetry = requests.filter(r => r.path === '/review/bootstrap').length;
    failReviewPage = false;
    await pageError.getByRole('button', { name: 'Réessayer' }).click();
    await page.waitForSelector('#pendingContainer .review-card');
    assert.equal(requests.filter(r => r.path === '/review/bootstrap').length, beforeRetry + 1);

    let loseBatchResponse = false;
    let batchWrites = 0;
    await page.route('**/employee/approval/batch', async route => {
      batchWrites++;
      const { entries } = route.request().postDataJSON();
      assert(entries.length > 25, 'The test must include an entry from a page beyond the first one.');
      if (loseBatchResponse) {
        await route.abort('failed');
        return;
      }
      await route.fulfill({ status: 200, json: {
        outcome: 'partial', updatedCount: entries.length - 2, requestedCount: entries.length, failedCount: 2,
        failures: [
          { index: 0, reasonCode: 'already_in_status' },
          { index: 30, reasonCode: 'shared_data_unavailable', employeeName: '<img src=x>', message: '<img src=x>' },
        ],
      } });
    });
    const approve = page.locator('#approveFilteredBtn');
    const receipt = page.locator('#reviewBatchResult');
    const submitBatch = async () => {
      page.once('dialog', dialog => dialog.accept());
      await approve.click();
      await receipt.waitFor();
    };
    const beforePartial = requests.filter(r => r.path === '/review/bootstrap').length;
    await submitBatch();
    assert.match(await receipt.locator('h3').textContent(), /58 approuvées · 2 non traitées/);
    await receipt.locator('summary').click();
    const failures = receipt.locator('li');
    assert.equal(await failures.count(), 2);
    assert.match(await failures.first().textContent(), /Camille Tremblay.*déjà approuvée/);
    assert.match(await failures.last().textContent(), /Camille Tremblay.*dossier partagé est inaccessible/);
    assert.equal(await receipt.locator('img').count(), 0);
    await page.waitForFunction(() => !document.getElementById('approveFilteredBtn').disabled);
    assert.equal(requests.filter(r => r.path === '/review/bootstrap').length, beforePartial + 2, 'A batch uses one selection read and one active review refresh.');
    assert(!requests.some(r => r.path === '/dashboard/bootstrap' || r.path === '/employees/bootstrap' || r.path === '/projects/bootstrap'));
    await receipt.getByRole('button', { name: 'Fermer' }).click();

    loseBatchResponse = true;
    await submitBatch();
    assert.match(await receipt.locator('h3').textContent(), /n’a pas pu être vérifié/);
    assert(await approve.isDisabled());
    await receipt.getByRole('button', { name: 'Actualiser la liste' }).click();
    await page.waitForFunction(() => !document.getElementById('approveFilteredBtn').disabled);
    assert.match(await receipt.locator('h3').textContent(), /La liste est à jour/);
    assert.equal(batchWrites, 2, 'Refreshing after a lost response must never resubmit a batch.');
    assert(!requests.some(r => r.path.includes('history')));
    assert.deepEqual(errors, []);
    console.log('Review cards browser smoke passed: pagination, cards, permissions, error recovery and partial/unknown batch results.');
  } finally {
    await browser.close();
    await new Promise(resolve => server.close(resolve));
  }
})().catch(error => { console.error(error); server.close(); process.exitCode = 1; });
