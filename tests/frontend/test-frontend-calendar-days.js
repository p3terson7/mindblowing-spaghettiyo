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

class GuardedDate extends Date {
  constructor(...args) {
    if (args.length === 0) {
      throw new Error("Calendar days must not read the current clock.");
    }
    super(...args);
  }

  static now() {
    throw new Error("Calendar days must not read Date.now().");
  }
}

function legacyBuildMonth(entries, activeMonthKey, options) {
  const [activeYear, activeMonth] = String(activeMonthKey || "").split("-").map(Number);
  const firstDay = new GuardedDate(activeYear, activeMonth - 1, 1);
  const lastDay = new GuardedDate(activeYear, activeMonth, 0);
  const gridStart = new GuardedDate(firstDay);
  gridStart.setDate(firstDay.getDate() - firstDay.getDay());
  const gridEnd = new GuardedDate(lastDay);
  gridEnd.setDate(lastDay.getDate() + (6 - lastDay.getDay()));
  const groupedEntries = (entries || []).reduce((accumulator, entry) => {
    const dateKey = options.getEntryDate(entry);
    if (!accumulator[dateKey]) {
      accumulator[dateKey] = [];
    }
    accumulator[dateKey].push(entry);
    return accumulator;
  }, {});
  const days = [];
  const cursor = new GuardedDate(gridStart);

  while (cursor <= gridEnd) {
    const dateKey = `${cursor.getFullYear()}-${String(cursor.getMonth() + 1).padStart(2, "0")}-${String(cursor.getDate()).padStart(2, "0")}`;
    const dayEntries = options.orderDayEntries(groupedEntries[dateKey] || []);
    const totalSeconds = dayEntries.reduce((accumulator, entry) => accumulator + options.getDurationSeconds(entry), 0);
    days.push({
      dateKey,
      dayNumber: cursor.getDate(),
      isCurrentMonth: cursor.getMonth() === (activeMonth - 1),
      entries: dayEntries,
      totalSeconds,
    });
    cursor.setDate(cursor.getDate() + 1);
  }

  return { year: activeYear, month: activeMonth, days };
}

let forbiddenGlobalReads = 0;
const isolatedContext = {
  Array,
  Date: GuardedDate,
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
      throw new Error(`Calendar days must not read ${name}.`);
    },
  });
  Object.defineProperty(isolatedContext.window, name, {
    get() {
      forbiddenGlobalReads += 1;
      throw new Error(`Calendar days must not read window.${name}.`);
    },
  });
}

const calendarDayUtilitySource = sourceBetween(
  utilitiesSource,
  "(function initializeCalendarDayUtilities",
  "function toCalendarMonthKey",
);
vm.createContext(isolatedContext);
vm.runInContext(calendarDayUtilitySource, isolatedContext);

const calendarDays = isolatedContext.window.Saphir.calendarDays;
assert.equal(isolatedContext.window.Saphir.preservedNamespaceValue, "preserved", "The shared Saphir namespace must be preserved.");
assert.equal(Object.isFrozen(calendarDays), true, "The calendar-day API must expose a stable surface.");
assert.deepEqual(Object.keys(calendarDays), ["buildMonth"]);
assert.equal(forbiddenGlobalReads, 0, "Initializing the calendar-day API touched a browser side effect.");

const entries = Object.freeze([
  Object.freeze({ id: "previous", date: "2026-07-31", seconds: 300, order: 1 }),
  Object.freeze({ id: "morning", date: "2026-08-17", seconds: 1800, order: 1 }),
  Object.freeze({ id: "evening", date: "2026-08-17", seconds: 3600, order: 3 }),
  Object.freeze({ id: "afternoon", date: "2026-08-17", seconds: 900, order: 2 }),
  Object.freeze({ id: "next", date: "2026-09-01", seconds: 600, order: 1 }),
  Object.freeze({ id: "outside", date: "2027-01-01", seconds: 7200, order: 1 }),
]);
const employeeOptions = Object.freeze({
  getEntryDate(entry) {
    return entry.date;
  },
  getDurationSeconds(entry) {
    return entry.seconds;
  },
  orderDayEntries(dayEntries) {
    return dayEntries;
  },
});
const selfOptions = Object.freeze({
  ...employeeOptions,
  orderDayEntries(dayEntries) {
    return dayEntries.slice().sort((left, right) => right.order - left.order);
  },
});

for (const activeMonthKey of ["2026-02", "2024-02", "2026-08", "2026-12", "2026-03", "2026-11", "", "invalid-08", "2026-13"]) {
  for (const [label, source] of [
    ["null", null],
    ["zero", []],
    ["singleton", entries.slice(1, 2)],
    ["multiple", entries],
  ]) {
    for (const [orderLabel, options] of [["Self", selfOptions], ["Employees", employeeOptions]]) {
      const before = JSON.stringify(source);
      const expected = legacyBuildMonth(source, activeMonthKey, options);
      const first = calendarDays.buildMonth(source, activeMonthKey, options);
      const second = calendarDays.buildMonth(source, activeMonthKey, options);
      assert.deepEqual(plain(first), plain(expected), `${orderLabel} ${label} model for ${String(activeMonthKey)} changed from the golden implementation.`);
      assert.deepEqual(plain(second), plain(expected), `${orderLabel} ${label} model for ${String(activeMonthKey)} is not deterministic.`);
      assert.equal(JSON.stringify(source), before, `${orderLabel} ${label} model mutated its source entries.`);
    }
  }
}

const february2026 = calendarDays.buildMonth([], "2026-02", employeeOptions);
const leapFebruary = calendarDays.buildMonth([], "2024-02", employeeOptions);
const august2026 = calendarDays.buildMonth(entries, "2026-08", employeeOptions);
assert.equal(february2026.days.length, 28, "A Sunday-to-Saturday February 2026 must use 28 cells.");
assert.equal(leapFebruary.days.length, 35, "Leap-year February 2024 must use 35 cells.");
assert.equal(august2026.days.length, 42, "August 2026 must use a six-week calendar grid.");
assert.equal(august2026.days[0].dateKey, "2026-07-26");
assert.equal(august2026.days[41].dateKey, "2026-09-05");
assert.equal(august2026.days.filter(day => day.isCurrentMonth).length, 31);
assert.deepEqual(Object.keys(august2026).join(","), "year,month,days");
assert.equal(august2026.days.every(day => Object.keys(day).join(",") === "dateKey,dayNumber,isCurrentMonth,entries,totalSeconds"), true, "The canonical day shape changed.");

const august17Employee = august2026.days.find(day => day.dateKey === "2026-08-17");
assert.deepEqual(plain(august17Employee.entries.map(entry => entry.id)), ["morning", "evening", "afternoon"], "Employees must preserve source order within a day.");
assert.equal(august17Employee.entries[0], entries[1], "The day model must retain original entry references.");
assert.equal(august17Employee.totalSeconds, 6300);
assert.equal(august2026.days.find(day => day.dateKey === "2026-07-31").totalSeconds, 300, "Adjacent grid dates must retain entries if supplied.");
assert.equal(august2026.days.some(day => day.dateKey === "2027-01-01"), false, "Entries outside the visible grid must not create extra cells.");

const august17Self = calendarDays.buildMonth(entries, "2026-08", selfOptions).days.find(day => day.dateKey === "2026-08-17");
assert.deepEqual(plain(august17Self.entries.map(entry => entry.id)), ["evening", "afternoon", "morning"], "Self must retain its latest-first day ordering.");
assert.equal(august17Self.entries[0], entries[2], "Self ordering must retain original entry objects.");
assert.equal(august17Self.totalSeconds, 6300);

const tiedEntries = Object.freeze([
  Object.freeze({ id: "first", date: "2026-08-18", seconds: 1, order: 10 }),
  Object.freeze({ id: "second", date: "2026-08-18", seconds: 2, order: 10 }),
]);
const tiedDay = calendarDays.buildMonth(tiedEntries, "2026-08", selfOptions).days.find(day => day.dateKey === "2026-08-18");
assert.deepEqual(plain(tiedDay.entries.map(entry => entry.id)), ["first", "second"], "Equal sort values must keep stable source order.");

const december = calendarDays.buildMonth([], "2026-12", employeeOptions);
assert.equal(december.days[0].dateKey, "2026-11-29");
assert.equal(december.days[december.days.length - 1].dateKey, "2027-01-02");
for (const monthKey of ["2026-03", "2026-11"]) {
  const model = calendarDays.buildMonth([], monthKey, employeeOptions);
  assert.equal(new Set(model.days.map(day => day.dateKey)).size, model.days.length, `${monthKey} produced duplicate dates around a DST transition.`);
}
assert.equal(forbiddenGlobalReads, 0, "Pure calendar-day calculations touched the DOM, fetch, storage, or current clock.");

for (const adapterName of ["getEntryDate", "getDurationSeconds", "orderDayEntries"]) {
  const incomplete = { ...employeeOptions };
  delete incomplete[adapterName];
  assert.throws(() => calendarDays.buildMonth([], "2026-08", incomplete), new RegExp(adapterName));
}
assert.throws(() => calendarDays.buildMonth([], "2026-08", null), /getEntryDate/);
assert.throws(() => calendarDays.buildMonth({}, "2026-08", employeeOptions), /reduce is not a function/, "Truthy non-arrays must retain the legacy failure contract.");

const selfFacadeSource = sourceBetween(selfSource, "function buildSelfCalendarDays", "function getSelfActiveEntry");
const employeeFacadeSource = sourceBetween(employeesSource, "function buildEmployeeCalendarDays", "function setDashboardEmployeeContext");
const selfRenderSource = sourceBetween(selfSource, "function renderSelfEntries", "function renderSelfState");
const employeeRenderSource = sourceBetween(employeesSource, "function renderEmployeeDetail", "async function loadEmployeeDetail");

for (const [label, source] of [["Self", selfFacadeSource], ["Employees", employeeFacadeSource]]) {
  assert.match(source, /window\.Saphir\.calendarDays\.buildMonth\s*\(/, `${label} does not delegate to the shared day model.`);
  assert.doesNotMatch(source, /gridStart|gridEnd|while\s*\(|groupEntriesByDate/, `${label} facade still owns calendar geometry or grouping.`);
}
assert.match(selfRenderSource, /buildSelfCalendarDays\(monthEntries, activeMonthKey\)/);
assert.match(employeeRenderSource, /buildEmployeeCalendarDays\(monthEntries, activeMonthKey\)/);
for (const [label, source] of [["Self", selfRenderSource], ["Employees", employeeRenderSource]]) {
  assert.doesNotMatch(source, /gridStart|gridEnd|firstDayOfMonth|lastDayOfMonth|while\s*\([^)]*(?:cursor|rollingDate)/, `${label} render still duplicates calendar geometry.`);
  assert.match(source, /calendarMonth\.days\.forEach\s*\(/, `${label} no longer renders every canonical day.`);
  assert.match(source, /day\.dayNumber/, `${label} no longer renders the canonical day number.`);
  assert.match(source, /day\.totalSeconds/, `${label} no longer renders the canonical daily total.`);
}

function testFacadeDelegation(kind) {
  const isSelf = kind === "Self";
  const calls = [];
  const marker = { year: 2026, month: 8, days: [] };
  const sortCalls = [];
  const durationAdapter = entry => entry.seconds;
  const context = {
    getEntryDurationSeconds: durationAdapter,
    sortEntriesByDateTime(dayEntries, latestFirst) {
      sortCalls.push({ dayEntries, latestFirst });
      return dayEntries.slice().reverse();
    },
    window: {
      Saphir: {
        calendarDays: {
          buildMonth(...args) {
            calls.push(args);
            return marker;
          },
        },
      },
    },
  };
  vm.createContext(context);
  vm.runInContext(isSelf ? selfFacadeSource : employeeFacadeSource, context);

  const sourceEntries = [{ id: "a", date: "2026-08-17", seconds: 10 }, { id: "b", date: "2026-08-17", seconds: 20 }];
  const result = isSelf
    ? context.buildSelfCalendarDays(sourceEntries, "2026-08")
    : context.buildEmployeeCalendarDays(sourceEntries, "2026-08");
  assert.equal(result, marker);
  assert.equal(calls.length, 1);
  assert.equal(calls[0][0], sourceEntries);
  assert.equal(calls[0][1], "2026-08");
  const options = calls[0][2];
  assert.equal(options.getEntryDate(sourceEntries[0]), "2026-08-17");
  assert.equal(options.getDurationSeconds, durationAdapter);
  const dayEntries = sourceEntries.slice();
  const ordered = options.orderDayEntries(dayEntries);
  if (isSelf) {
    assert.deepEqual(plain(ordered.map(entry => entry.id)), ["b", "a"]);
    assert.equal(sortCalls.length, 1);
    assert.equal(sortCalls[0].dayEntries, dayEntries);
    assert.equal(sortCalls[0].latestFirst, true, "Self must retain latest-first ordering.");
  } else {
    assert.equal(ordered, dayEntries, "Employees must retain the exact grouped-array order.");
    assert.equal(sortCalls.length, 0, "Employees must not acquire Self's sorting behavior.");
  }
}

testFacadeDelegation("Self");
testFacadeDelegation("Employees");

console.log("Frontend calendar-day boundary contracts passed.");
