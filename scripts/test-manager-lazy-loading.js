#!/usr/bin/env node

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const repoRoot = path.resolve(__dirname, "..");
const frontendRoot = path.join(repoRoot, "apps/admin/frontend");
const indexPath = path.join(frontendRoot, "index.html");
const appShellPath = path.join(frontendRoot, "scripts/AppShell.js");
const indexSource = fs.readFileSync(indexPath, "utf8");
const appShellSource = fs.readFileSync(appShellPath, "utf8");

function sourceBetween(source, startMarker, endMarker) {
  const start = source.indexOf(startMarker);
  const end = source.indexOf(endMarker, start + startMarker.length);
  assert.notEqual(start, -1, `Unable to find ${startMarker}`);
  assert.notEqual(end, -1, `Unable to find ${endMarker}`);
  return source.slice(start, end).trim();
}

function withoutQuery(source) {
  return String(source || "").split("?")[0];
}

function scriptBytes(source) {
  return fs.statSync(path.join(frontendRoot, withoutQuery(source))).size;
}

const managerConstantSource = sourceBetween(appShellSource, "const MANAGER_VIEW_IDS", "function normalizeClientRole");
const constantContext = {};
vm.createContext(constantContext);
vm.runInContext(`${managerConstantSource}
this.managerViewIds = MANAGER_VIEW_IDS;
this.managerScriptSource = MANAGER_SCRIPT_SOURCE;
this.managerViewSources = MANAGER_VIEW_SCRIPT_SOURCES;`, constantContext);
const managerViewIds = Array.from(constantContext.managerViewIds);
const managerScriptSource = JSON.parse(JSON.stringify(constantContext.managerScriptSource));
const managerViewSources = JSON.parse(JSON.stringify(constantContext.managerViewSources));

assert.deepEqual(managerViewIds, ["dashboardView", "employeesView", "adminView", "projectsView"]);
assert.deepEqual(managerViewSources, {
  dashboardView: [managerScriptSource.dashboard],
  employeesView: [managerScriptSource.dashboard, managerScriptSource.chart, managerScriptSource.employees],
  adminView: [managerScriptSource.dashboard, managerScriptSource.approvals, managerScriptSource.history],
  projectsView: [managerScriptSource.dashboard, managerScriptSource.chart, managerScriptSource.projects],
});

const expectedUniqueManagerSources = [
  "assets/vendor/chart.umd.min.js",
  "scripts/Views/EmployeesView.js",
  "scripts/Views/DashboardView.js",
  "scripts/Views/ApprovalsView.js",
  "scripts/Views/HistoryView.js",
  "scripts/Views/ProjectsView.js",
];
assert.deepEqual(Object.values(managerScriptSource).map(withoutQuery), expectedUniqueManagerSources);

const staticSources = Array.from(indexSource.matchAll(/<script\s+[^>]*src="([^"]+)"[^>]*><\/script>/g), match => match[1]);
const expectedStaticSources = [
  "assets/vendor/bootstrap/bootstrap.bundle.min.js",
  "scripts/I18n.js",
  "scripts/Utilities.js",
  "scripts/AppShell.js",
  "scripts/Views/ViewSwitching.js",
  "scripts/Views/SelfView.js",
];
assert.deepEqual(staticSources.map(withoutQuery), expectedStaticSources, "core script dependency order changed");
Object.values(managerScriptSource).forEach(source => {
  assert.equal(staticSources.map(withoutQuery).includes(withoutQuery(source)), false, `${source} must not be eager`);
});
assert.match(appShellSource, /async function runViewRefresh\(viewId\) \{[\s\S]*?await ensureManagerAssetsForView\(viewId\);/, "view refresh must await its deferred assets");
assert.match(appShellSource, /\.catch\(error => \{\s*state\.stale = true;/, "failed view refreshes must remain stale for retry");
assert.match(appShellSource, /state\.stale = true;\s*if \(error && error\.isManagerAssetLoadError\) \{\s*return;/, "asset failures must be handled without an unhandled navigation rejection");

const loaderSource = [
  sourceBetween(appShellSource, "function loadScriptOnce", "function ensureManagerAssetsForView"),
  sourceBetween(appShellSource, "function ensureManagerAssetsForView", "function resetViewState"),
].join("\n\n");

function createScriptElement(baseURI) {
  const attributes = new Map();
  const listeners = {
    load: [],
    error: [],
  };
  let resolvedSource = "";

  return {
    async: true,
    parentNode: null,
    readyState: "",
    onload: null,
    onerror: null,
    get src() {
      return resolvedSource;
    },
    set src(value) {
      resolvedSource = new URL(value, baseURI).href;
    },
    getAttribute(name) {
      return attributes.get(name) || null;
    },
    setAttribute(name, value) {
      attributes.set(name, String(value));
    },
    addEventListener(type, listener, options = {}) {
      listeners[type].push({ listener, once: Boolean(options && options.once) });
    },
    dispatch(type) {
      const propertyHandler = type === "load" ? this.onload : this.onerror;
      if (typeof propertyHandler === "function") {
        propertyHandler.call(this);
      }
      const handlers = listeners[type].slice();
      listeners[type] = listeners[type].filter(item => !item.once);
      handlers.forEach(item => item.listener.call(this));
    },
  };
}

function createLoaderHarness(failures = {}) {
  const requestedSources = [];
  const evaluatedSources = [];
  const loadedScripts = [];
  const remainingFailures = { ...failures };
  const baseURI = "https://overtime.test/";
  const head = {
    appendChild(script) {
      script.parentNode = head;
      loadedScripts.push(script);
      const source = script.getAttribute("data-app-manager-script");
      requestedSources.push(source);
      queueMicrotask(() => {
        if (remainingFailures[source] > 0) {
          remainingFailures[source] -= 1;
          script.dispatch("error");
          return;
        }
        evaluatedSources.push(source);
        script.readyState = "complete";
        script.dispatch("load");
      });
      return script;
    },
    removeChild(script) {
      const index = loadedScripts.indexOf(script);
      if (index >= 0) {
        loadedScripts.splice(index, 1);
      }
      script.parentNode = null;
    },
  };
  const document = {
    baseURI,
    head,
    scripts: loadedScripts,
    createElement(tagName) {
      assert.equal(tagName, "script");
      return createScriptElement(baseURI);
    },
  };
  const context = {
    document,
    MANAGER_VIEW_IDS: managerViewIds,
    MANAGER_VIEW_SCRIPT_SOURCES: managerViewSources,
    appShellState: {
      scriptLoadPromises: {},
      managerAssetPromisesByView: {},
    },
    getCurrentUser: () => null,
    isManagerUser: user => Boolean(user && ["admin", "superAdmin"].includes(user.role)),
    URL,
    Promise,
    Error,
    Array,
  };
  vm.createContext(context);
  vm.runInContext(`${loaderSource}\nthis.lazyLoader = { loadScriptOnce, ensureManagerAssetsForView };`, context);

  return {
    context,
    document,
    requestedSources,
    evaluatedSources,
    loadedScripts,
  };
}

async function testPerViewLoading() {
  const harness = createLoaderHarness();
  const employee = { role: "employee", employeeCode: "100001" };
  const manager = { role: "admin", employeeCode: "100002" };

  await harness.context.lazyLoader.ensureManagerAssetsForView("selfView", employee);
  await harness.context.lazyLoader.ensureManagerAssetsForView("dashboardView", employee);
  await harness.context.lazyLoader.ensureManagerAssetsForView("selfView", manager);
  assert.deepEqual(harness.requestedSources, [], "employee/self startup must not request manager assets");

  const managerLoads = [
    harness.context.lazyLoader.ensureManagerAssetsForView("dashboardView", manager),
    harness.context.lazyLoader.ensureManagerAssetsForView("employeesView", manager),
    harness.context.lazyLoader.ensureManagerAssetsForView("adminView", manager),
    harness.context.lazyLoader.ensureManagerAssetsForView("projectsView", manager),
  ];
  const expectedDiscoveryOrder = [
    managerScriptSource.dashboard,
    managerScriptSource.chart,
    managerScriptSource.employees,
    managerScriptSource.approvals,
    managerScriptSource.history,
    managerScriptSource.projects,
  ];
  assert.deepEqual(harness.requestedSources, expectedDiscoveryOrder, "all required requests must be discovered before any load settles");
  assert.deepEqual(harness.evaluatedSources, [], "script evaluation should remain asynchronous");

  await Promise.all(managerLoads);
  assert.deepEqual(harness.evaluatedSources, expectedDiscoveryOrder, "classic scripts must evaluate in insertion order");
  assert.ok(harness.loadedScripts.every(script => script.async === false), "dynamic scripts must preserve ordered execution");
  assert.ok(harness.loadedScripts.every(script => script.getAttribute("data-app-manager-script-loaded") === "true"));

  await harness.context.lazyLoader.ensureManagerAssetsForView("projectsView", manager);
  await harness.context.lazyLoader.loadScriptOnce(managerScriptSource.dashboard);
  assert.equal(harness.requestedSources.length, expectedDiscoveryOrder.length, "loaded dependencies must not be requested twice");
}

async function testFailureAndRetry() {
  const manager = { role: "admin", employeeCode: "100002" };
  const harness = createLoaderHarness({
    [managerScriptSource.dashboard]: 1,
  });

  await assert.rejects(
    harness.context.lazyLoader.ensureManagerAssetsForView("dashboardView", manager),
    /Unable to load application script/,
  );
  assert.equal(harness.loadedScripts.length, 0, "failed managed script must be removed");
  assert.equal(harness.context.appShellState.managerAssetPromisesByView.dashboardView, undefined, "failed view promise must reset");

  await harness.context.lazyLoader.ensureManagerAssetsForView("dashboardView", manager);
  assert.deepEqual(harness.requestedSources, [managerScriptSource.dashboard, managerScriptSource.dashboard], "retry must request the failed script again");
  assert.equal(harness.loadedScripts.length, 1);

  const pendingHarness = createLoaderHarness();
  const existing = createScriptElement(pendingHarness.document.baseURI);
  existing.src = managerScriptSource.dashboard;
  existing.parentNode = pendingHarness.document.head;
  existing.setAttribute("data-app-manager-script", managerScriptSource.dashboard);
  pendingHarness.loadedScripts.push(existing);
  let resolved = false;
  const existingPromise = pendingHarness.context.lazyLoader.loadScriptOnce(managerScriptSource.dashboard).then(() => {
    resolved = true;
  });
  await Promise.resolve();
  assert.equal(resolved, false, "an existing managed script must not resolve before its load event");
  existing.dispatch("load");
  await existingPromise;
  assert.equal(resolved, true);
}

async function testSessionRetentionOnAssetFailure() {
  const sessionSource = [
    sourceBetween(appShellSource, "async function loadAuthenticatedWorkspace", "async function applySession"),
    sourceBetween(appShellSource, "async function applySession", "async function submitLogin"),
    sourceBetween(appShellSource, "async function restoreSession", "window.refreshActiveAppView"),
  ].join("\n\n");
  let storedSession = null;
  let clearSessionCount = 0;
  const toastMessages = [];
  const loggedErrors = [];
  const sessionContext = {
    apiUrl: "https://overtime.test/",
    appShellState: {
      initialized: false,
      lastSyncVersion: null,
      lastSyncChangeKey: null,
    },
    validateAuthenticatedUser(user) {
      user.role = user.role || "admin";
    },
    setStoredSession(session) {
      storedSession = session;
    },
    getStoredSession() {
      return storedSession;
    },
    clearStoredSession() {
      clearSessionCount += 1;
      storedSession = null;
    },
    resetViewState() {},
    clearClientLookupCaches() {},
    clearRoleUi() {},
    markAllowedViewsStale() {},
    updateSessionSummary() {},
    configureRoleUi() {},
    showAuthOverlay() {},
    hideAuthOverlay() {},
    setAuthMessage() {},
    setSyncStatus() {},
    t(key) {
      return key;
    },
    showToast(message) {
      toastMessages.push(message);
    },
    async bootstrapApplication() {
      sessionContext.appShellState.initialized = true;
      throw new Error("manager asset failed");
    },
    async refreshActiveView() {
      throw new Error("manager asset failed again");
    },
    async pollSyncState() {},
    async fetch() {
      return { ok: true };
    },
    async parseResponse() {
      return { role: "admin", username: "restored-manager" };
    },
    console: {
      error(...args) {
        loggedErrors.push(args);
      },
    },
  };
  vm.createContext(sessionContext);
  vm.runInContext(`${sessionSource}\nthis.sessionApi = { applySession, restoreSession };`, sessionContext);

  await sessionContext.sessionApi.applySession({
    token: "fresh-token",
    user: { role: "admin", username: "fresh-manager" },
  });
  assert.equal(storedSession.token, "fresh-token", "fresh session must survive a view asset failure");
  assert.equal(clearSessionCount, 0);

  storedSession = {
    token: "restored-token",
    user: { role: "admin", username: "cached-manager" },
  };
  await sessionContext.sessionApi.restoreSession();
  assert.ok(storedSession, `restored session was unexpectedly cleared: ${loggedErrors.map(args => args.join(" ")).join(" | ")}`);
  assert.equal(storedSession.token, "restored-token", "restored session must survive a view asset failure");
  assert.equal(clearSessionCount, 0, `view load failure must not enter the authentication failure cleanup path: ${loggedErrors.map(args => args.join(" ")).join(" | ")}`);
  assert.equal(toastMessages.length, 2, "both view failures should be reported to the user");
}

async function run() {
  await testPerViewLoading();
  await testFailureAndRetry();
  await testSessionRetentionOnAssetFailure();

  const staticBytes = staticSources.reduce((total, source) => total + scriptBytes(source), 0);
  const uniqueManagerBytes = Object.values(managerScriptSource).reduce((total, source) => total + scriptBytes(source), 0);
  const eagerBytes = staticBytes + uniqueManagerBytes;
  const viewBytes = Object.fromEntries(Object.entries(managerViewSources).map(([viewId, sources]) => [
    viewId,
    sources.reduce((total, source) => total + scriptBytes(source), 0),
  ]));
  const reductionPercent = eagerBytes > 0 ? (uniqueManagerBytes / eagerBytes) * 100 : 0;

  console.log("Manager lazy-loading test passed.");
  console.log(`Non-manager initial scripts: ${staticSources.length} requests / ${staticBytes} bytes (${(staticBytes / 1024).toFixed(1)} KiB).`);
  console.log(`First-use manager bytes: dashboard ${viewBytes.dashboardView}, employees ${viewBytes.employeesView}, review ${viewBytes.adminView}, projects ${viewBytes.projectsView}.`);
  console.log(`All deferred manager assets: ${uniqueManagerBytes} bytes; non-manager initial bytes reduced ${reductionPercent.toFixed(1)}% versus eager.`);
}

run().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
