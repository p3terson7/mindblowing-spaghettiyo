const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const read = name => fs.readFileSync(path.resolve(__dirname, '../../app/frontend/scripts/', name), 'utf8');
function section(source, from, to) { const start = source.indexOf(from); const end = source.indexOf(to, start); assert(start >= 0 && end > start); return source.slice(start, end); }
function element() {
  const classes = new Set(); const handlers = {};
  return { value: '', innerHTML: '', textContent: '', handlers, classList: { contains: key => classes.has(key), add: key => classes.add(key), toggle: (key, value) => value ? classes.add(key) : classes.delete(key) }, addEventListener: (name, fn) => { handlers[name] = fn; }, setAttribute() {}, replaceChildren() {} };
}
(async () => {
  const source = read('Views/HistoryView.js'); const nodes = new Map(); const requests = []; let activeTab = 'all-history-tab';
  const get = id => { if (!nodes.has(id)) nodes.set(id, element()); return nodes.get(id); };
  const context = { URLSearchParams, console, window: { clearTimeout, setTimeout },
    document: { getElementById: get, querySelector: () => ({ id: activeTab }) },
    t: (_, values) => String(values?.count || 0), setLoadingState() {}, showToast() {}, apiUrl: '/',
    parseResponse: x => x, runButtonAction: (_, fn) => fn(),
    fetch: async url => { requests.push(url); return { items: [], page: Number(new URL(url, 'http://localhost').searchParams.get('page')), totalPages: 7, total: 167, counts: { all: 167, add: 84 } }; },
  };
  vm.createContext(context); vm.runInContext(source, context);
  vm.runInContext('renderHistoryTabs = () => {}; setActiveHistoryLoadingState = () => {};', context);
  assert.equal(requests.length, 0, 'Loading history assets must not fetch history');
  get('historyWorkspace').classList.add('d-none');
  await get('loadHistoryBtn').handlers.click({ currentTarget: get('loadHistoryBtn') });
  assert.equal(requests.length, 1); assert(requests[0].includes('page=1'));
  await context.fetchHistory(1); assert.equal(requests.length, 1, 'Repeated open must reuse current page');
  await context.fetchHistory(2); assert(requests.at(-1).includes('page=2'));
  activeTab = 'add-history-tab'; await get('historyTabs').handlers['shown.bs.tab']({ target: { id: activeTab } });
  await new Promise(resolve => setImmediate(resolve));
  assert(requests.at(-1).includes('category=add') && requests.at(-1).includes('page=1'));
  context.window.invalidateReviewHistory(); await context.fetchHistory(1); assert.equal(requests.length, 4);
  context.window.resetReviewHistory(); assert(get('historyWorkspace').classList.contains('d-none'), 'Logout must clear optional history');

  const employees = read('Views/EmployeesView.js'); const employeeRequests = [];
  const state = { selectedEmployeeCode: '', selectedProjectCode: '', statisticsRequested: false, loadSequence: 0 };
  const scopeNode = { value: 'active' };
  const people = { employeesViewState: state, apiUrl: '/', console, setLoadingState() {}, setEmployeeAnalyticsLoadingState() {},
    document: { getElementById: id => id === 'employeesScopeSelect' ? scopeNode : element() },
    fetch: async url => { employeeRequests.push(url); return { employees: [{ code: '1', statsLoaded: false }], projects: [] }; },
    parseResponse: x => x, populateEmployeesProjectFilter() {}, filterEmployeesByScope: x => x, applyEmployeeSearchFilter() {}, showToast() {}, t: x => x,
  };
  vm.createContext(people); vm.runInContext(section(employees, 'function loadEmployeesView(', 'function getEmployeeByCode'), people);
  await people.loadEmployeesView(); assert.equal(employeeRequests[0], '/employees/bootstrap?scope=active');
  assert.equal(employeeRequests.length, 1, 'Initial directory must be one request, no details/lookups');
  scopeNode.value = 'archived'; state.statisticsRequested = true; await people.loadEmployeesView();
  assert.equal(employeeRequests[1], '/employees/bootstrap?scope=archived&includeStats=true');
  let detailRefreshes = 0; let directoryRefreshes = 0;
  const mutation = { employeesViewState: { statisticsRequested: false, selectedProjectCode: '' }, document: { getElementById: () => ({ value: '' }) },
    window: { invalidateEmployeesViewEntryCache() {} }, loadEmployeeDetail: async () => { detailRefreshes++; }, loadEmployeesView: async () => { directoryRefreshes++; }, console, showToast() {} };
  vm.createContext(mutation); vm.runInContext(section(employees, 'async function refreshPeopleEmployeeDetail(', 'window.refreshPeopleEmployeeDetail'), mutation);
  await mutation.refreshPeopleEmployeeDetail('1');
  assert.equal(detailRefreshes, 1); assert.equal(directoryRefreshes, 0, 'Entry edit must not reload all employee stats');
  mutation.employeesViewState.statisticsRequested = true;
  await mutation.refreshPeopleEmployeeDetail('1'); assert.equal(directoryRefreshes, 1, 'Visible stats must refresh after entry edit');
  assert(!read('Views/ApprovalsView.js').includes('payload && payload.history'), 'Review must not consume eager history');
  const shell = read('AppShell.js');
  const sync = { getCurrentUser: () => ({ role: 'admin' }), isManagerUser: () => true, userHasEmployeeWorkspace: () => false, window: { employeeDirectoryNeedsEntryRefresh: () => false } };
  vm.createContext(sync); vm.runInContext(section(shell, 'function getViewsAffectedBySyncState', 'function normalizeApiUrl'), sync);
  assert(!Array.from(sync.getViewsAffectedBySyncState({ category: 'history' })).includes('adminView'), 'History sync must not reload approvals');
  assert(!Array.from(sync.getViewsAffectedBySyncState({ category: 'employee', resource: '2' })).includes('employeesView'), 'Entry sync must not reload metadata-only directory');
  sync.window.employeeDirectoryNeedsEntryRefresh = () => true;
  assert(Array.from(sync.getViewsAffectedBySyncState({ category: 'employee', resource: '2' })).includes('employeesView'), 'Visible analytics must still refresh');
  console.log('Lazy view architecture: server pages, navigation reuse, optional stats, session reset and targeted sync passed.');
})().catch(error => { console.error(error); process.exitCode = 1; });
