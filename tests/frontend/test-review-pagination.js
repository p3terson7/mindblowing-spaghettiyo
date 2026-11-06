const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, '../../app/frontend/scripts/Views/ApprovalsView.js'), 'utf8');
const elements = {};
function get(id) {
  if (!elements[id]) {
    const classes = new Set(id === 'pending-tab' ? ['active'] : []);
    elements[id] = { value: '', innerHTML: '', textContent: '', options: [], disabled: false,
      classList: { contains: x => classes.has(x), toggle: (x, on) => on ? classes.add(x) : classes.delete(x) },
      replaceChildren() { this.innerHTML = ''; }, setAttribute() {} };
  }
  return elements[id];
}
const requests = []; const rendered = []; const loading = [];
const payload = url => {
  const q = new URL(url, 'http://localhost').searchParams;
  const tab = q.get('tab'); const page = Number(q.get('page'));
  return { tab, page, pageSize: 25, total: 60, totalPages: 3, approvals: [{ entryId: tab + '-' + page }],
    counts: { pending: 60, approved: 3, rejected: 2, attention: 1 }, actionableCount: 60,
    employees: [{ employeeCode: '001', employeeName: 'A' }], projects: [],
    startDate: tab === 'approved' ? '2026-11-01' : '', endDate: tab === 'approved' ? '2026-11-30' : '' };
};
const context = {
  window: {}, document: { getElementById: get }, apiUrl: '/', URLSearchParams, Map, Object, Array, Number, String,
  clearTimeout, setTimeout, allApprovalEntries: [], approvalScopedProjects: [],
  buildApprovalEmployeeOptions: () => '', populateApprovalProjectFilter() {},
  updateApproveFilteredButtonState() {}, setLoadingState(id) { loading.push(id); },
  renderApprovalsList(id, items) { rendered.push([id, items[0]?.entryId]); },
  t: (key, values) => key + JSON.stringify(values || {}), escapeHtml: x => String(x),
  createEmptyState: x => x, showToast() {}, console: { error() {} }, parseResponse: x => x,
  async fetch(url) { requests.push(url); return payload(url); },
};
vm.createContext(context);
vm.runInContext(source.slice(source.indexOf('const REVIEW_TABS'), source.indexOf('const REVIEW_ISSUE_I18N_KEYS')), context);
function tab(name) { ['pending','approved','attention','rejected'].forEach(x => get(x + '-tab').classList.toggle('active', x === name)); }
(async () => {
  await context.loadReviewView();
  assert.equal(requests.length, 1); assert.match(requests[0], /tab=pending/);
  assert.deepEqual(loading, ['pendingContainer'], 'Hidden tabs must not get skeletons or entry markup.');
  assert.deepEqual(rendered[0], ['pendingContainer', 'pending-1']);
  assert.match(get('reviewPagination').innerHTML, /data-review-page="2"/);
  await context.fetchReviewPage({ page: 2 }); assert.equal(requests.length, 2);
  await context.fetchReviewPage({ page: 1 }); assert.equal(requests.length, 2, 'Back navigation did not reuse the page cache.');
  tab('approved'); await context.fetchReviewPage();
  assert.equal(get('reviewStartDate').value, '2026-11-01', 'Effective server dates must be visible.');
  tab('pending'); await context.fetchReviewPage(); assert.equal(requests.length, 3, 'Returning to a loaded tab fetched it again.');
  context.window.invalidateReviewWorkspace(); await context.fetchReviewPage(); assert.equal(requests.length, 4, 'Sync invalidation retained stale page data.');
  const deferred = [];
  context.fetch = url => new Promise(resolve => deferred.push({url, resolve}));
  get('approvalsSearchInput').value = 'old'; const old = context.fetchReviewPage();
  get('approvalsSearchInput').value = 'new'; const next = context.fetchReviewPage();
  deferred[1].resolve({...payload(deferred[1].url), approvals:[{entryId:'new'}]}); await next;
  deferred[0].resolve({...payload(deferred[0].url), approvals:[{entryId:'old'}]}); await old;
  assert.equal(rendered.at(-1)[1], 'new', 'A late filter response replaced the newest page.');
  get('approvalsSearchInput').value = 'logout'; const pending = context.fetchReviewPage();
  context.window.resetReviewWorkspace(); deferred[2].resolve(payload(deferred[2].url)); await pending;
  assert.equal(context.allApprovalEntries.length, 0, 'A late response repopulated Review after logout.');
  context.fetch = async () => { throw Error('offline'); };
  assert.equal(await context.loadReviewView(), false, 'Failed refresh did not report failure.');
  assert.match(source, /selectionOnly.*true/);
  assert.match(source, /filteredPendingEntries = Array.isArray\(selection.selection\)/, 'Bulk approval must use the full server-side selection, not the visible page.');
  console.log('Review paging UI passed: lazy tabs, pager, page reuse, effective dates, targeted invalidation, stale-response/logout guards, failure reporting and all-page bulk selection.');
})().catch(error => { console.error(error); process.exitCode = 1; });
