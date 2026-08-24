#!/usr/bin/env node

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const repoRoot = path.resolve(__dirname, "..", "..");
const read = relativePath => fs.readFileSync(path.join(repoRoot, relativePath), "utf8");
const utilitiesSource = read("app/frontend/scripts/Utilities.js");
const selfSource = read("app/frontend/scripts/Views/SelfView.js");
const dashboardSource = read("app/frontend/scripts/Views/DashboardView.js");
const employeesSource = read("app/frontend/scripts/Views/EmployeesView.js");
const projectsSource = read("app/frontend/scripts/Views/ProjectsView.js");

const fixedNow = "2026-08-17T14:30:00";
class FixedDate extends Date {
  constructor(...args) {
    super(...(args.length > 0 ? args : [fixedNow]));
  }

  static now() {
    return Date.parse(fixedNow);
  }
}

function createElement(id = "") {
  const attributes = new Map();
  const classes = new Set();
  return {
    id,
    value: "",
    innerHTML: "",
    innerText: "",
    textContent: "",
    disabled: false,
    checked: false,
    files: [],
    options: [],
    style: {
      setProperty() {},
      removeProperty() {},
    },
    classList: {
      add(...names) {
        names.forEach(name => classes.add(name));
      },
      remove(...names) {
        names.forEach(name => classes.delete(name));
      },
      toggle(name, force) {
        const enabled = force === undefined ? !classes.has(name) : Boolean(force);
        if (enabled) {
          classes.add(name);
        } else {
          classes.delete(name);
        }
        return enabled;
      },
      contains(name) {
        return classes.has(name);
      },
    },
    addEventListener() {},
    removeEventListener() {},
    appendChild() {},
    remove() {},
    focus() {},
    querySelector() {
      return null;
    },
    querySelectorAll() {
      return [];
    },
    closest() {
      return null;
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

function createBrowserContext() {
  const elements = new Map();
  const getElement = id => {
    if (!elements.has(id)) {
      elements.set(id, createElement(id));
    }
    return elements.get(id);
  };
  const localValues = new Map();
  const document = {
    documentElement: {
      getAttribute() {
        return "light";
      },
    },
    body: createElement("body"),
    getElementById: getElement,
    querySelector() {
      return null;
    },
    querySelectorAll() {
      return [];
    },
    createElement(tagName) {
      return createElement(tagName);
    },
    addEventListener() {},
  };
  const window = {
    getI18nLocale() {
      return "en-CA";
    },
    addEventListener() {},
    removeEventListener() {},
  };
  const context = {
    Array,
    Boolean,
    Date: FixedDate,
    Error,
    JSON,
    Map,
    Math,
    Number,
    Object,
    Promise,
    Set,
    String,
    TypeError,
    URL,
    WeakMap,
    clearTimeout,
    console,
    document,
    elements,
    getI18nLocale: window.getI18nLocale,
    localStorage: {
      getItem(key) {
        return localValues.has(key) ? localValues.get(key) : null;
      },
      setItem(key, value) {
        localValues.set(key, String(value));
      },
      removeItem(key) {
        localValues.delete(key);
      },
    },
    requestAnimationFrame(callback) {
      callback();
      return 1;
    },
    cancelAnimationFrame() {},
    setTimeout,
    t(key) {
      return key;
    },
    tn(key) {
      return key;
    },
    window,
  };
  window.document = document;
  window.localStorage = context.localStorage;
  window.window = window;
  return context;
}

function plain(value) {
  return JSON.parse(JSON.stringify(value));
}

function legacyMonthKey(dateValue) {
  const parsed = dateValue instanceof FixedDate
    ? dateValue
    : (() => {
      const parts = String(dateValue || "").split("-").map(Number);
      if (parts.length < 3 || parts.some(Number.isNaN)) {
        return null;
      }
      const date = new FixedDate(parts[0], parts[1] - 1, parts[2]);
      return Number.isNaN(date.getTime()) ? null : date;
    })();
  const date = parsed || new FixedDate();
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}`;
}

function legacyShiftMonthKey(monthKey, delta) {
  const [year, month] = String(monthKey || "").split("-").map(Number);
  const date = new FixedDate(
    Number.isNaN(year) ? new FixedDate().getFullYear() : year,
    Number.isNaN(month) ? new FixedDate().getMonth() : month - 1,
    1,
  );
  date.setMonth(date.getMonth() + delta);
  return legacyMonthKey(date);
}

function testSharedPrimitiveEquivalence() {
  const context = createBrowserContext();
  vm.createContext(context);
  vm.runInContext(`${utilitiesSource}\nthis.sharedPrimitives = {
    createEmptyState,
    toCalendarMonthKey,
    shiftCalendarMonthKey,
    formatCalendarMonthLabel,
    getCalendarWeekdayLabels,
    groupEntriesByDate,
    getEntryDurationSeconds,
  };`, context);
  const shared = context.sharedPrimitives;

  ["2026-08-17", "2025-12-01", "invalid", ""].forEach(value => {
    assert.equal(shared.toCalendarMonthKey(value), legacyMonthKey(value));
  });
  [
    ["2026-01", -1],
    ["2026-12", 1],
    ["2026-08", -12],
    ["2026-08", 12],
  ].forEach(([monthKey, delta]) => {
    assert.equal(shared.shiftCalendarMonthKey(monthKey, delta), legacyShiftMonthKey(monthKey, delta));
  });

  assert.equal(shared.formatCalendarMonthLabel("2026-08"), "August 2026");
  assert.deepEqual(plain(shared.getCalendarWeekdayLabels()), ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]);
  assert.deepEqual(plain(shared.groupEntriesByDate([
    { entryId: "a", date: "2026-08-17" },
    { entryId: "b", date: "2026-08-17" },
    { entryId: "c", date: "2026-08-18" },
  ])), {
    "2026-08-17": [
      { entryId: "a", date: "2026-08-17" },
      { entryId: "b", date: "2026-08-17" },
    ],
    "2026-08-18": [{ entryId: "c", date: "2026-08-18" }],
  });
  assert.deepEqual(plain(shared.groupEntriesByDate(null)), {});
  assert.equal(shared.getEntryDurationSeconds({ overtime: "01:02:03", punchIn: "09:00:00", punchOut: "10:02:03" }), 3723);
  assert.equal(shared.getEntryDurationSeconds({ date: "2026-08-17", punchIn: "12:00:00", punchOut: "" }), 9000);
  assert.equal(shared.createEmptyState("<A & B>"), '<div class="empty-state">&lt;A &amp; B&gt;</div>');
}

function testSelfRunsWithoutDashboard() {
  const context = createBrowserContext();
  vm.createContext(context);
  vm.runInContext(`${utilitiesSource}\n${selfSource}\nthis.selfTestApi = { renderSelfEntries };`, context);

  context.selfTestApi.renderSelfEntries([]);
  const rendered = context.elements.get("selfEntriesContainer").innerHTML;
  assert.match(rendered, /class="empty-state"/);
  assert.match(rendered, /employees\.noEntriesForMonth/);
}

function testProjectsRunWithoutDashboard() {
  const context = createBrowserContext();
  vm.createContext(context);
  vm.runInContext(`${utilitiesSource}\n${projectsSource}\nthis.projectTestApi = { renderProjectSummaryCards };`, context);

  context.projectTestApi.renderProjectSummaryCards([]);
  const rendered = context.elements.get("projectsSummaryContainer").innerHTML;
  assert.equal(rendered, '<div class="empty-state">projects.noStats</div>');
}

assert.doesNotMatch(dashboardSource, /function createEmptyState\s*\(/, "Dashboard still owns the shared empty-state renderer.");
assert.doesNotMatch(selfSource, /function (?:toSelfMonthKey|shiftSelfMonthKey|getSelfCalendarWeekdayLabels|groupSelfEntriesByDate|getSelfCalendarEntrySeconds)\s*\(/);
assert.doesNotMatch(employeesSource, /function (?:toMonthKey|shiftMonthKey|formatCalendarMonthLabel|getCalendarWeekdayLabels|groupEmployeeEntriesByDate|getEmployeeCalendarEntrySeconds)\s*\(/);

testSharedPrimitiveEquivalence();
testSelfRunsWithoutDashboard();
testProjectsRunWithoutDashboard();
console.log("Shared frontend primitive runtime contracts passed.");
