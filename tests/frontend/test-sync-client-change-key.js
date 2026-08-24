#!/usr/bin/env node

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const repoRoot = path.resolve(__dirname, "..", "..");

function readSource(relativePath) {
  return fs.readFileSync(path.join(repoRoot, relativePath), "utf8");
}

function getFunctionSource(source, functionName, nextMarker) {
  const functionStart = source.indexOf(`function ${functionName}`);
  const start = source.slice(Math.max(0, functionStart - 6), functionStart) === "async "
    ? functionStart - 6
    : functionStart;
  const end = source.indexOf(nextMarker, start);
  assert.notEqual(functionStart, -1, `Unable to find ${functionName}`);
  assert.notEqual(end, -1, `Unable to find end marker for ${functionName}`);
  return source.slice(start, end);
}

function loadChangeKey(relativePath, functionName, nextMarker) {
  const source = readSource(relativePath);
  const context = {};
  vm.createContext(context);
  vm.runInContext(
    `${getFunctionSource(source, functionName, nextMarker)}\nthis.changeKey = ${functionName};`,
    context
  );
  return context.changeKey;
}

function createUnifiedPollHarness({
  username = "manager",
  role = "admin",
  lastSyncVersion = 5,
  lastSyncChangeKey = "id:initial",
} = {}) {
  const source = readSource("app/frontend/scripts/AppShell.js");
  const state = {
    syncRequestInFlight: false,
    lastSyncVersion,
    lastSyncChangeKey,
  };
  const currentUser = { username, role };
  const calls = {
    handledStates: [],
    targetedStates: [],
    targetedStaleViews: [],
    allStaleUsers: [],
    refreshes: 0,
    errors: [],
  };
  let syncState = null;
  let failNextRefresh = false;

  const context = {
    appShellState: state,
    apiUrl: "http://localhost/api/",
    document: { hidden: false },
    window: {
      handleSyncStateChange(value) {
        calls.handledStates.push(value);
      },
    },
    console: {
      error(...args) {
        calls.errors.push(args);
      },
    },
    getSessionToken: () => "token",
    fetch: async () => ({}),
    parseResponse: async () => syncState,
    setLastSyncStatus: () => {},
    setSyncStatus: () => {},
    t: key => key,
    getCurrentUser: () => currentUser,
    getViewsAffectedBySyncState(value) {
      calls.targetedStates.push(value);
      return ["targetedView"];
    },
    markViewsStale(viewIds) {
      calls.targetedStaleViews.push(Array.from(viewIds));
    },
    markAllowedViewsStale(user) {
      calls.allStaleUsers.push(user);
    },
    async refreshActiveView() {
      calls.refreshes += 1;
      if (failNextRefresh) {
        failNextRefresh = false;
        throw new Error("synthetic refresh failure");
      }
    },
    scheduleNextSyncPoll: () => {},
  };

  vm.createContext(context);
  vm.runInContext([
    getFunctionSource(source, "getSyncStateChangeKey", "function getStoredTheme"),
    getFunctionSource(source, "pollSyncState", "async function bootstrapApplication"),
    "this.poll = pollSyncState;",
  ].join("\n"), context);

  return {
    calls,
    state,
    poll: context.poll,
    setHidden(value) {
      context.document.hidden = value;
    },
    setSyncState(value) {
      syncState = value;
    },
    failNextRefresh() {
      failNextRefresh = true;
    },
  };
}

const changeKeys = [
  loadChangeKey("app/frontend/scripts/AppShell.js", "getSyncStateChangeKey", "function getStoredTheme"),
];

for (const changeKey of changeKeys) {
  assert.equal(
    changeKey({ version: 9, changeId: "abc", updatedAtUtc: "ignored" }),
    "id:abc",
    "New sync states should use their durable change ID"
  );

  const beforeReset = changeKey({
    version: 65,
    updatedAtUtc: "2026-07-13T10:00:00Z",
    category: "employee",
    resource: "000000001",
  });
  const afterReset = changeKey({
    version: 1,
    updatedAtUtc: "2026-07-13T10:01:00Z",
    category: "seed",
    resource: "reset-sample-data",
  });
  assert.notEqual(beforeReset, afterReset, "Legacy version resets must still trigger refresh");

  const sameVersionDifferentTimestamp = changeKey({
    version: 1,
    updatedAtUtc: "2026-07-13T10:02:00Z",
    category: "seed",
    resource: "reset-sample-data",
  });
  assert.notEqual(afterReset, sameVersionDifferentTimestamp, "Equal legacy versions must use the remaining event identity");
}

async function testAdminGapRouting() {
  const harness = createUnifiedPollHarness();
  harness.setSyncState({
    version: 7,
    changeId: "skipped-event",
    updatedAtUtc: "2026-07-13T10:03:00Z",
    category: "employee",
    resource: "000000001",
  });

  await harness.poll();

  assert.equal(harness.calls.handledStates.length, 1);
  assert.equal(harness.calls.handledStates[0].category, "seed", "Skipped revisions must use full invalidation routing");
  assert.equal(harness.calls.handledStates[0].resource, "sync-gap");
  assert.equal(harness.calls.handledStates[0].version, 7, "Gap routing must preserve revision metadata");
  assert.equal(harness.calls.handledStates[0].changeId, "skipped-event");
  assert.equal(harness.calls.allStaleUsers.length, 1, "Skipped revisions must mark every allowed view stale");
  assert.equal(harness.calls.targetedStates.length, 0, "Skipped revisions must not use category targeting");
  assert.equal(harness.calls.refreshes, 1, "Skipped revisions must refresh the active view");
  assert.equal(harness.state.lastSyncVersion, 7);
  assert.equal(harness.state.lastSyncChangeKey, "id:skipped-event");

  harness.setSyncState({
    version: 8,
    changeId: "sequential-event",
    category: "history",
    resource: "history.json",
  });
  await harness.poll();

  assert.equal(harness.calls.handledStates[1].category, "history", "An exact +1 revision may use category targeting");
  assert.equal(harness.calls.targetedStates.length, 1);
  assert.deepEqual(harness.calls.targetedStaleViews[0], ["targetedView"]);
  assert.equal(harness.calls.allStaleUsers.length, 1);

  harness.setSyncState({
    version: 8,
    changeId: "same-version-new-event",
    category: "project",
    resource: "P-1",
  });
  await harness.poll();
  assert.equal(harness.calls.handledStates[2].category, "seed", "A new change ID at the same revision is a sync gap");
  assert.equal(harness.calls.targetedStates.length, 1);
  assert.equal(harness.calls.allStaleUsers.length, 2);

  harness.setSyncState({
    version: 2,
    changeId: "rollback-event",
    category: "employee",
    resource: "000000001",
  });
  await harness.poll();
  assert.equal(harness.calls.handledStates[3].resource, "sync-gap", "Revision rollback must use full invalidation routing");
  assert.equal(harness.calls.targetedStates.length, 1);
  assert.equal(harness.calls.allStaleUsers.length, 3);
}

async function testAdminRefreshRetry() {
  const harness = createUnifiedPollHarness();
  harness.setSyncState({
    version: 6,
    changeId: "retry-event",
    category: "history",
    resource: "history.json",
  });
  harness.failNextRefresh();

  await harness.poll();
  assert.equal(harness.state.lastSyncVersion, 5, "A failed admin refresh must retain the previous revision");
  assert.equal(harness.state.lastSyncChangeKey, "id:initial", "A failed admin refresh must retain the previous change key");

  await harness.poll();
  assert.equal(harness.calls.refreshes, 2, "The unchanged server event must retry after a failed admin refresh");
  assert.equal(harness.calls.handledStates.length, 2, "Retry must repeat cache invalidation before refreshing");
  assert.equal(harness.state.lastSyncVersion, 6);
  assert.equal(harness.state.lastSyncChangeKey, "id:retry-event");
}

async function testAdminHiddenCursorCommit() {
  const harness = createUnifiedPollHarness();
  harness.setHidden(true);
  harness.setSyncState({
    version: 9,
    changeId: "hidden-gap",
    category: "employee",
    resource: "000000001",
  });

  await harness.poll();
  assert.equal(harness.calls.allStaleUsers.length, 1, "Hidden polling must record full staleness before advancing");
  assert.equal(harness.calls.refreshes, 0, "Hidden polling defers the active-view refresh");
  assert.equal(harness.state.lastSyncVersion, 9);
  assert.equal(harness.state.lastSyncChangeKey, "id:hidden-gap");
}

async function testUnifiedEmployeeRefreshRetry() {
  const harness = createUnifiedPollHarness({
    username: "employee",
    role: "employee",
    lastSyncVersion: 30,
    lastSyncChangeKey: "id:employee-initial",
  });
  harness.setSyncState({
    version: 32,
    changeId: "employee-retry-event",
    category: "employee",
    resource: "000000001",
  });
  harness.failNextRefresh();

  await harness.poll();
  assert.equal(harness.state.lastSyncVersion, 30, "A failed unified employee refresh must retain the previous revision");
  assert.equal(harness.state.lastSyncChangeKey, "id:employee-initial");
  assert.equal(harness.calls.allStaleUsers.length, 1, "A sync gap must invalidate every view allowed for the employee session");
  assert.equal(harness.calls.allStaleUsers[0].role, "employee");

  await harness.poll();
  assert.equal(harness.calls.refreshes, 2, "The unified client must retry an unchanged event for an employee session");
  assert.equal(harness.calls.allStaleUsers.length, 2, "The retry must repeat the conservative employee-view invalidation");
  assert.equal(harness.state.lastSyncVersion, 32);
  assert.equal(harness.state.lastSyncChangeKey, "id:employee-retry-event");
}

Promise.resolve()
  .then(testAdminGapRouting)
  .then(testAdminRefreshRetry)
  .then(testAdminHiddenCursorCommit)
  .then(testUnifiedEmployeeRefreshRetry)
  .then(() => {
    console.log("Unified client sync test passed: gap routing is conservative and failed refreshes retry for every role.");
  })
  .catch(error => {
    console.error(error);
    process.exitCode = 1;
  });
