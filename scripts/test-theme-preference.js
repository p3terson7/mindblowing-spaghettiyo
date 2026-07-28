const assert = require("assert");
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const repoRoot = path.resolve(__dirname, "..");
const source = fs.readFileSync(path.join(repoRoot, "apps/admin/frontend/scripts/AppShell.js"), "utf8");
const start = source.indexOf("function getStoredTheme");
const end = source.indexOf("const appShellState", start);
assert(start >= 0 && end > start, "Unable to locate AppShell theme functions.");

const storage = new Map();
const attributes = new Map();
const events = [];
const context = {
  APP_THEME_KEY: "saphirAppTheme",
  PRE_SAPHIR_THEME_KEY: "overtimeAppTheme",
  CustomEvent: class CustomEvent {
    constructor(type, options) {
      this.type = type;
      this.detail = options && options.detail;
    }
  },
  document: {
    documentElement: {
      setAttribute(name, value) {
        attributes.set(name, value);
      },
    },
    getElementById() {
      return null;
    },
    querySelectorAll() {
      return [];
    },
  },
  localStorage: {
    getItem(key) {
      return storage.has(key) ? storage.get(key) : null;
    },
    setItem(key, value) {
      storage.set(key, String(value));
    },
    removeItem(key) {
      storage.delete(key);
    },
  },
  t(key) {
    return key;
  },
  window: {
    dispatchEvent(event) {
      events.push(event);
    },
    matchMedia() {
      return { matches: true };
    },
  },
};

vm.createContext(context);
vm.runInContext(source.slice(start, end), context);

assert.strictEqual(context.getStoredTheme(), "system", "System should be the default theme preference.");
context.applyAppTheme("system");
assert.strictEqual(attributes.get("data-theme"), "dark", "System preference should resolve against the OS theme.");
assert.strictEqual(attributes.get("data-theme-mode"), "system", "The unresolved preference should remain available to UI controls.");
assert.strictEqual(storage.get("saphirAppTheme"), "system", "System preference should be persisted without flattening it.");
assert.deepStrictEqual(
  JSON.parse(JSON.stringify(events.at(-1).detail)),
  { theme: "dark", mode: "system" },
  "Theme change events should expose both the resolved theme and selected mode.",
);

context.applyAppTheme("light");
assert.strictEqual(attributes.get("data-theme"), "light");
assert.strictEqual(storage.get("saphirAppTheme"), "light");

storage.clear();
storage.set("overtimeAppTheme", "dark");
assert.strictEqual(context.getStoredTheme(), "dark", "A legacy theme preference should be migrated.");
assert.strictEqual(storage.get("saphirAppTheme"), "dark");
assert(!storage.has("overtimeAppTheme"));

console.log("Theme preference test passed.");
