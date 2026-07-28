#!/usr/bin/env node

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const repoRoot = path.resolve(__dirname, "..");
const utilitiesSource = fs.readFileSync(path.join(repoRoot, "apps/admin/frontend/scripts/Utilities.js"), "utf8");
const stylesSource = fs.readFileSync(path.join(repoRoot, "apps/admin/frontend/assets/styles.css"), "utf8");
const appShellSource = fs.readFileSync(path.join(repoRoot, "apps/admin/frontend/scripts/AppShell.js"), "utf8");
const selfViewSource = fs.readFileSync(path.join(repoRoot, "apps/admin/frontend/scripts/Views/SelfView.js"), "utf8");
const viewSwitchingSource = fs.readFileSync(path.join(repoRoot, "apps/admin/frontend/scripts/Views/ViewSwitching.js"), "utf8");
const managerViewSources = Object.fromEntries(
  ["DashboardView", "EmployeesView", "ApprovalsView", "HistoryView", "ProjectsView"].map(name => [
    name,
    fs.readFileSync(path.join(repoRoot, `apps/admin/frontend/scripts/Views/${name}.js`), "utf8"),
  ]),
);
const indexSource = fs.readFileSync(path.join(repoRoot, "apps/admin/frontend/index.html"), "utf8");
const helperStart = utilitiesSource.indexOf("const asyncButtonActions");
const helperEnd = utilitiesSource.indexOf("function timeRangeArrowIconMarkup", helperStart);
assert(helperStart >= 0 && helperEnd > helperStart, "Unable to locate the async button helper.");

const context = { Map, WeakMap, Promise, String, Boolean, TypeError };
vm.createContext(context);
vm.runInContext(`${utilitiesSource.slice(helperStart, helperEnd)}
this.buttonBusyApi = { runButtonAction };`, context);

function createButton(id, options = {}) {
  const attributes = new Map();
  const classes = new Set();
  if (options.ariaBusy != null) {
    attributes.set("aria-busy", String(options.ariaBusy));
  }
  if (options.ariaDisabled != null) {
    attributes.set("aria-disabled", String(options.ariaDisabled));
  }

  return {
    id,
    disabled: Boolean(options.disabled),
    textContent: options.textContent || "Save changes",
    classList: {
      add(name) {
        classes.add(name);
      },
      remove(name) {
        classes.delete(name);
      },
      contains(name) {
        return classes.has(name);
      },
    },
    getAttribute(name) {
      return attributes.has(name) ? attributes.get(name) : null;
    },
    setAttribute(name, value) {
      attributes.set(name, String(value));
    },
    removeAttribute(name) {
      attributes.delete(name);
    },
  };
}

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, resolve, reject };
}

async function testSuccessAndDuplicateSuppression() {
  const button = createButton("saveButton");
  const action = deferred();
  let actionCount = 0;
  const invoke = () => {
    actionCount += 1;
    return action.promise;
  };

  const first = context.buttonBusyApi.runButtonAction(button, invoke);
  const duplicate = context.buttonBusyApi.runButtonAction(button, invoke);

  assert.equal(button.disabled, true, "The active button must be disabled immediately.");
  assert.equal(button.getAttribute("aria-busy"), "true", "The active button must expose its busy state.");
  assert.equal(button.getAttribute("aria-disabled"), "true", "The active control must expose its disabled state.");
  assert.equal(button.classList.contains("is-async-busy"), true, "The spinner class is missing.");
  assert.equal(button.textContent, "Save changes", "The visible action label must remain intact.");

  await Promise.resolve();
  assert.equal(actionCount, 1, "A duplicate click started the backend action twice.");
  action.resolve("saved");
  assert.equal(await first, "saved");
  assert.equal(await duplicate, "saved");
  assert.equal(button.disabled, false, "The button was not restored after success.");
  assert.equal(button.getAttribute("aria-busy"), null, "The temporary aria-busy state was not removed.");
  assert.equal(button.getAttribute("aria-disabled"), null, "The temporary aria-disabled state was not removed.");
  assert.equal(button.classList.contains("is-async-busy"), false, "The spinner class was not removed.");
}

async function testFailureRestoresExistingState() {
  const button = createButton("disabledButton", { disabled: true, ariaBusy: "false", ariaDisabled: "false" });
  await assert.rejects(
    context.buttonBusyApi.runButtonAction(button, () => Promise.reject(new Error("failed"))),
    /failed/,
  );
  assert.equal(button.disabled, true, "A button disabled before the action must remain disabled.");
  assert.equal(button.getAttribute("aria-busy"), "false", "The original aria-busy value must be restored.");
  assert.equal(button.getAttribute("aria-disabled"), "false", "The original aria-disabled value must be restored.");
  assert.equal(button.classList.contains("is-async-busy"), false);
}

async function testRerenderedButtonSharesActionKey() {
  const originalButton = createButton("dynamicAction");
  const replacementButton = createButton("dynamicAction");
  const action = deferred();
  let actionCount = 0;
  const first = context.buttonBusyApi.runButtonAction(originalButton, () => {
    actionCount += 1;
    return action.promise;
  }, { key: "dynamic-save" });

  await Promise.resolve();
  const duplicate = context.buttonBusyApi.runButtonAction(replacementButton, () => {
    actionCount += 1;
    return Promise.resolve("duplicate");
  }, { key: "dynamic-save" });
  assert.equal(replacementButton.disabled, true, "A rerendered duplicate button must join the busy state.");
  assert.equal(actionCount, 1, "A rerendered button bypassed duplicate-action protection.");

  action.resolve("complete");
  assert.equal(await first, "complete");
  assert.equal(await duplicate, "complete");
  assert.equal(originalButton.disabled, false);
  assert.equal(replacementButton.disabled, false);
  assert.equal(originalButton.classList.contains("is-async-busy"), false);
  assert.equal(replacementButton.classList.contains("is-async-busy"), false);
}

async function testIntentionalDisabledResult() {
  const button = createButton("commitButton");
  await context.buttonBusyApi.runButtonAction(button, () => Promise.resolve(), {
    disabledAfter: true,
  });
  assert.equal(button.disabled, true, "An action must be able to intentionally leave its button disabled.");
  assert.equal(button.getAttribute("aria-busy"), null, "A disabled result is no longer busy after completion.");

  await context.buttonBusyApi.runButtonAction(button, () => Promise.resolve(), {
    disabledAfter: (_button, wasDisabled) => !wasDisabled,
  });
  assert.equal(button.disabled, false, "The disabledAfter callback did not control the final button state.");
}

async function testIndependentActionsShareButtonState() {
  const button = createButton("sharedButton");
  const firstAction = deferred();
  const secondAction = deferred();
  const first = context.buttonBusyApi.runButtonAction(button, () => firstAction.promise, { key: "first-action" });
  const second = context.buttonBusyApi.runButtonAction(button, () => secondAction.promise, { key: "second-action" });
  await Promise.resolve();

  firstAction.resolve("first");
  assert.equal(await first, "first");
  assert.equal(button.disabled, true, "The button was restored while another action still owned its busy state.");
  assert.equal(button.classList.contains("is-async-busy"), true);

  secondAction.resolve("second");
  assert.equal(await second, "second");
  assert.equal(button.disabled, false);
  assert.equal(button.classList.contains("is-async-busy"), false);
}

async function testRelatedControlsAreLockedWithoutExtraSpinners() {
  const button = createButton("editButton");
  const sibling = createButton("otherEditButton", { ariaDisabled: "false" });
  const previouslyDisabled = createButton("unavailableEditButton", { disabled: true });
  const action = deferred();
  const pending = context.buttonBusyApi.runButtonAction(button, () => action.promise, {
    key: "shared-editor",
    disableWhileRunning: [button, sibling, previouslyDisabled],
  });

  await Promise.resolve();
  assert.equal(sibling.disabled, true, "A competing editor opener must be disabled.");
  assert.equal(sibling.getAttribute("aria-disabled"), "true");
  assert.equal(sibling.classList.contains("is-async-busy"), false, "Only the clicked action should show a spinner.");
  action.resolve();
  await pending;
  assert.equal(sibling.disabled, false, "A competing opener was not restored.");
  assert.equal(sibling.getAttribute("aria-disabled"), "false", "A competing opener lost its original accessibility state.");
  assert.equal(previouslyDisabled.disabled, true, "A previously disabled competing opener must stay disabled.");
}

async function main() {
  await testSuccessAndDuplicateSuppression();
  await testFailureRestoresExistingState();
  await testRerenderedButtonSharesActionKey();
  await testIntentionalDisabledResult();
  await testIndependentActionsShareButtonState();
  await testRelatedControlsAreLockedWithoutExtraSpinners();

  assert.match(stylesSource, /button\.is-async-busy::before[\s\S]*?\{[\s\S]*?animation:\s*asyncButtonSpin/, "The busy button spinner is missing.");
  assert.match(stylesSource, /@media \(prefers-reduced-motion: reduce\)[\s\S]*?button\.is-async-busy::before[\s\S]*?\{[\s\S]*?animation:\s*none;/, "The spinner must respect reduced-motion preferences.");
  for (const actionKey of [
    "settings-health",
    "self-settings",
    "self-gc179-profile",
    "auth-login",
    "auth-password-change",
    "self-password-change",
    "auth-logout",
  ]) {
    assert(appShellSource.includes(`key: "${actionKey}"`), `AppShell action is not protected: ${actionKey}`);
  }
  assert(selfViewSource.includes('key: "self-punch"'), "Self-service punching is missing its busy action key.");
  assert(selfViewSource.includes("key: `self-gc179-export:${monthKey}`"), "Self-service GC179 export is missing its busy action key.");
  assert(viewSwitchingSource.includes("runButtonAction(navLink"), "View navigation is missing its busy state.");
  assert(viewSwitchingSource.includes('key: "view-navigation"'), "View navigation must share one action lock.");
  assert(viewSwitchingSource.includes('disableWhileRunning: () => document.querySelectorAll(".app-nav-link")'), "Competing navigation links must be disabled while a view loads.");
  for (const [name, source] of Object.entries(managerViewSources)) {
    assert(source.includes("runButtonAction("), `${name} has no protected backend action.`);
  }
  for (const asset of [
    "assets/styles.css?v=20260722-button-busy",
    "scripts/Utilities.js?v=20260722-button-busy",
    "scripts/AppShell.js?v=20260722-button-busy",
    "scripts/Views/ViewSwitching.js?v=20260722-button-busy",
    "scripts/Views/SelfView.js?v=20260722-button-busy",
  ]) {
    assert(indexSource.includes(asset), `The busy-state asset cache key was not updated: ${asset}`);
  }
  for (const managerView of Object.keys(managerViewSources)) {
    assert(
      appShellSource.includes(`scripts/Views/${managerView}.js?v=20260722-button-busy`),
      `The lazy manager asset cache key was not updated: ${managerView}`,
    );
  }
  console.log("Async button busy-state test passed.");
}

main().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
