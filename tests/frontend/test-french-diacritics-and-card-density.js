const assert = require("assert");
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const repoRoot = path.resolve(__dirname, "..", "..");
const read = relativePath => fs.readFileSync(path.join(repoRoot, relativePath), "utf8");

const utilitiesSource = read("app/frontend/scripts/Utilities.js");
const i18nSource = read("app/frontend/scripts/I18n.js");
const indexSource = read("app/frontend/index.html");
const cssSource = read("app/frontend/assets/apple-ui.css");
const baseCssSource = read("app/frontend/assets/styles.css");
const employeesViewSource = read("app/frontend/scripts/Views/EmployeesView.js");

const helperStart = utilitiesSource.indexOf("const FRENCH_LOOKUP_LABEL_CORRECTIONS");
const helperEnd = utilitiesSource.indexOf("function buildCodeOptions", helperStart);
assert(helperStart >= 0 && helperEnd > helperStart, "Unable to locate the French lookup-label compatibility helpers.");

const localeState = { value: "fr-CA" };
const context = {
  getCurrentLocale: () => localeState.value,
};
vm.createContext(context);
vm.runInContext(`${utilitiesSource.slice(helperStart, helperEnd)}
this.restoreFrenchLookupDiacritics = restoreFrenchLookupDiacritics;
this.getLocalizedOptionLabel = getLocalizedOptionLabel;`, context);

const legacyFrenchLabels = new Map([
  ["Code de temps supplementaire", "Code de temps supplémentaire"],
  ["HEURES SUPPLEMENTAIRES, Jour ouvrable regulier", "HEURES SUPPLÉMENTAIRES, Jour ouvrable régulier"],
  ["HEURES SUPPLEMENTAIRES, Deuxieme jour de repos subsequent", "HEURES SUPPLÉMENTAIRES, Deuxième jour de repos subséquent"],
  ["HEURES SUPPLEMENTAIRES, Conge ferie", "HEURES SUPPLÉMENTAIRES, Congé férié"],
  ["TEMPS de DEPLACEMENT, Jour ouvrable regulier", "TEMPS de DÉPLACEMENT, Jour ouvrable régulier"],
  ["INDEMNITE DE PRESENCE", "INDEMNITÉ DE PRÉSENCE"],
  ["TEMPS PARTIEL, Prime pour le travail effectue lors d'un jour ferie", "TEMPS PARTIEL, Prime pour le travail effectué lors d'un jour férié"],
  ["En espece", "En espèce"],
  ["Conge", "Congé"],
  ["Cout-efficacite", "Coût-efficacité"],
  ["Absence imprevue", "Absence imprévue"],
]);

for (const [legacyLabel, correctedLabel] of legacyFrenchLabels) {
  assert.strictEqual(
    context.getLocalizedOptionLabel({ labelFr: legacyLabel, labelEn: "English fallback" }),
    correctedLabel,
    `Legacy French label was not corrected: ${legacyLabel}`,
  );
}

assert.strictEqual(
  context.getLocalizedOptionLabel({ labelFr: "Libellé personnalisé", labelEn: "Custom label" }),
  "Libellé personnalisé",
  "Custom French labels must remain untouched.",
);
localeState.value = "en-CA";
assert.strictEqual(
  context.getLocalizedOptionLabel({ labelFr: "En espece", labelEn: "Cash" }),
  "Cash",
  "The French compatibility layer must not affect English labels.",
);

const catalogueSources = [
  read("data/overtimeCodes.json"),
  read("data/paymentOptions.json"),
  read("data/reasonCodes.json"),
];
for (const expectedText of [
  "HEURES SUPPLÉMENTAIRES",
  "DÉPLACEMENT",
  "INDEMNITÉ DE PRÉSENCE",
  "En espèce",
  "Congé",
  "Coût-efficacité",
  "Absence imprévue",
]) {
  assert(catalogueSources.some(source => source.includes(expectedText)), `The checked-in catalogues are missing: ${expectedText}`);
}

const seedBytes = fs.readFileSync(path.join(repoRoot, "scripts/seed-presentation-data.ps1"));
assert.deepStrictEqual(Array.from(seedBytes.subarray(0, 3)), [0xef, 0xbb, 0xbf], "The Windows presentation seed must keep its UTF-8 BOM.");

for (const [name, source] of Object.entries({ indexSource, i18nSource, utilitiesSource })) {
  assert(!/[ÃÂ][\u0080-\u00bf]?/.test(source), `${name} contains likely UTF-8 mojibake.`);
}

assert.match(cssSource, /\.employee-directory-section-grid\s*\{[\s\S]*?minmax\(min\(100%, 272px\), 1fr\)/, "Employee directory cards do not keep a readable responsive width.");
assert.match(cssSource, /\.employee-card\s*\{[\s\S]*?grid-template-rows:\s*none;[\s\S]*?margin-bottom:\s*0;/, "Employee cards still reserve an empty row or external space.");
assert.match(baseCssSource, /\.employee-project-bubble-row\.is-compact\s*\{[\s\S]*?grid-template-columns:\s*repeat\(2, minmax\(0, 1fr\)\);[\s\S]*?max-height:\s*none;[\s\S]*?overflow:\s*hidden;/, "Employee project pills can still clip or introduce a nested scrollbar.");
assert.match(cssSource, /\.employee-card \.project-identity-pill\s*\{[\s\S]*?background:\s*var\(--surface\);[\s\S]*?border-color:\s*var\(--separator\);/, "Employee project pills do not share one neutral surface and outline.");
assert.match(cssSource, /\.employee-card \.project-identity-pill\.is-backup\s*\{[\s\S]*?border-style:\s*dashed;/, "Backup project pills need a non-fill distinction.");
assert.match(cssSource, /\.project-summary-card\s*\{[\s\S]*?min-height:\s*0;[\s\S]*?padding:\s*12px;/, "Project cards still enforce the old oversized minimum height.");
assert.match(cssSource, /\.project-summary-card\s*\{[\s\S]*?border-inline-start-width:\s*1px;/, "Project cards still use an oversized colored edge.");
assert.match(cssSource, /\.project-summary-card \.project-card-assignments\s*\{[\s\S]*?grid-template-columns:\s*repeat\(2, minmax\(0, 1fr\)\)/, "Project assignments are not compacted into two readable columns.");

const employeeLoadingStart = utilitiesSource.indexOf('if (variant === "employeeBarChart")');
const genericChartLoadingStart = utilitiesSource.indexOf('if (variant === "chart")', employeeLoadingStart);
assert(employeeLoadingStart >= 0 && genericChartLoadingStart > employeeLoadingStart, "The dedicated employee bar-chart loading state is missing.");
const employeeLoadingMarkup = utilitiesSource.slice(employeeLoadingStart, genericChartLoadingStart);
assert(!employeeLoadingMarkup.includes("loading-bar-chart"), "Employee analytics still uses the generic chart loading block.");
assert.strictEqual((employeeLoadingMarkup.match(/loading-employee-bar-row/g) || []).length, 5, "Employee analytics must render five compact loading bars.");
assert.match(employeesViewSource, /setEmployeeAnalyticsLoadingState\(\)[\s\S]*?createLoadingState\("employeeBarChart",\s*1\)/, "Employee analytics does not request its dedicated compact loading state.");
assert.doesNotMatch(employeesViewSource, /setEmployeeAnalyticsLoadingState\(\)[\s\S]*?createLoadingState\("chart",\s*1\)/, "Employee analytics still requests the oversized generic chart loader.");

assert.match(baseCssSource, /\.loading-shell-chart\s*\{[\s\S]*?max-width:\s*100%;[\s\S]*?height:\s*100%;[\s\S]*?min-height:\s*0;[\s\S]*?overflow:\s*hidden;/, "Generic chart loading shells are not constrained to their host.");
assert.match(baseCssSource, /\.loading-chart\s*\{[\s\S]*?grid-template-rows:\s*auto minmax\(0, 1fr\);[\s\S]*?min-height:\s*0;[\s\S]*?overflow:\s*hidden;/, "Generic chart loading content can still exceed a fixed-height host.");
assert.match(baseCssSource, /\.loading-bar-chart\s*\{[\s\S]*?height:\s*100%;[\s\S]*?min-height:\s*0;/, "The generic chart loading bar does not inherit its host height.");
assert.doesNotMatch(baseCssSource, /\.loading-bar-chart\s*\{[^}]*height:\s*320px;/, "The generic chart loader still has the unsafe fixed 320px height.");
assert.match(baseCssSource, /\.loading-employee-bar-chart\s*\{[\s\S]*?gap:\s*14px;[\s\S]*?overflow:\s*hidden;/, "The employee chart loading rows are not compact and contained.");
assert.match(baseCssSource, /\.loading-employee-bar-label,[\s\S]*?\.loading-employee-bar-value\s*\{[\s\S]*?height:\s*10px;[\s\S]*?border-radius:\s*3px;/, "Employee loading bars are not slim, non-pill rows.");
assert.match(baseCssSource, /\.employee-analytics-card\s*\{[\s\S]*?overflow:\s*hidden;[\s\S]*?contain:\s*paint;/, "The employee analytics card does not paint-contain its loading state.");
assert.match(baseCssSource, /\.chart-stage,[\s\S]*?\.project-insight-stage,[\s\S]*?\.employee-analytics-stage\s*\{[\s\S]*?overflow:\s*hidden;[\s\S]*?contain:\s*layout paint;/, "Chart stages are not layout/paint-contained against loading overflow.");
assert.match(cssSource, /\.employee-analytics-stage\s*\{[\s\S]*?border-radius:\s*10px;/, "The contained employee chart stage is missing theme polish.");
assert.match(cssSource, /#projectDetailContainer\s*\{[\s\S]*?scroll-margin-top:\s*88px;/, "Project details can still be hidden beneath the sticky application header after navigation.");
assert.match(cssSource, /\.project-summary-card\.project-colored-surface:hover,[\s\S]*?\.project-summary-card\.project-colored-surface\.is-active\s*\{[\s\S]*?border-inline-start-color:\s*color-mix\(in srgb, var\(--project-color\)/, "Project cards no longer preserve their project color on the thin leading edge while hovered or selected.");
assert.match(cssSource, /\.project-portfolio-toolbar\s*\{[\s\S]*?grid-template-columns:/, "Project portfolio controls are missing their responsive layout.");
assert.match(cssSource, /\.project-portfolio-panel\s*\{[\s\S]*?row-gap:\s*14px;/, "Project portfolio blocks do not have enough vertical separation.");
assert.match(cssSource, /\.project-summary-section-grid,[\s\S]*?\.projects-grid\s*\{[\s\S]*?gap:\s*16px;/, "Project cards do not have enough space between them.");
assert.match(cssSource, /\.project-summary-section-grid,[\s\S]*?\.projects-grid\s*\{[\s\S]*?grid-auto-rows:\s*max-content;/, "Project cards can still collapse below the height of their contents.");
assert.match(cssSource, /\.project-portfolio-toolbar\s*\{[\s\S]*?gap:\s*12px;[\s\S]*?padding:\s*14px;/, "Project portfolio controls remain too compressed.");
assert.match(cssSource, /\.project-portfolio-sort-hint\s*\{[\s\S]*?margin:\s*-6px 2px 0;[\s\S]*?line-height:\s*1\.4;/, "Project sorting guidance is still crowded against adjacent containers.");
assert.match(cssSource, /\.project-portfolio-panel\s*>\s*\.projects-grid\s*\{[\s\S]*?padding-top:\s*2px;[\s\S]*?scroll-padding-top:\s*2px;/, "The lifted first project card can still have its top border clipped by the scrollport.");

for (const asset of [
  "assets/apple-ui.css?v=20260824-review-attention-tab-v1",
  "scripts/I18n.js?v=20260824-review-attention-tab-v1",
  "scripts/Utilities.js?v=20260824-review-attention-tab-v1",
  "scripts/AppShell.js?v=20260824-review-attention-tab-v1",
]) {
  assert(indexSource.includes(asset), `Updated UI asset is missing its cache buster: ${asset}`);
}

console.log("French diacritics and compact-card contract tests passed.");
