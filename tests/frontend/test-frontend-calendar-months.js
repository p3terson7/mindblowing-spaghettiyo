#!/usr/bin/env node

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const repoRoot = path.resolve(__dirname, "..", "..");
const read = relativePath => fs.readFileSync(path.join(repoRoot, relativePath), "utf8");
const utilitiesSource = read("app/frontend/scripts/Utilities.js");
const selfSource = read("app/frontend/scripts/Views/SelfView.js");
const employeesSource = read("app/frontend/scripts/Views/EmployeesView.js");

function sourceBetween(source, startMarker, endMarker) {
  const start = source.indexOf(startMarker);
  const end = source.indexOf(endMarker, start + startMarker.length);
  assert.notEqual(start, -1, `Unable to find ${startMarker}`);
  assert.notEqual(end, -1, `Unable to find ${endMarker}`);
  return source.slice(start, end).trim();
}

function plain(value) {
  return JSON.parse(JSON.stringify(value));
}

const fixedNow = "2026-08-17T14:30:00";
class FixedDate extends Date {
  constructor(...args) {
    super(...(args.length > 0 ? args : [fixedNow]));
  }

  static now() {
    return Date.parse(fixedNow);
  }
}

function parseLocalDate(value) {
  const parts = String(value || "").split("-").map(Number);
  if (parts.length < 3 || parts.some(Number.isNaN)) {
    return null;
  }
  const date = new FixedDate(parts[0], parts[1] - 1, parts[2]);
  return Number.isNaN(date.getTime()) ? null : date;
}

function toMonthKey(value) {
  const date = value instanceof FixedDate ? value : parseLocalDate(value);
  const resolved = date || new FixedDate();
  return `${resolved.getFullYear()}-${String(resolved.getMonth() + 1).padStart(2, "0")}`;
}

function legacyResolveActiveMonth(entries, selectedMonthKey, options) {
  if (selectedMonthKey) {
    return selectedMonthKey;
  }

  if (Array.isArray(entries) && entries.length > 0) {
    const latest = entries.slice().sort((left, right) => options.getTimestamp(right) - options.getTimestamp(left))[0];
    return options.toMonthKey(options.getEntryDate(latest));
  }

  return options.toMonthKey(options.referenceDate);
}

function legacyBuildYear(entries, activeMonthKey, options) {
  const [activeYear] = String(activeMonthKey || "").split("-").map(Number);
  const year = Number.isNaN(activeYear) ? options.referenceDate.getFullYear() : activeYear;
  const monthCounts = {};

  (entries || []).forEach(entry => {
    const monthKey = options.toMonthKey(options.getEntryDate(entry));
    if (!monthKey.startsWith(`${year}-`)) {
      return;
    }
    monthCounts[monthKey] = (monthCounts[monthKey] || 0) + 1;
  });

  return Array.from({ length: 12 }, (_, index) => {
    const monthDate = new FixedDate(year, index, 1);
    const monthKey = options.toMonthKey(monthDate);
    return {
      monthKey,
      label: options.formatMonthLabel(monthDate),
      count: monthCounts[monthKey] || 0,
      active: monthKey === activeMonthKey,
    };
  });
}

let forbiddenGlobalReads = 0;
const isolatedContext = {
  Array,
  Date: FixedDate,
  Number,
  Object,
  String,
  TypeError,
  window: {
    Saphir: {
      preservedNamespaceValue: "preserved",
    },
  },
};
for (const name of ["document", "fetch", "localStorage"]) {
  Object.defineProperty(isolatedContext, name, {
    get() {
      forbiddenGlobalReads += 1;
      throw new Error(`Calendar months must not read ${name}.`);
    },
  });
  Object.defineProperty(isolatedContext.window, name, {
    get() {
      forbiddenGlobalReads += 1;
      throw new Error(`Calendar months must not read window.${name}.`);
    },
  });
}

const calendarMonthUtilitySource = sourceBetween(
  utilitiesSource,
  "(function initializeCalendarMonthUtilities",
  "function toCalendarMonthKey",
);
vm.createContext(isolatedContext);
vm.runInContext(calendarMonthUtilitySource, isolatedContext);

const calendarMonths = isolatedContext.window.Saphir.calendarMonths;
assert.equal(isolatedContext.window.Saphir.preservedNamespaceValue, "preserved", "The shared Saphir namespace must be preserved.");
assert.equal(Object.isFrozen(calendarMonths), true, "The calendar-month API must expose a stable surface.");
assert.deepEqual(Object.keys(calendarMonths).sort(), ["buildYear", "resolveActiveMonth"]);
assert.equal(forbiddenGlobalReads, 0, "Initializing the calendar-month API touched a browser side effect.");

const referenceDate = new FixedDate();
const entries = Object.freeze([
  Object.freeze({ id: "old", date: "2025-12-31", punchIn: "23:00:00" }),
  Object.freeze({ id: "jan", date: "2026-01-01", punchIn: "08:00:00" }),
  Object.freeze({ id: "aug-a", date: "2026-08-05", punchIn: "07:00:00" }),
  Object.freeze({ id: "aug-b", date: "2026-08-17", punchIn: "12:00:00" }),
  Object.freeze({ id: "future", date: "2027-01-01", punchIn: "09:00:00" }),
]);
const selfOptions = Object.freeze({
  getTimestamp(entry) {
    return new FixedDate(`${entry.date}T${entry.punchIn || "00:00:00"}`).getTime();
  },
  getEntryDate(entry) {
    return entry.date;
  },
  toMonthKey,
  referenceDate,
});
const buildOptions = Object.freeze({
  getEntryDate(entry) {
    return entry.date;
  },
  toMonthKey,
  formatMonthLabel(date) {
    return `month-${date.getMonth() + 1}`;
  },
  referenceDate,
});

assert.equal(calendarMonths.resolveActiveMonth([], "2024-02", null), "2024-02", "A selected month must remain an exact short circuit.");
for (const [label, source] of [
  ["null", null],
  ["non-array", { date: "2024-01-01" }],
  ["zero", []],
  ["singleton", entries.slice(1, 2)],
  ["multiple", entries],
]) {
  const before = JSON.stringify(source);
  const expected = legacyResolveActiveMonth(source, "", selfOptions);
  assert.equal(calendarMonths.resolveActiveMonth(source, "", selfOptions), expected, `${label} active-month resolution changed.`);
  assert.equal(calendarMonths.resolveActiveMonth(source, "", selfOptions), expected, `${label} active-month resolution is not deterministic.`);
  assert.equal(JSON.stringify(source), before, `${label} active-month resolution mutated its entries.`);
}

const stableTieEntries = Object.freeze([
  Object.freeze({ date: "2026-01-03", timestamp: 10 }),
  Object.freeze({ date: "2026-02-03", timestamp: 10 }),
]);
const stableTieOptions = Object.freeze({
  ...selfOptions,
  getTimestamp(entry) {
    return entry.timestamp;
  },
});
assert.equal(calendarMonths.resolveActiveMonth(stableTieEntries, "", stableTieOptions), "2026-01", "Equal timestamps must preserve source order.");

for (const activeMonthKey of ["2026-08", "2025-12", "invalid-08", "", null, " 2026-08 "]) {
  for (const [label, source] of [["null", null], ["zero", []], ["singleton", entries.slice(2, 3)], ["multiple", entries]]) {
    const before = JSON.stringify(source);
    const expected = legacyBuildYear(source, activeMonthKey, buildOptions);
    const first = calendarMonths.buildYear(source, activeMonthKey, buildOptions);
    const second = calendarMonths.buildYear(source, activeMonthKey, buildOptions);
    assert.deepEqual(plain(first), expected, `${label} board for ${String(activeMonthKey)} changed from the golden implementation.`);
    assert.deepEqual(plain(second), expected, `${label} board for ${String(activeMonthKey)} is not deterministic.`);
    assert.equal(first.length, 12, "A yearly board must always expose twelve months.");
    assert.equal(JSON.stringify(source), before, `${label} board generation mutated its entries.`);
  }
}

const augustBoard = calendarMonths.buildYear(entries, "2026-08", buildOptions);
assert.deepEqual(plain(augustBoard[7]), { monthKey: "2026-08", label: "month-8", count: 2, active: true });
assert.equal(augustBoard[0].count, 1);
assert.equal(augustBoard.every(month => Object.keys(month).join(",") === "monthKey,label,count,active"), true, "The canonical board shape changed.");
assert.equal(forbiddenGlobalReads, 0, "Pure calendar-month calculations touched the DOM, fetch, or storage.");

for (const adapterName of ["toMonthKey", "getTimestamp", "getEntryDate"]) {
  const incomplete = { ...selfOptions };
  delete incomplete[adapterName];
  const source = adapterName === "toMonthKey" ? [] : entries.slice(0, 1);
  assert.throws(() => calendarMonths.resolveActiveMonth(source, "", incomplete), new RegExp(adapterName));
}
assert.throws(() => calendarMonths.resolveActiveMonth([], "", { ...selfOptions, referenceDate: null }), /valid reference date/);
for (const adapterName of ["toMonthKey", "getEntryDate", "formatMonthLabel"]) {
  const incomplete = { ...buildOptions };
  delete incomplete[adapterName];
  assert.throws(() => calendarMonths.buildYear([], "2026-08", incomplete), new RegExp(adapterName));
}
assert.throws(() => calendarMonths.buildYear([], "2026-08", { ...buildOptions, referenceDate: new FixedDate("invalid") }), /valid reference date/);

const selfDefaultSource = sourceBetween(selfSource, "function getDefaultSelfMonthKey", "function buildSelfMonthBoard");
const selfBoardSource = sourceBetween(selfSource, "function buildSelfMonthBoard", "function getSelfActiveEntry");
const employeeDefaultSource = sourceBetween(employeesSource, "function getDefaultEmployeeMonthKey", "function buildEmployeeInsightMarkup");
const employeeBoardSource = sourceBetween(employeesSource, "function buildEmployeeMonthBoard", "function setDashboardEmployeeContext");

for (const [label, source] of [
  ["Self default", selfDefaultSource],
  ["Employees default", employeeDefaultSource],
]) {
  assert.match(source, /window\.Saphir\.calendarMonths\.resolveActiveMonth\s*\(/, `${label} does not delegate to the shared resolver.`);
  assert.doesNotMatch(source, /\.sort\s*\(|sortEntriesByDateTime/, `${label} still owns the sorting loop.`);
}
for (const [label, source] of [
  ["Self board", selfBoardSource],
  ["Employees board", employeeBoardSource],
]) {
  assert.match(source, /window\.Saphir\.calendarMonths\.buildYear\s*\(/, `${label} does not delegate to the shared board builder.`);
  assert.doesNotMatch(source, /monthCounts|Array\.from\s*\(|\.forEach\s*\(/, `${label} still owns the month-counting loop.`);
}

function testFacadeDelegation(kind) {
  const isSelf = kind === "Self";
  const calls = { resolveActiveMonth: [], buildYear: [] };
  const canonicalBoard = [
    { monthKey: "2026-01", label: "Jan", count: 2, active: false },
    { monthKey: "2026-02", label: "Feb", count: 1, active: true },
  ];
  const marker = "resolved-month";
  const toMonthKeyMarker = value => `key:${String(value)}`;
  const context = {
    Date: FixedDate,
    selfViewState: { currentMonthKey: "self-selected" },
    employeesViewState: { currentMonthByEmployee: { E1: "employee-selected" } },
    toEntryDateTime(entry) {
      return { getTime: () => entry.selfTimestamp };
    },
    toCalendarMonthKey: toMonthKeyMarker,
    getCurrentLocale() {
      return "fr-CA";
    },
    window: {
      Saphir: {
        calendarMonths: {
          resolveActiveMonth(...args) {
            calls.resolveActiveMonth.push(args);
            return marker;
          },
          buildYear(...args) {
            calls.buildYear.push(args);
            return canonicalBoard;
          },
        },
      },
    },
  };
  vm.createContext(context);
  vm.runInContext([
    isSelf ? selfDefaultSource : employeeDefaultSource,
    isSelf ? selfBoardSource : employeeBoardSource,
  ].join("\n\n"), context);

  const sourceEntries = [{ date: "2026-02-03", selfTimestamp: 42 }];
  const defaultResult = isSelf
    ? context.getDefaultSelfMonthKey(sourceEntries)
    : context.getDefaultEmployeeMonthKey("E1", sourceEntries);
  assert.equal(defaultResult, marker);
  assert.equal(calls.resolveActiveMonth.length, 1);
  assert.equal(calls.resolveActiveMonth[0][0], sourceEntries);
  assert.equal(calls.resolveActiveMonth[0][1], isSelf ? "self-selected" : "employee-selected");
  const resolveOptions = calls.resolveActiveMonth[0][2];
  assert.equal(resolveOptions.getEntryDate(sourceEntries[0]), "2026-02-03");
  assert.equal(resolveOptions.toMonthKey, toMonthKeyMarker);
  assert.equal(resolveOptions.referenceDate.toISOString(), new FixedDate().toISOString());
  if (isSelf) {
    assert.equal(resolveOptions.getTimestamp(sourceEntries[0]), 42, "Self must retain its date-and-time timestamp adapter.");
  } else {
    assert.equal(resolveOptions.getTimestamp(sourceEntries[0]), new FixedDate("2026-02-03").getTime(), "Employees must retain its date-only timestamp adapter.");
  }

  const boardResult = isSelf
    ? context.buildSelfMonthBoard(sourceEntries, "2026-02")
    : context.buildEmployeeMonthBoard(sourceEntries, "2026-02");
  assert.equal(calls.buildYear.length, 1);
  assert.equal(calls.buildYear[0][0], sourceEntries);
  assert.equal(calls.buildYear[0][1], "2026-02");
  const boardOptions = calls.buildYear[0][2];
  assert.equal(boardOptions.getEntryDate(sourceEntries[0]), "2026-02-03");
  assert.equal(boardOptions.toMonthKey, toMonthKeyMarker);
  let localeCall = null;
  assert.equal(boardOptions.formatMonthLabel({
    toLocaleDateString(locale, options) {
      localeCall = { locale, options };
      return "févr.";
    },
  }), "févr.");
  assert.deepEqual(plain(localeCall), { locale: "fr-CA", options: { month: "short" } });

  if (isSelf) {
    assert.deepEqual(plain(boardResult), [
      { key: "2026-01", label: "Jan", count: 2, active: false },
      { key: "2026-02", label: "Feb", count: 1, active: true },
    ], "The Self facade must retain its historical key field.");
  } else {
    assert.equal(boardResult, canonicalBoard, "The Employees facade must retain the canonical monthKey array without reshaping it.");
  }
}

testFacadeDelegation("Self");
testFacadeDelegation("Employees");

console.log("Frontend calendar-month boundary contracts passed.");
