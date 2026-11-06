const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const source = fs.readFileSync(path.join(__dirname, "../../app/frontend/scripts/AppShell.js"), "utf8").split("const APP_API_URL_KEY")[0];

async function harness(mode) {
  let ticks = 0;
  const listeners = {};
  let requests = 0;
  let originalResult = null;
  const window = {
    location: { search: mode ? `?saphirTrace=${mode}` : "", href: "http://localhost:8081/" },
    requestAnimationFrame(callback) { callback(); },
    fetch(resource, options) {
      requests++;
      assert.equal(options.body, "private-password-private-token");
      originalResult = { ok: true, status: 200, headers: { get: () => "a".repeat(32) }, text: async () => '{"privateSalary":123456789}' };
      return Promise.resolve(originalResult);
    },
    refreshDashboardView: async () => true,
    applyDashboardBootstrap: () => "unchanged-state-result",
    bootstrapApplication: async () => true,
    restoreSession: async () => true,
    submitLogin: async () => true,
  };
  const originalFetch = window.fetch;
  const context = { window, URLSearchParams, URL, Blob, setTimeout: callback => callback(), performance: { now: () => ++ticks, getEntriesByType: () => [{ startTime: 0, responseEnd: 2, domContentLoadedEventEnd: 3, loadEventEnd: 4, name: "private-corporate-url" }] }, document: {
    addEventListener(name, callback) { listeners[name] = callback; },
    body: { appendChild() {} },
    createElement() { return { style: {}, addEventListener() {}, click() {} }; },
  } };
  vm.createContext(context); vm.runInContext(source, context);
  if (!mode) {
    assert.equal(window.SaphirPerformance, undefined);
    assert.equal(window.fetch, originalFetch, "Disabled mode must not install a request proxy.");
    assert.equal(requests, 0);
    return;
  }
  listeners.DOMContentLoaded();
  window.SaphirPerformance.observeDashboard();
  const response = await window.fetch("http://localhost:8081/employee/123456789?token=secret", { method: "GET", body: "private-password-private-token" });
  assert.equal(response, originalResult, "Tracing must return the original Response object.");
  const text = await window.SaphirPerformance.readText(response);
  const body = window.SaphirPerformance.parseJson(text);
  assert.equal(body.privateSalary, 123456789);
  assert.equal(window.applyDashboardBootstrap(), "unchanged-state-result");
  assert.equal(await window.refreshDashboardView(), true);
  const exported = window.SaphirPerformance.export();
  assert(!/private-password|private-token|privateSalary|123456789|private-corporate-url|\?token/.test(exported));
  const events = exported.trim().split("\n").map(line => JSON.parse(line));
  assert(events.some(event => event.backendTraceId === "a".repeat(32)));
  assert(events.some(event => event.operation === "Browser.ParseJson" && event.durationMs > 0));
  assert(events.some(event => event.operation === "Dashboard.UsableAfterPaint" && event.event === "span_end"));
  assert.equal(requests, 1, "No diagnostic request may be introduced.");
  const usable = events.find(event => event.operation === "Dashboard.UsableAfterPaint");
  const dashboard = events.find(event => event.operation === "refreshDashboardView");
  assert.equal(usable.parentSpanId, dashboard.spanId);
}

(async () => {
  await harness(""); await harness("summary"); await harness("detailed");
  console.log("Browser performance tracing passed: opt-in, unchanged results, monotonic durations, correlation, local export, privacy and no telemetry requests.");
})().catch(error => { console.error(error); process.exitCode = 1; });
