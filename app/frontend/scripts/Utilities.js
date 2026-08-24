function escapeHtml(value) {
  return String(value == null ? "" : value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/\"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

const asyncButtonActions = new Map();
const asyncButtonStates = new WeakMap();
const asyncDisabledControlStates = new WeakMap();

function getAsyncButtonActionKey(button, options) {
  if (options && options.key != null && String(options.key).trim()) {
    return `key:${String(options.key).trim()}`;
  }

  if (button && button.id) {
    return `button:${button.id}`;
  }

  return button || null;
}

function setAsyncButtonBusy(button) {
  if (!button || typeof button.setAttribute !== "function") {
    return null;
  }

  const existingState = asyncButtonStates.get(button);
  if (existingState) {
    existingState.count += 1;
    return existingState;
  }

  const state = {
    count: 1,
    disabled: Boolean(button.disabled),
    ariaBusy: button.getAttribute("aria-busy"),
    ariaDisabled: button.getAttribute("aria-disabled"),
  };
  asyncButtonStates.set(button, state);
  button.disabled = true;
  button.setAttribute("aria-busy", "true");
  button.setAttribute("aria-disabled", "true");
  button.classList.add("is-async-busy");
  return state;
}

function restoreAsyncButton(button, state, options) {
  if (!button || !state || asyncButtonStates.get(button) !== state) {
    return;
  }

  if (options && Object.prototype.hasOwnProperty.call(options, "disabledAfter")) {
    state.disabledAfter = options.disabledAfter;
  }
  state.count -= 1;
  if (state.count > 0) {
    return;
  }

  asyncButtonStates.delete(button);
  const disabledAfter = Object.prototype.hasOwnProperty.call(state, "disabledAfter")
    ? state.disabledAfter
    : state.disabled;
  button.disabled = typeof disabledAfter === "function"
    ? Boolean(disabledAfter(button, state.disabled))
    : Boolean(disabledAfter);
  button.classList.remove("is-async-busy");
  if (state.ariaBusy == null) {
    button.removeAttribute("aria-busy");
  } else {
    button.setAttribute("aria-busy", state.ariaBusy);
  }
  if (state.ariaDisabled == null) {
    button.removeAttribute("aria-disabled");
  } else {
    button.setAttribute("aria-disabled", state.ariaDisabled);
  }
}

function setAsyncControlDisabled(control) {
  if (!control || typeof control.setAttribute !== "function") {
    return null;
  }

  const existingState = asyncDisabledControlStates.get(control);
  if (existingState) {
    existingState.count += 1;
    return existingState;
  }

  const state = {
    count: 1,
    disabled: Boolean(control.disabled),
    ariaDisabled: control.getAttribute("aria-disabled"),
  };
  asyncDisabledControlStates.set(control, state);
  control.disabled = true;
  control.setAttribute("aria-disabled", "true");
  return state;
}

function restoreAsyncControlDisabled(control, state) {
  if (!control || !state || asyncDisabledControlStates.get(control) !== state) {
    return;
  }

  state.count -= 1;
  if (state.count > 0) {
    return;
  }

  asyncDisabledControlStates.delete(control);
  control.disabled = state.disabled;
  if (state.ariaDisabled == null) {
    control.removeAttribute("aria-disabled");
  } else {
    control.setAttribute("aria-disabled", state.ariaDisabled);
  }
}

function getAsyncDisabledControls(button, options) {
  if (!options || !options.disableWhileRunning) {
    return [];
  }

  const configuredControls = typeof options.disableWhileRunning === "function"
    ? options.disableWhileRunning()
    : options.disableWhileRunning;
  const controls = configuredControls && typeof configuredControls[Symbol.iterator] === "function"
    ? Array.from(configuredControls)
    : [configuredControls];
  return Array.from(new Set(controls.filter(control => control && control !== button)));
}

// Deduplicates by explicit key (or stable button id), including across a rerendered
// replacement button. Use disabledAfter when the completed action must intentionally
// leave the control in a different disabled state than it had before the request.
function runButtonAction(button, action, options = {}) {
  if (typeof action !== "function") {
    return Promise.reject(new TypeError("A button action function is required."));
  }

  const actionKey = getAsyncButtonActionKey(button, options);
  const inFlightAction = actionKey == null ? null : asyncButtonActions.get(actionKey);
  const buttonState = setAsyncButtonBusy(button);
  const disabledControls = getAsyncDisabledControls(button, options);
  const disabledControlStates = disabledControls.map(control => ({
    control,
    state: setAsyncControlDisabled(control),
  }));
  const restoreControls = () => {
    restoreAsyncButton(button, buttonState, options);
    disabledControlStates.forEach(({ control, state }) => restoreAsyncControlDisabled(control, state));
  };

  if (inFlightAction) {
    return inFlightAction.finally(restoreControls);
  }

  const actionPromise = Promise.resolve().then(action);
  if (actionKey != null) {
    asyncButtonActions.set(actionKey, actionPromise);
  }

  return actionPromise.finally(() => {
    if (actionKey != null && asyncButtonActions.get(actionKey) === actionPromise) {
      asyncButtonActions.delete(actionKey);
    }
    restoreControls();
  });
}

function timeRangeArrowIconMarkup() {
  return '<i class="fa-solid fa-arrow-right-long time-range-arrow" aria-hidden="true"></i>';
}

function timeRangeArrowText() {
  return "→";
}

function buildTimeRangeText(start, end) {
  return `${start} ${timeRangeArrowText()} ${end}`;
}

function buildTimeRangeMarkup(start, end) {
  return `${escapeHtml(start)} ${timeRangeArrowIconMarkup()} ${escapeHtml(end)}`;
}

function getCurrentLocale() {
  if (typeof window.getI18nLocale === "function") {
    return window.getI18nLocale();
  }
  return undefined;
}

(function initializeTextSearchUtilities(global) {
  function toText(value) {
    return value == null ? "" : String(value);
  }

  function tokenize(normalizedText) {
    return toText(normalizedText).split(/\s+/).filter(token => token.length > 0);
  }

  function matchesAll(normalizedText, tokens) {
    const text = toText(normalizedText);
    return (tokens || []).every(token => text.includes(token));
  }

  const saphir = global.Saphir && typeof global.Saphir === "object" ? global.Saphir : {};
  saphir.textSearch = Object.freeze({
    tokenize,
    matchesAll,
  });
  global.Saphir = saphir;
})(window);

function filterEntries(entries, searchTerm) {
  const tokens = window.Saphir.textSearch.tokenize(String(searchTerm || "").toLowerCase());
  if (tokens.length === 0) {
    return entries;
  }

  return entries.filter(entry => {
    const combinedText = [
      entry.employeeName,
      entry.employeeCode,
      entry.date,
      formatDateToWords(entry.date),
      entry.projectCode,
      entry.overtimeCode,
      entry.paymentOption,
      entry.reasonCode,
      entry.entryType,
      entry.diverseReason,
      entry.diverseSummary,
      entry.workComment,
      getEntryStatusLabel(entry),
      entry.message,
      entry.messageAuthorName,
      entry.messageAuthorUsername,
    ].join(" ").toLowerCase();

    return window.Saphir.textSearch.matchesAll(combinedText, tokens);
  });
}

function getEntryWorkComment(entry) {
  if (!entry || typeof entry !== "object") {
    return "";
  }

  const workComment = String(entry.workComment || "").trim();
  return workComment || String(entry.diverseSummary || "").trim();
}

function renderEntryWorkComment(entry, options = {}) {
  const comment = getEntryWorkComment(entry);
  if (!comment) {
    return "";
  }

  const compactClass = options.compact === true ? " is-compact" : "";
  return `
    <div class="entry-work-comment${compactClass}" role="note" aria-label="${escapeHtml(t("shared.employeeWorkComment"))}">
      <div class="entry-work-comment-label"><i class="fa-regular fa-comment" aria-hidden="true"></i> ${escapeHtml(t("shared.employeeWorkComment"))}</div>
      <div class="entry-work-comment-text">${escapeHtml(comment)}</div>
    </div>
  `;
}

function getEntryNotes(entry) {
  const safeEntry = entry && typeof entry === "object" ? entry : {};
  const employeeComment = getEntryWorkComment(safeEntry);
  const supervisorNote = String(safeEntry.message || "").trim();
  const supervisorNoteAuthor = String(safeEntry.messageAuthorName || safeEntry.messageAuthorUsername || "").trim();
  const count = Number(Boolean(employeeComment)) + Number(Boolean(supervisorNote));

  return {
    employeeComment,
    supervisorNote,
    supervisorNoteAuthor,
    count,
    preview: employeeComment || supervisorNote,
  };
}

function getEntrySupervisorNoteLabel(entry) {
  const notes = getEntryNotes(entry);
  return notes.supervisorNoteAuthor
    ? t("shared.managerMessageBy", { name: notes.supervisorNoteAuthor })
    : t("shared.managerMessage");
}

function encodeEntryNoteData(value) {
  return encodeURIComponent(String(value || ""));
}

function decodeEntryNoteData(value) {
  try {
    return decodeURIComponent(String(value || ""));
  } catch (error) {
    return String(value || "");
  }
}

function renderEntryNotesPreview(entry, options = {}) {
  const notes = getEntryNotes(entry);
  if (notes.count === 0) {
    return options.showEmpty === true
      ? `<span class="entry-notes-empty" aria-label="${escapeHtml(t("shared.noEntryNotes"))}">-</span>`
      : "";
  }

  return `
    <button
      type="button"
      class="entry-notes-preview"
      data-entry-notes-trigger
      data-entry-employee-comment="${escapeHtml(encodeEntryNoteData(notes.employeeComment))}"
      data-entry-supervisor-note="${escapeHtml(encodeEntryNoteData(notes.supervisorNote))}"
      data-entry-supervisor-note-author="${escapeHtml(encodeEntryNoteData(notes.supervisorNoteAuthor))}"
      aria-expanded="false"
      aria-label="${escapeHtml(t("action.viewEntryNotes"))}"
      title="${escapeHtml(t("action.viewEntryNotes"))}"
    >
      <i class="fa-regular fa-comment" aria-hidden="true"></i>
      <span class="entry-notes-preview-text">${escapeHtml(notes.preview)}</span>
      ${notes.count > 1 ? `<span class="entry-notes-count" aria-hidden="true">${notes.count}</span>` : ""}
    </button>
  `;
}

let activeEntryNotesPopover = null;
let activeEntryNotesTrigger = null;
let entryNotesPopoverInitialized = false;
let entryNotesPopoverSequence = 0;

function getEntryNotesFromTrigger(trigger) {
  return {
    employeeComment: decodeEntryNoteData(trigger && trigger.getAttribute("data-entry-employee-comment")),
    supervisorNote: decodeEntryNoteData(trigger && trigger.getAttribute("data-entry-supervisor-note")),
    supervisorNoteAuthor: decodeEntryNoteData(trigger && trigger.getAttribute("data-entry-supervisor-note-author")),
  };
}

function buildEntryNotesPopoverContent(trigger) {
  const notes = getEntryNotesFromTrigger(trigger);
  const sections = [];

  if (notes.employeeComment) {
    sections.push(`
      <div class="entry-notes-reader-section">
        <div class="entry-notes-reader-label"><i class="fa-regular fa-comment" aria-hidden="true"></i> ${escapeHtml(t("shared.employeeWorkComment"))}</div>
        <div class="entry-notes-reader-text">${escapeHtml(notes.employeeComment)}</div>
      </div>
    `);
  }

  if (notes.supervisorNote) {
    const supervisorNoteLabel = notes.supervisorNoteAuthor
      ? t("shared.managerMessageBy", { name: notes.supervisorNoteAuthor })
      : t("shared.managerMessage");
    sections.push(`
      <div class="entry-notes-reader-section">
        <div class="entry-notes-reader-label"><i class="fa-regular fa-note-sticky" aria-hidden="true"></i> ${escapeHtml(supervisorNoteLabel)}</div>
        <div class="entry-notes-reader-text">${escapeHtml(notes.supervisorNote)}</div>
      </div>
    `);
  }

  return `<div class="entry-notes-reader" role="note">${sections.join("")}</div>`;
}

function closeEntryNotesPopover(options = {}) {
  const popover = activeEntryNotesPopover;
  const trigger = activeEntryNotesTrigger;
  activeEntryNotesPopover = null;
  activeEntryNotesTrigger = null;

  if (trigger) {
    trigger.setAttribute("aria-expanded", "false");
    trigger.removeAttribute("aria-controls");
  }
  if (popover) {
    popover.remove();
  }
  if (options.restoreFocus === true && trigger && trigger.isConnected) {
    trigger.focus();
  }
}

function positionEntryNotesPopover() {
  if (!activeEntryNotesPopover || !activeEntryNotesTrigger) {
    return;
  }

  if (!activeEntryNotesTrigger.isConnected) {
    closeEntryNotesPopover();
    return;
  }

  if (window.innerWidth <= 760) {
    activeEntryNotesPopover.removeAttribute("data-placement");
    activeEntryNotesPopover.style.removeProperty("left");
    activeEntryNotesPopover.style.removeProperty("top");
    return;
  }

  const viewportMargin = 12;
  const anchorGap = 8;
  const triggerRect = activeEntryNotesTrigger.getBoundingClientRect();
  const popoverRect = activeEntryNotesPopover.getBoundingClientRect();
  const fitsBelow = triggerRect.bottom + anchorGap + popoverRect.height <= window.innerHeight - viewportMargin;
  const fitsAbove = triggerRect.top - anchorGap - popoverRect.height >= viewportMargin;
  const placement = !fitsBelow && fitsAbove ? "top" : "bottom";
  const top = placement === "top"
    ? triggerRect.top - popoverRect.height - anchorGap
    : Math.min(triggerRect.bottom + anchorGap, window.innerHeight - popoverRect.height - viewportMargin);
  const left = Math.max(
    viewportMargin,
    Math.min(triggerRect.left, window.innerWidth - popoverRect.width - viewportMargin),
  );

  activeEntryNotesPopover.setAttribute("data-placement", placement);
  activeEntryNotesPopover.style.left = `${Math.round(left)}px`;
  activeEntryNotesPopover.style.top = `${Math.max(viewportMargin, Math.round(top))}px`;
}

function toggleEntryNotesPopover(trigger) {
  if (!trigger) {
    return;
  }

  if (activeEntryNotesTrigger === trigger) {
    closeEntryNotesPopover({ restoreFocus: true });
    return;
  }

  closeEntryNotesPopover();
  const notes = getEntryNotesFromTrigger(trigger);
  if (!notes.employeeComment && !notes.supervisorNote) {
    return;
  }

  entryNotesPopoverSequence += 1;
  const popoverId = `entry-notes-popover-${entryNotesPopoverSequence}`;
  const popoverTitleId = `${popoverId}-title`;
  const popover = document.createElement("aside");
  popover.id = popoverId;
  popover.className = "entry-notes-popover";
  popover.setAttribute("role", "region");
  popover.setAttribute("aria-labelledby", popoverTitleId);
  popover.innerHTML = `
    <div class="entry-notes-reader-header">
      <div class="entry-notes-reader-title" id="${popoverTitleId}">${escapeHtml(t("shared.entryNotes"))}</div>
      <button type="button" class="entry-notes-reader-close" data-entry-notes-close aria-label="${escapeHtml(t("shared.close"))}" title="${escapeHtml(t("shared.close"))}">
        <i class="fa-solid fa-xmark" aria-hidden="true"></i>
      </button>
    </div>
    <div class="entry-notes-reader-body">${buildEntryNotesPopoverContent(trigger)}</div>
  `;

  activeEntryNotesTrigger = trigger;
  activeEntryNotesPopover = popover;
  trigger.setAttribute("aria-expanded", "true");
  trigger.setAttribute("aria-controls", popoverId);
  document.body.appendChild(popover);
  positionEntryNotesPopover();
}

function initializeEntryNotesPopover() {
  if (entryNotesPopoverInitialized) {
    return;
  }
  entryNotesPopoverInitialized = true;

  document.addEventListener("click", event => {
    const target = event.target && typeof event.target.closest === "function" ? event.target : null;
    const trigger = target ? target.closest("[data-entry-notes-trigger]") : null;
    if (trigger) {
      event.preventDefault();
      toggleEntryNotesPopover(trigger);
      return;
    }

    if (target && target.closest("[data-entry-notes-close]")) {
      event.preventDefault();
      closeEntryNotesPopover({ restoreFocus: true });
      return;
    }

    if (activeEntryNotesPopover && !(target && activeEntryNotesPopover.contains(target))) {
      closeEntryNotesPopover();
    }
  });

  document.addEventListener("keydown", event => {
    if (event.key === "Escape" && activeEntryNotesPopover) {
      event.preventDefault();
      closeEntryNotesPopover({ restoreFocus: true });
    }
  });

  window.addEventListener("resize", positionEntryNotesPopover);
  document.addEventListener("scroll", positionEntryNotesPopover, true);

  if (typeof MutationObserver === "function") {
    const observer = new MutationObserver(() => {
      if (activeEntryNotesTrigger && !activeEntryNotesTrigger.isConnected) {
        closeEntryNotesPopover();
      }
    });
    observer.observe(document.body, { childList: true, subtree: true });
  }
}

function formatTimeString(timeStr) {
  if (!timeStr) {
    return "--:--";
  }

  const parts = String(timeStr).split(":");
  if (parts.length < 2) {
    return String(timeStr);
  }

  return `${parts[0].padStart(2, "0")}:${parts[1].padStart(2, "0")}`;
}

function normalizeTime(timeString) {
  return timeString ? String(timeString).slice(0, 5) : "";
}

function normalizeBooleanValue(value, fallback) {
  if (typeof value === "boolean") {
    return value;
  }

  const text = String(value == null ? "" : value).trim().toLowerCase();
  if (["true", "1", "yes", "y", "on"].includes(text)) {
    return true;
  }
  if (["false", "0", "no", "n", "off"].includes(text)) {
    return false;
  }

  return Boolean(fallback);
}

function getFirstDefinedPropertyValue(source, names) {
  const objectSource = source && typeof source === "object" ? source : {};
  const fieldNames = Array.isArray(names) ? names : [];
  for (let index = 0; index < fieldNames.length; index += 1) {
    const name = fieldNames[index];
    if (Object.prototype.hasOwnProperty.call(objectSource, name)) {
      return objectSource[name];
    }
  }

  return undefined;
}

function getFirstNonEmptyPropertyValue(source, names) {
  const objectSource = source && typeof source === "object" ? source : {};
  const fieldNames = Array.isArray(names) ? names : [];
  for (let index = 0; index < fieldNames.length; index += 1) {
    const name = fieldNames[index];
    if (!Object.prototype.hasOwnProperty.call(objectSource, name)) {
      continue;
    }
    const candidate = objectSource[name];
    if (candidate != null && String(candidate).trim()) {
      return candidate;
    }
  }

  return "";
}

function hasAnyOwnProperty(source, names) {
  const objectSource = source && typeof source === "object" ? source : {};
  const fieldNames = Array.isArray(names) ? names : [];
  return fieldNames.some(name => Object.prototype.hasOwnProperty.call(objectSource, name));
}

function normalizeGc179ProfileCode(value, fallback, maxLength) {
  const normalized = String(value || "")
    .trim()
    .toUpperCase()
    .replace(/\s+/g, "")
    .replace(/[^A-Z0-9._\/-]/g, "")
    .slice(0, maxLength)
    .trim();
  return normalized || String(fallback || "").trim().toUpperCase();
}

function normalizeGc179Group(value) {
  return normalizeGc179ProfileCode(value, "STS", 6);
}

function normalizeGc179SubGroup(value) {
  return normalizeGc179ProfileCode(value, "SUF-00", 10);
}

function normalizeGc179Level(value) {
  return normalizeGc179ProfileCode(value, "", 10);
}

function normalizeGc179Position(value) {
  return normalizeGc179Group(value);
}

function normalizeGc179Echelon(value) {
  return normalizeGc179SubGroup(value);
}

function bindGc179CodeFormatter(input, onChange) {
  if (!input) {
    return;
  }

  input.addEventListener("input", () => {
    const selectionStart = input.selectionStart;
    const selectionEnd = input.selectionEnd;
    const uppercaseValue = String(input.value || "").toUpperCase();
    if (input.value !== uppercaseValue) {
      input.value = uppercaseValue;
      if (typeof input.setSelectionRange === "function" && selectionStart != null && selectionEnd != null) {
        input.setSelectionRange(selectionStart, selectionEnd);
      }
    }
    if (typeof onChange === "function") {
      onChange(input.value);
    }
  });
}

function formatGc179Pri(value) {
  const digits = String(value || "").replace(/\D/g, "").slice(0, 9);
  const groups = [];
  for (let index = 0; index < digits.length; index += 3) {
    groups.push(digits.slice(index, index + 3));
  }

  return groups.join(" ");
}

function bindGc179PriFormatter(input) {
  if (!input) {
    return;
  }

  const formatInput = () => {
    const formatted = formatGc179Pri(input.value);
    if (input.value !== formatted) {
      input.value = formatted;
    }
  };

  input.addEventListener("input", formatInput);
  input.addEventListener("blur", formatInput);
}

function parseLocalDate(dateString) {
  const parts = String(dateString || "").split("-").map(Number);
  if (parts.length < 3 || parts.some(Number.isNaN)) {
    return null;
  }

  const date = new Date(parts[0], parts[1] - 1, parts[2]);
  return Number.isNaN(date.getTime()) ? null : date;
}

function normalizeDateInputValue(dateString) {
  const trimmed = String(dateString || "").trim();
  if (!trimmed) {
    return "";
  }

  const parsedDate = parseLocalDate(trimmed);
  if (!parsedDate) {
    return "";
  }

  return trimmed;
}

function toLocalDateInputValue(dateValue = new Date()) {
  const date = dateValue instanceof Date ? dateValue : new Date(dateValue);
  if (Number.isNaN(date.getTime())) {
    return "";
  }

  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
}

(function initializeDateRangeUtilities(global) {
  function copyReferenceDate(referenceDate) {
    const date = referenceDate instanceof Date
      ? new Date(referenceDate.getTime())
      : new Date(referenceDate);
    if (Number.isNaN(date.getTime())) {
      throw new TypeError("A valid reference date is required.");
    }
    return date;
  }

  function resolveSelf(range, customRange, referenceDate) {
    const normalizedRange = range || "month";
    const normalizedCustomRange = customRange && typeof customRange === "object" ? customRange : {};
    const now = copyReferenceDate(referenceDate);

    if (normalizedRange === "custom") {
      return {
        startDate: normalizeDateInputValue(normalizedCustomRange.startDate),
        endDate: normalizeDateInputValue(normalizedCustomRange.endDate),
      };
    }

    if (normalizedRange === "year") {
      return {
        startDate: toLocalDateInputValue(new Date(now.getFullYear(), 0, 1)),
        endDate: toLocalDateInputValue(now),
      };
    }

    if (normalizedRange === "month") {
      return {
        startDate: toLocalDateInputValue(new Date(now.getFullYear(), now.getMonth(), 1)),
        endDate: toLocalDateInputValue(now),
      };
    }

    return { startDate: "", endDate: "" };
  }

  function resolveProjects(filterPeriod, customRange, referenceDate) {
    const normalizedFilter = filterPeriod || "all";
    const normalizedCustomRange = customRange && typeof customRange === "object" ? customRange : {};
    const now = copyReferenceDate(referenceDate);
    const endDate = now.toISOString().split("T")[0];
    let startDate = "";
    let resolvedEndDate = endDate;

    switch (normalizedFilter) {
      case "1M":
        startDate = new Date(now.getFullYear(), now.getMonth(), 1).toISOString().split("T")[0];
        break;
      case "6M":
        startDate = new Date(now.getFullYear(), now.getMonth() - 6, 1).toISOString().split("T")[0];
        break;
      case "1Y":
        startDate = new Date(now.getFullYear() - 1, now.getMonth(), now.getDate()).toISOString().split("T")[0];
        break;
      case "custom":
        startDate = normalizeDateInputValue(normalizedCustomRange.startDate);
        resolvedEndDate = normalizeDateInputValue(normalizedCustomRange.endDate);
        break;
      case "all":
      default:
        startDate = "";
        resolvedEndDate = "";
        break;
    }

    return { startDate, endDate: resolvedEndDate };
  }

  const saphir = global.Saphir && typeof global.Saphir === "object" ? global.Saphir : {};
  saphir.dateRanges = Object.freeze({
    resolveSelf,
    resolveProjects,
  });
  global.Saphir = saphir;
})(window);

(function initializeEntryStatsUtilities(global) {
  function resolveStatus(entry, isOpen) {
    if (isOpen(entry)) {
      return "live";
    }
    return String(entry && entry.status || "pending").toLowerCase();
  }

  function selectTopBucket(buckets) {
    return Object.values(buckets).sort((left, right) => {
      if (right.seconds !== left.seconds) {
        return right.seconds - left.seconds;
      }
      return right.count - left.count;
    })[0] || null;
  }

  function requireAdapter(options, name) {
    const adapter = options && options[name];
    if (typeof adapter !== "function") {
      throw new TypeError(`Entry statistics require the ${name} adapter.`);
    }
    return adapter;
  }

  function summarize(entries, options) {
    const sourceEntries = Array.isArray(entries) ? entries : [];
    const getDurationSeconds = requireAdapter(options, "getDurationSeconds");
    const getStatus = requireAdapter(options, "getStatus");
    const getTimestamp = requireAdapter(options, "getTimestamp");
    const getProjectCode = requireAdapter(options, "getProjectCode");
    const getProject = requireAdapter(options, "getProject");
    const getOvertimeCode = requireAdapter(options, "getOvertimeCode");
    const includeSourceEntries = Boolean(options && options.includeSourceEntries);
    const includeProjectEntries = Boolean(options && options.includeProjectEntries);
    const projectBuckets = {};
    const overtimeCodeBuckets = {};
    const totals = {
      count: sourceEntries.length,
      seconds: 0,
      approvedSeconds: 0,
      pending: 0,
      rejected: 0,
      live: 0,
      notes: 0,
      maxSeconds: 0,
    };

    sourceEntries.forEach(entry => {
      const seconds = getDurationSeconds(entry);
      const status = getStatus(entry);
      const projectCode = getProjectCode(entry);
      const overtimeCode = getOvertimeCode(entry);

      if (!projectBuckets[projectCode]) {
        const project = getProject(projectCode, entry);
        const projectBucket = {
          projectCode,
          projectName: project.projectName,
          colorKey: project.colorKey,
          markerKey: project.markerKey,
          count: 0,
          seconds: 0,
          approvedSeconds: 0,
          pending: 0,
          rejected: 0,
          live: 0,
          notes: 0,
          maxSeconds: 0,
          latestEntry: null,
        };
        if (includeProjectEntries) {
          projectBucket.entries = [];
        }
        projectBucket.overtimeCodes = {};
        projectBuckets[projectCode] = projectBucket;
      }

      const projectBucket = projectBuckets[projectCode];
      if (includeProjectEntries) {
        projectBucket.entries.push(entry);
      }
      projectBucket.count += 1;
      projectBucket.seconds += seconds;
      projectBucket.maxSeconds = Math.max(projectBucket.maxSeconds, seconds);
      projectBucket.latestEntry = !projectBucket.latestEntry || getTimestamp(entry) > getTimestamp(projectBucket.latestEntry)
        ? entry
        : projectBucket.latestEntry;

      if (!projectBucket.overtimeCodes[overtimeCode]) {
        projectBucket.overtimeCodes[overtimeCode] = { code: overtimeCode, count: 0, seconds: 0 };
      }
      projectBucket.overtimeCodes[overtimeCode].count += 1;
      projectBucket.overtimeCodes[overtimeCode].seconds += seconds;

      if (!overtimeCodeBuckets[overtimeCode]) {
        overtimeCodeBuckets[overtimeCode] = { code: overtimeCode, count: 0, seconds: 0 };
      }
      overtimeCodeBuckets[overtimeCode].count += 1;
      overtimeCodeBuckets[overtimeCode].seconds += seconds;

      totals.seconds += seconds;
      totals.maxSeconds = Math.max(totals.maxSeconds, seconds);
      if (String(entry.message || "").trim()) {
        totals.notes += 1;
        projectBucket.notes += 1;
      }
      if (status === "approved") {
        totals.approvedSeconds += seconds;
        projectBucket.approvedSeconds += seconds;
      } else if (status === "pending") {
        totals.pending += 1;
        projectBucket.pending += 1;
      } else if (status === "rejected") {
        totals.rejected += 1;
        projectBucket.rejected += 1;
      } else if (status === "live") {
        totals.live += 1;
        projectBucket.live += 1;
      }
    });

    const summary = {
      totals,
      projects: Object.values(projectBuckets).sort((left, right) => right.seconds - left.seconds),
      topOvertimeCode: selectTopBucket(overtimeCodeBuckets),
    };
    return includeSourceEntries
      ? { entries: sourceEntries, ...summary }
      : summary;
  }

  const saphir = global.Saphir && typeof global.Saphir === "object" ? global.Saphir : {};
  saphir.entryStats = Object.freeze({
    resolveStatus,
    selectTopBucket,
    summarize,
  });
  global.Saphir = saphir;
})(window);

(function initializeCalendarMonthUtilities(global) {
  function requireAdapter(options, name) {
    const adapter = options && options[name];
    if (typeof adapter !== "function") {
      throw new TypeError(`Calendar months require the ${name} adapter.`);
    }
    return adapter;
  }

  function requireReferenceDate(options) {
    const referenceDate = options && options.referenceDate;
    if (!referenceDate || typeof referenceDate.getFullYear !== "function" || Number.isNaN(referenceDate.getTime())) {
      throw new TypeError("Calendar months require a valid reference date.");
    }
    return referenceDate;
  }

  function resolveActiveMonth(entries, selectedMonthKey, options) {
    if (selectedMonthKey) {
      return selectedMonthKey;
    }

    const sourceEntries = Array.isArray(entries) ? entries : [];
    const toMonthKey = requireAdapter(options, "toMonthKey");
    if (sourceEntries.length > 0) {
      const getTimestamp = requireAdapter(options, "getTimestamp");
      const getEntryDate = requireAdapter(options, "getEntryDate");
      const latestEntry = sourceEntries.slice().sort((left, right) => getTimestamp(right) - getTimestamp(left))[0];
      return toMonthKey(getEntryDate(latestEntry));
    }

    return toMonthKey(requireReferenceDate(options));
  }

  function buildYear(entries, activeMonthKey, options) {
    const toMonthKey = requireAdapter(options, "toMonthKey");
    const getEntryDate = requireAdapter(options, "getEntryDate");
    const formatMonthLabel = requireAdapter(options, "formatMonthLabel");
    const referenceDate = requireReferenceDate(options);
    const [activeYear] = String(activeMonthKey || "").split("-").map(Number);
    const year = Number.isNaN(activeYear) ? referenceDate.getFullYear() : activeYear;
    const monthCounts = {};

    (entries || []).forEach(entry => {
      const monthKey = toMonthKey(getEntryDate(entry));
      if (!monthKey.startsWith(`${year}-`)) {
        return;
      }
      monthCounts[monthKey] = (monthCounts[monthKey] || 0) + 1;
    });

    return Array.from({ length: 12 }, (_, index) => {
      const monthDate = new Date(year, index, 1);
      const monthKey = toMonthKey(monthDate);
      return {
        monthKey,
        label: formatMonthLabel(monthDate),
        count: monthCounts[monthKey] || 0,
        active: monthKey === activeMonthKey,
      };
    });
  }

  const saphir = global.Saphir && typeof global.Saphir === "object" ? global.Saphir : {};
  saphir.calendarMonths = Object.freeze({
    resolveActiveMonth,
    buildYear,
  });
  global.Saphir = saphir;
})(window);

(function initializeCalendarDayUtilities(global) {
  function requireAdapter(options, name) {
    const adapter = options && options[name];
    if (typeof adapter !== "function") {
      throw new TypeError(`Calendar days require the ${name} adapter.`);
    }
    return adapter;
  }

  function buildMonth(entries, activeMonthKey, options) {
    const getEntryDate = requireAdapter(options, "getEntryDate");
    const getDurationSeconds = requireAdapter(options, "getDurationSeconds");
    const orderDayEntries = requireAdapter(options, "orderDayEntries");
    const [activeYear, activeMonth] = String(activeMonthKey || "").split("-").map(Number);
    const firstDay = new Date(activeYear, activeMonth - 1, 1);
    const lastDay = new Date(activeYear, activeMonth, 0);
    const gridStart = new Date(firstDay);
    gridStart.setDate(firstDay.getDate() - firstDay.getDay());
    const gridEnd = new Date(lastDay);
    gridEnd.setDate(lastDay.getDate() + (6 - lastDay.getDay()));
    const groupedEntries = (entries || []).reduce((accumulator, entry) => {
      const dateKey = getEntryDate(entry);
      if (!accumulator[dateKey]) {
        accumulator[dateKey] = [];
      }
      accumulator[dateKey].push(entry);
      return accumulator;
    }, {});
    const days = [];
    const cursor = new Date(gridStart);

    while (cursor <= gridEnd) {
      const dateKey = `${cursor.getFullYear()}-${String(cursor.getMonth() + 1).padStart(2, "0")}-${String(cursor.getDate()).padStart(2, "0")}`;
      const dayEntries = orderDayEntries(groupedEntries[dateKey] || []);
      const totalSeconds = dayEntries.reduce((accumulator, entry) => accumulator + getDurationSeconds(entry), 0);
      days.push({
        dateKey,
        dayNumber: cursor.getDate(),
        isCurrentMonth: cursor.getMonth() === (activeMonth - 1),
        entries: dayEntries,
        totalSeconds,
      });
      cursor.setDate(cursor.getDate() + 1);
    }

    return {
      year: activeYear,
      month: activeMonth,
      days,
    };
  }

  const saphir = global.Saphir && typeof global.Saphir === "object" ? global.Saphir : {};
  saphir.calendarDays = Object.freeze({
    buildMonth,
  });
  global.Saphir = saphir;
})(window);

function toCalendarMonthKey(dateValue) {
  const date = dateValue instanceof Date ? dateValue : parseLocalDate(dateValue);
  if (!date) {
    const now = new Date();
    return `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, "0")}`;
  }

  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}`;
}

function shiftCalendarMonthKey(monthKey, delta) {
  const [year, month] = String(monthKey || "").split("-").map(Number);
  const date = new Date(
    Number.isNaN(year) ? new Date().getFullYear() : year,
    Number.isNaN(month) ? new Date().getMonth() : month - 1,
    1,
  );
  date.setMonth(date.getMonth() + delta);
  return toCalendarMonthKey(date);
}

function formatCalendarMonthLabel(monthKey) {
  const [year, month] = String(monthKey || "").split("-").map(Number);
  const date = new Date(
    Number.isNaN(year) ? new Date().getFullYear() : year,
    Number.isNaN(month) ? new Date().getMonth() : month - 1,
    1,
  );
  return date.toLocaleDateString(getCurrentLocale(), { month: "long", year: "numeric" });
}

function getCalendarWeekdayLabels() {
  const baseSunday = new Date(2026, 0, 4);
  return Array.from({ length: 7 }, (_, index) => {
    const date = new Date(baseSunday);
    date.setDate(baseSunday.getDate() + index);
    return date.toLocaleDateString(getCurrentLocale(), { weekday: "short" });
  });
}

function groupEntriesByDate(entries) {
  return (entries || []).reduce((accumulator, entry) => {
    if (!accumulator[entry.date]) {
      accumulator[entry.date] = [];
    }
    accumulator[entry.date].push(entry);
    return accumulator;
  }, {});
}

function isDateWithinRange(dateString, startDate, endDate) {
  const entryDate = parseLocalDate(dateString);
  if (!entryDate) {
    return false;
  }

  const normalizedStartDate = normalizeDateInputValue(startDate);
  if (normalizedStartDate) {
    const start = parseLocalDate(normalizedStartDate);
    if (start && entryDate < start) {
      return false;
    }
  }

  const normalizedEndDate = normalizeDateInputValue(endDate);
  if (normalizedEndDate) {
    const end = parseLocalDate(normalizedEndDate);
    if (end && entryDate > end) {
      return false;
    }
  }

  return true;
}

function buildDateRangeLabel(startDate, endDate) {
  const normalizedStart = normalizeDateInputValue(startDate);
  const normalizedEnd = normalizeDateInputValue(endDate);

  if (normalizedStart && normalizedEnd) {
    return buildTimeRangeText(formatDateLabel(normalizedStart), formatDateLabel(normalizedEnd));
  }

  if (normalizedStart) {
    return `${t("filters.startDate")} ${formatDateLabel(normalizedStart)}`;
  }

  if (normalizedEnd) {
    return `${t("filters.endDate")} ${formatDateLabel(normalizedEnd)}`;
  }

  return "";
}

function formatDateToWords(dateString) {
  if (!dateString) {
    return t("shared.unknownDate");
  }

  const date = parseLocalDate(dateString);
  if (!date) {
    return String(dateString);
  }

  return date.toLocaleDateString(getCurrentLocale(), { year: "numeric", month: "long", day: "numeric" });
}

function formatDateLabel(dateString) {
  if (!dateString) {
    return t("shared.unknownDate");
  }

  const date = parseLocalDate(dateString);
  if (!date) {
    return String(dateString);
  }

  return date.toLocaleDateString(getCurrentLocale(), { weekday: "short", month: "short", day: "numeric" });
}

function formatYMToWords(dateStr) {
  if (!dateStr) {
    return t("shared.unknown");
  }

  const [year, month] = String(dateStr).split("-");
  const date = new Date(Number(year), Number(month) - 1, 1);
  if (Number.isNaN(date.getTime())) {
    return String(dateStr);
  }

  return date.toLocaleDateString(getCurrentLocale(), { month: "short", year: "numeric" });
}

function formatDateTimeStamp(timestamp) {
  if (!timestamp) {
    return t("shared.unknownTime");
  }

  const normalized = String(timestamp).replace(" ", "T");
  const date = new Date(normalized);
  if (Number.isNaN(date.getTime())) {
    return String(timestamp);
  }

  return `${date.toLocaleDateString(getCurrentLocale(), { month: "short", day: "numeric", year: "numeric" })} | ${date.toLocaleTimeString(getCurrentLocale(), { hour: "2-digit", minute: "2-digit" })}`;
}

function convertFormattedTimeToBackend(timeStr) {
  if (!timeStr) {
    return "";
  }

  const cleaned = String(timeStr).replace(/\s+/g, "").replace("h", ":");
  if (cleaned.split(":").length === 2) {
    return `${cleaned}:00`;
  }

  return cleaned;
}

function timeStringToSeconds(timeStr) {
  if (!timeStr || timeStr === "N/A") {
    return 0;
  }

  const parts = String(timeStr).split(":").map(Number);
  if (parts.some(Number.isNaN)) {
    return 0;
  }

  while (parts.length < 3) {
    parts.push(0);
  }

  return (parts[0] * 3600) + (parts[1] * 60) + parts[2];
}

function secondsToDurationLabel(totalSeconds) {
  const safeSeconds = Math.max(0, Number(totalSeconds) || 0);
  const hours = Math.floor(safeSeconds / 3600);
  const minutes = Math.floor((safeSeconds % 3600) / 60);
  return `${String(hours).padStart(2, "0")}h ${String(minutes).padStart(2, "0")}`;
}

function getEntryDurationSeconds(entry) {
  if (isEntryOpen(entry)) {
    const startedAt = toEntryDateTime(entry);
    return Math.max(0, Math.floor((Date.now() - startedAt.getTime()) / 1000));
  }
  return timeStringToSeconds(entry && entry.overtime);
}

function updateTotalOvertime(entries) {
  const totalSeconds = (entries || []).reduce((accumulator, entry) => accumulator + timeStringToSeconds(entry.overtime), 0);
  const target = document.getElementById("totalOvertime");
  if (target) {
    target.innerText = secondsToDurationLabel(totalSeconds);
  }
}

const overtimeEntryLookupCache = {
  apiUrl: null,
  scopeKey: null,
  payload: null,
};

const scopedProjectLookupCache = {
  apiUrl: null,
  scopeKey: null,
  payload: null,
};

function getLookupCacheScopeKey() {
  const user = typeof getCurrentUser === "function" ? getCurrentUser() : null;
  const role = user && typeof normalizeClientRole === "function"
    ? normalizeClientRole(user.role)
    : String(user && user.role || "");
  const username = String(user && user.username || "");
  const employeeCode = String(user && user.employeeCode || "");
  return [role, username, employeeCode].join("|");
}

function parseResponse(response) {
  if (!response.ok) {
    return response.text().then(text => {
      if (!text) {
        throw new Error(t("error.requestFailedStatus", { status: response.status }));
      }

      try {
        const payload = JSON.parse(text);
        throw new Error(payload.error || text);
      } catch (error) {
        if (error instanceof SyntaxError) {
          throw new Error(text);
        }
        throw error;
      }
    });
  }

  return response.text().then(text => {
    if (!text) {
      return {};
    }
    return JSON.parse(text);
  });
}

function createEmptyState(message) {
  return `<div class="empty-state">${escapeHtml(message)}</div>`;
}

function createLoadingState(variant = "list", count = 3) {
  const safeCount = Math.max(1, Number(count) || 1);

  if (variant === "employeeBarChart") {
    return `
      <div class="loading-shell loading-shell-employee-chart" aria-hidden="true">
        <div class="loading-employee-bar-chart">
          <div class="loading-employee-bar-row">
            <span class="loading-bar loading-employee-bar-label"></span>
            <span class="loading-bar loading-employee-bar-value"></span>
          </div>
          <div class="loading-employee-bar-row">
            <span class="loading-bar loading-employee-bar-label"></span>
            <span class="loading-bar loading-employee-bar-value"></span>
          </div>
          <div class="loading-employee-bar-row">
            <span class="loading-bar loading-employee-bar-label"></span>
            <span class="loading-bar loading-employee-bar-value"></span>
          </div>
          <div class="loading-employee-bar-row">
            <span class="loading-bar loading-employee-bar-label"></span>
            <span class="loading-bar loading-employee-bar-value"></span>
          </div>
          <div class="loading-employee-bar-row">
            <span class="loading-bar loading-employee-bar-label"></span>
            <span class="loading-bar loading-employee-bar-value"></span>
          </div>
        </div>
      </div>
    `;
  }

  if (variant === "chart") {
    return `
      <div class="loading-shell loading-shell-chart" aria-hidden="true">
        <div class="loading-chart">
          <span class="loading-bar loading-bar-title"></span>
          <span class="loading-bar loading-bar-chart"></span>
        </div>
      </div>
    `;
  }

  if (variant === "detail") {
    return `
      <div class="loading-shell loading-shell-detail" aria-hidden="true">
        <div class="loading-card loading-card-detail">
          <span class="loading-bar loading-bar-title"></span>
          <span class="loading-bar loading-bar-meta"></span>
          <span class="loading-bar loading-bar-wide"></span>
          <span class="loading-bar loading-bar-wide"></span>
        </div>
      </div>
    `;
  }

  const cards = Array.from({ length: safeCount }).map(() => `
    <div class="loading-card">
      <span class="loading-bar loading-bar-title"></span>
      <span class="loading-bar loading-bar-meta"></span>
      <span class="loading-bar loading-bar-wide"></span>
    </div>
  `).join("");

  const shellClass = variant === "grid"
    ? "loading-shell-grid"
    : variant === "activity"
      ? "loading-shell-activity"
      : "loading-shell-list";

  return `<div class="loading-shell ${shellClass}" aria-hidden="true">${cards}</div>`;
}

function setLoadingState(targetOrId, variant = "list", count = 3) {
  const target = typeof targetOrId === "string"
    ? document.getElementById(targetOrId)
    : targetOrId;

  if (!target) {
    return;
  }

  target.innerHTML = createLoadingState(variant, count);
}

function setChartLoadingState(containerId) {
  const container = document.getElementById(containerId);
  if (!container) {
    return;
  }

  const chartStage = container.querySelector(".chart-stage");
  if (!chartStage) {
    return;
  }

  chartStage.innerHTML = createLoadingState("chart", 1);
}

function getStatusTone(status) {
  if (status && typeof status === "object" && isEntryForgottenClockOut(status)) {
    return "attention";
  }

  const statusValue = status && typeof status === "object" ? status.status : status;
  switch (String(statusValue || "").toLowerCase()) {
    case "approved":
      return "approved";
    case "rejected":
      return "rejected";
    default:
      return "pending";
  }
}

function canModifyEntry(entry) {
  return !entry || entry.canModify !== false;
}

function canApproveEntry(entry) {
  return !entry || entry.canApprove !== false;
}

function getEntryPermissionReason(entry) {
  if (!canModifyEntry(entry)) {
    return "readOnlyProject";
  }

  if (!canApproveEntry(entry)) {
    return String(entry && entry.permissionReason || "superAdminApproval");
  }

  return "";
}

function getEntryPermissionBadgeMarkup(entry) {
  const reason = getEntryPermissionReason(entry);
  if (!reason) {
    return "";
  }

  const tone = reason === "superAdminApproval" ? "locked" : "readonly";
  return `<span class="permission-badge ${tone}">${escapeHtml(t(`permissions.${reason}`))}</span>`;
}

function isEntryForgottenClockOut(entry) {
  if (!entry || typeof entry !== "object") {
    return false;
  }

  const value = entry.forgottenClockOut !== undefined && entry.forgottenClockOut !== null
    ? entry.forgottenClockOut
    : entry.needsClockOutReview;
  if (typeof value === "boolean") {
    return value;
  }

  const normalized = String(value || "").trim().toLowerCase();
  return normalized === "true" || normalized === "1" || normalized === "yes";
}

function getEntryStatusLabel(entry) {
  if (isEntryForgottenClockOut(entry)) {
    return t("status.clockOutMissing");
  }

  return translateStatus(entry && entry.status ? entry.status : "pending");
}

function formatRelativeTime(timestamp) {
  if (!timestamp) {
    return t("date.justNow");
  }

  const normalized = String(timestamp).replace(" ", "T");
  const date = new Date(normalized);
  if (Number.isNaN(date.getTime())) {
    return String(timestamp);
  }

  const deltaSeconds = Math.round((Date.now() - date.getTime()) / 1000);
  if (deltaSeconds < 60) {
    return t("date.justNow");
  }
  if (deltaSeconds < 3600) {
    return t("date.minutesAgo", { count: Math.floor(deltaSeconds / 60) });
  }
  if (deltaSeconds < 86400) {
    return t("date.hoursAgo", { count: Math.floor(deltaSeconds / 3600) });
  }

  return t("date.daysAgo", { count: Math.floor(deltaSeconds / 86400) });
}

function sortEntriesByDateTime(entries, latestFirst) {
  return (entries || []).slice().sort((left, right) => {
    const leftDate = toEntryDateTime(left).getTime();
    const rightDate = toEntryDateTime(right).getTime();
    return latestFirst ? rightDate - leftDate : leftDate - rightDate;
  });
}

function toEntryDateTime(entry) {
  const fallback = entry && entry.date ? `${entry.date}T${entry.punchIn || "00:00:00"}` : Date.now();
  return new Date(fallback);
}

function getLatestEntry(entries) {
  const sorted = sortEntriesByDateTime(entries, true);
  return sorted.length > 0 ? sorted[0] : null;
}

function isEntryOpen(entry) {
  return Boolean(entry && entry.punchIn && !entry.punchOut && !isEntryForgottenClockOut(entry));
}

function getEntryType(entry) {
  const normalized = String(entry && entry.entryType ? entry.entryType : "overtime").trim().toLowerCase();
  return normalized === "diverse" ? "diverse" : "overtime";
}

function isDiverseEntry(entry) {
  return getEntryType(entry) === "diverse";
}

function getEntryContextLabel(entry) {
  if (isDiverseEntry(entry)) {
    const reason = String(entry && entry.diverseReason || "").trim();
    return reason ? `${t("shared.diverse")} | ${reason}` : t("shared.diverse");
  }

  const parts = [];

  if (entry && entry.projectCode) {
    parts.push(String(entry.projectCode));
  }

  if (entry && entry.overtimeCode) {
    parts.push(String(entry.overtimeCode));
  }

  if (entry && entry.paymentOption) {
    parts.push(formatPaymentOptionValue(entry.paymentOption));
  }

  if (entry && entry.reasonCode) {
    parts.push(String(entry.reasonCode));
  }

  return parts.length > 0 ? parts.join(" | ") : t("shared.uncoded");
}

function getEntryExactPunchIn(entry) {
  if (!entry) {
    return "";
  }

  return String(entry.exactPunchIn || entry.punchIn || "");
}

function getEntryExactPunchOut(entry) {
  if (!entry) {
    return "";
  }

  return String(entry.exactPunchOut || entry.punchOut || "");
}

function getEntryRoundedTimeRange(entry) {
  const roundedPunchIn = formatTimeString(entry && entry.punchIn);
  const roundedPunchOut = entry && entry.punchOut ? formatTimeString(entry.punchOut) : t("shared.inProgress");
  return buildTimeRangeText(roundedPunchIn, roundedPunchOut);
}

function getEntryRoundedTimeRangeMarkup(entry) {
  const roundedPunchIn = formatTimeString(entry && entry.punchIn);
  const roundedPunchOut = entry && entry.punchOut ? formatTimeString(entry.punchOut) : t("shared.inProgress");
  return buildTimeRangeMarkup(roundedPunchIn, roundedPunchOut);
}

function getEntryExactTimeLabel(entry) {
  const exactPunchIn = getEntryExactPunchIn(entry);
  const exactPunchOut = getEntryExactPunchOut(entry);
  const exactStart = exactPunchIn ? formatTimeString(exactPunchIn) : "";
  const exactEnd = exactPunchOut ? formatTimeString(exactPunchOut) : "";
  const hasExactStartDifference = Boolean(exactPunchIn && entry && entry.punchIn && exactPunchIn !== entry.punchIn);
  const hasExactEndDifference = Boolean(exactPunchOut && entry && entry.punchOut && exactPunchOut !== entry.punchOut);

  if (!hasExactStartDifference && !hasExactEndDifference) {
    return "";
  }

  if (entry && entry.punchOut && exactEnd) {
    return t("shared.exactRange", { start: exactStart, end: exactEnd });
  }

  return t("shared.exactClockIn", { time: exactStart });
}

function getProjectDisplayName(project) {
  const projectCode = String(project && project.projectCode || "").trim();
  const projectName = String(project && project.projectName || "").trim();
  return projectName || projectCode;
}

const SAPHIR_PROJECT_COLOR_KEYS = Object.freeze([
  "blue",
  "green",
  "violet",
  "teal",
  "amber",
  "coral",
  "pink",
  "indigo",
  "graphite",
  "mint",
]);

const SAPHIR_PROJECT_MARKER_KEYS = Object.freeze([
  "circle",
  "square",
  "diamond",
  "triangle",
]);

const SAPHIR_PROJECT_IDENTITY_COUNT = SAPHIR_PROJECT_COLOR_KEYS.length * SAPHIR_PROJECT_MARKER_KEYS.length;

function getProjectIdentityBucket(projectCode) {
  let hash = 0;
  String(projectCode || "").trim().toUpperCase().split("").forEach(character => {
    hash = ((hash * 31) + character.charCodeAt(0)) % SAPHIR_PROJECT_IDENTITY_COUNT;
  });
  return Math.abs(hash);
}

function getDefaultProjectColorKey(projectCode) {
  return SAPHIR_PROJECT_COLOR_KEYS[getProjectIdentityBucket(projectCode) % SAPHIR_PROJECT_COLOR_KEYS.length];
}

function getDefaultProjectMarkerKey(projectCode) {
  const markerIndex = Math.floor(getProjectIdentityBucket(projectCode) / SAPHIR_PROJECT_COLOR_KEYS.length);
  return SAPHIR_PROJECT_MARKER_KEYS[markerIndex % SAPHIR_PROJECT_MARKER_KEYS.length];
}

function normalizeProjectColorKey(colorKey, projectCode = "") {
  const candidate = String(colorKey || "").trim().toLowerCase();
  return SAPHIR_PROJECT_COLOR_KEYS.includes(candidate)
    ? candidate
    : getDefaultProjectColorKey(projectCode);
}

function getProjectColorKey(projectOrCode) {
  const isProjectObject = projectOrCode && typeof projectOrCode === "object";
  const projectCode = isProjectObject
    ? String(projectOrCode.projectCode || "").trim()
    : String(projectOrCode || "").trim();
  const colorKey = isProjectObject ? projectOrCode.colorKey : "";
  return normalizeProjectColorKey(colorKey, projectCode);
}

function normalizeProjectMarkerKey(markerKey, projectCode = "") {
  const candidate = String(markerKey || "").trim().toLowerCase();
  return SAPHIR_PROJECT_MARKER_KEYS.includes(candidate)
    ? candidate
    : getDefaultProjectMarkerKey(projectCode);
}

function getProjectMarkerKey(projectOrCode) {
  const isProjectObject = projectOrCode && typeof projectOrCode === "object";
  const projectCode = isProjectObject
    ? String(projectOrCode.projectCode || "").trim()
    : String(projectOrCode || "").trim();
  const markerKey = isProjectObject ? projectOrCode.markerKey : "";
  return normalizeProjectMarkerKey(markerKey, projectCode);
}

function getProjectIdentityFromBucket(bucket) {
  const numericBucket = Number(bucket);
  const safeBucket = Number.isFinite(numericBucket) ? Math.trunc(numericBucket) : 0;
  const normalizedBucket = ((safeBucket % SAPHIR_PROJECT_IDENTITY_COUNT) + SAPHIR_PROJECT_IDENTITY_COUNT) % SAPHIR_PROJECT_IDENTITY_COUNT;
  return {
    colorKey: SAPHIR_PROJECT_COLOR_KEYS[normalizedBucket % SAPHIR_PROJECT_COLOR_KEYS.length],
    markerKey: SAPHIR_PROJECT_MARKER_KEYS[Math.floor(normalizedBucket / SAPHIR_PROJECT_COLOR_KEYS.length)],
  };
}

function getProjectColorStyle(projectOrCode) {
  return `--project-color:var(--project-color-${getProjectColorKey(projectOrCode)})`;
}

function getProjectColorCssValue(projectOrCode) {
  const key = getProjectColorKey(projectOrCode);
  const styles = getComputedStyle(document.documentElement);
  return styles.getPropertyValue(`--project-color-${key}`).trim()
    || styles.getPropertyValue("--accent").trim()
    || "#0868d7";
}

function getProjectChartPointStyle(projectOrCode) {
  const pointStyles = {
    circle: "circle",
    square: "rect",
    diamond: "rectRot",
    triangle: "triangle",
  };
  return pointStyles[getProjectMarkerKey(projectOrCode)] || "circle";
}

function getProjectChartBorderDash(projectOrCode) {
  const borderDashes = {
    circle: [],
    square: [8, 4],
    diamond: [3, 3],
    triangle: [12, 4, 3, 4],
  };
  return borderDashes[getProjectMarkerKey(projectOrCode)].slice();
}

function findProjectByCode(projects, projectCode) {
  const candidate = String(projectCode || "").trim();
  if (!candidate) {
    return null;
  }
  return (Array.isArray(projects) ? projects : []).find(project => (
    String(project && project.projectCode || "").trim() === candidate
  )) || null;
}

function renderProjectColorDot(projectOrCode) {
  const colorKey = getProjectColorKey(projectOrCode);
  const markerKey = getProjectMarkerKey(projectOrCode);
  return `<span class="project-color-dot project-marker-${markerKey}" data-project-color-key="${colorKey}" data-project-marker-key="${markerKey}" style="${getProjectColorStyle(projectOrCode)}" aria-hidden="true"></span>`;
}

function renderProjectIdentityPill(projectOrCode, label = "", extraClass = "", title = "") {
  const isProjectObject = projectOrCode && typeof projectOrCode === "object";
  const projectCode = isProjectObject
    ? String(projectOrCode.projectCode || "").trim()
    : String(projectOrCode || "").trim();
  const displayLabel = String(label || projectCode).trim();
  const safeExtraClass = String(extraClass || "").replace(/[^A-Za-z0-9 _-]/g, "").trim();
  const classes = `project-identity-pill${safeExtraClass ? ` ${safeExtraClass}` : ""}`;
  const titleAttribute = String(title || "").trim() ? ` title="${escapeHtml(title)}"` : "";
  return `<span class="${classes}" style="${getProjectColorStyle(projectOrCode)}"${titleAttribute}>${renderProjectColorDot(projectOrCode)}<span>${escapeHtml(displayLabel)}</span></span>`;
}

function formatProjectCodeAndName(project) {
  const projectCode = String(project && project.projectCode || "").trim();
  const projectName = String(project && project.projectName || "").trim();
  if (!projectCode) {
    return projectName;
  }
  if (!projectName || projectName.toLocaleLowerCase() === projectCode.toLocaleLowerCase()) {
    return projectCode;
  }
  return `${projectCode} | ${projectName}`;
}

function buildProjectOptions(projects, placeholder, selectedValue) {
  const options = Array.isArray(projects) ? projects : [];
  const placeholderText = placeholder || t("shared.project");
  const nextSelectedValue = selectedValue || "";
  return [`<option value="">${escapeHtml(placeholderText)}</option>`]
    .concat(options.map(project => {
      const code = String(project.projectCode || "");
      const selected = code === nextSelectedValue ? " selected" : "";
      return `<option value="${escapeHtml(code)}" data-project-color-key="${escapeHtml(getProjectColorKey(project))}" data-project-marker-key="${escapeHtml(getProjectMarkerKey(project))}"${selected}>${escapeHtml(formatProjectCodeAndName(project))}</option>`;
    }))
    .join("");
}

const FRENCH_LOOKUP_LABEL_CORRECTIONS = Object.freeze({
  "Code de temps supplementaire": "Code de temps supplémentaire",
  "HEURES SUPPLEMENTAIRES, Jour ouvrable regulier": "HEURES SUPPLÉMENTAIRES, Jour ouvrable régulier",
  "HEURES SUPPLEMENTAIRES, Premier jour de repos": "HEURES SUPPLÉMENTAIRES, Premier jour de repos",
  "HEURES SUPPLEMENTAIRES, Deuxieme jour de repos subsequent": "HEURES SUPPLÉMENTAIRES, Deuxième jour de repos subséquent",
  "HEURES SUPPLEMENTAIRES, Conge ferie": "HEURES SUPPLÉMENTAIRES, Congé férié",
  "TEMPS de DEPLACEMENT, Jour ouvrable regulier": "TEMPS de DÉPLACEMENT, Jour ouvrable régulier",
  "TEMPS de DEPLACEMENT, Jour de repos": "TEMPS de DÉPLACEMENT, Jour de repos",
  "INDEMNITE DE PRESENCE": "INDEMNITÉ DE PRÉSENCE",
  "TEMPS PARTIEL, Prime pour le travail effectue lors d'un jour ferie": "TEMPS PARTIEL, Prime pour le travail effectué lors d'un jour férié",
  "En espece": "En espèce",
  "Conge": "Congé",
  "Cout-efficacite": "Coût-efficacité",
  "Absence imprevue": "Absence imprévue",
});

function restoreFrenchLookupDiacritics(value) {
  const text = String(value || "");
  return FRENCH_LOOKUP_LABEL_CORRECTIONS[text] || text;
}

function getLocalizedOptionLabel(item) {
  if (!item) {
    return "";
  }

  const locale = String(getCurrentLocale() || "").toLowerCase();
  if (locale.startsWith("fr")) {
    return restoreFrenchLookupDiacritics(item.labelFr || item.label || item.labelEn || item.descriptionFr || item.description || item.code || "");
  }

  return String(item.labelEn || item.label || item.labelFr || item.descriptionEn || item.description || item.code || "");
}

function buildCodeOptions(options, placeholder, selectedValue, optionsConfig = {}) {
  const items = Array.isArray(options) ? options : [];
  const placeholderText = placeholder || "";
  const nextSelectedValue = selectedValue || "";
  const includePlaceholder = optionsConfig.includePlaceholder !== false;
  const codeProperty = optionsConfig.codeProperty || "code";
  const blankLabel = optionsConfig.blankLabel || placeholderText;
  const renderedOptions = includePlaceholder
    ? [`<option value="">${escapeHtml(placeholderText)}</option>`]
    : [];

  items.forEach(item => {
    const code = String(item && item[codeProperty] != null ? item[codeProperty] : "");
    const label = getLocalizedOptionLabel(item) || code || blankLabel;
    const selected = code === nextSelectedValue ? " selected" : "";
    const text = code ? `${code} | ${label}` : label;
    renderedOptions.push(`<option value="${escapeHtml(code)}"${selected}>${escapeHtml(text)}</option>`);
  });

  return renderedOptions.join("");
}

function buildOvertimeCodeOptions(overtimeCodes, placeholder, selectedValue) {
  return buildCodeOptions(overtimeCodes, placeholder || t("shared.overtimeCode"), selectedValue, {
    includePlaceholder: false,
    blankLabel: t("shared.overtimeCode"),
  });
}

function buildPaymentOptionOptions(paymentOptions, placeholder, selectedValue) {
  return buildCodeOptions(paymentOptions, placeholder || t("shared.paymentOption"), selectedValue, {
    includePlaceholder: true,
  });
}

function buildReasonCodeOptions(reasonCodes, placeholder, selectedValue) {
  return buildCodeOptions(reasonCodes, placeholder || t("shared.reasonCode"), selectedValue, {
    includePlaceholder: false,
    blankLabel: t("shared.reasonCode"),
  });
}

function getLookupOptionByCode(collection, code) {
  return (Array.isArray(collection) ? collection : []).find(item => String(item.code || "") === String(code || "")) || null;
}

function formatPaymentOptionValue(code) {
  const cached = overtimeEntryLookupCache.payload;
  const option = cached ? getLookupOptionByCode(cached.paymentOptions, code) : null;
  if (option) {
    return getLocalizedOptionLabel(option);
  }

  const normalizedCode = String(code || "");
  if (normalizedCode === "cash") {
    return String(getCurrentLocale() || "").toLowerCase().startsWith("fr") ? "En espèce" : "Cash";
  }
  if (normalizedCode === "leave") {
    return String(getCurrentLocale() || "").toLowerCase().startsWith("fr") ? "Congé" : "Leave";
  }
  return normalizedCode;
}

async function downloadGc179FdfExport(config) {
  const monthKey = String(config && config.monthKey || "").trim();
  const employeeCode = String(config && config.employeeCode || "").trim();
  const isSelfExport = Boolean(config && config.self);
  const path = isSelfExport
    ? `self/gc179-open?month=${encodeURIComponent(monthKey)}`
    : `employee/${encodeURIComponent(employeeCode)}/gc179-open?month=${encodeURIComponent(monthKey)}`;

  if (!monthKey || (!isSelfExport && !employeeCode)) {
    showToast(t("export.gc179DownloadError", { message: t("error.missingRequiredFields") }), "error");
    return false;
  }

  try {
    const response = await fetch(apiUrl + path, { method: "POST" });
    const payload = await parseResponse(response);
    showToast(t("export.gc179LaunchSuccess", {
      count: payload && payload.partCount ? payload.partCount : 1,
    }), "success");
    return true;
  } catch (error) {
    showToast(t("export.gc179DownloadError", { message: error.message || error }), "error");
    return false;
  }
}

async function fetchOvertimeEntryLookups(forceRefresh = false) {
  const currentApiUrl = window.apiUrl || "";
  const scopeKey = getLookupCacheScopeKey();
  if (!forceRefresh && overtimeEntryLookupCache.payload && overtimeEntryLookupCache.apiUrl === currentApiUrl && overtimeEntryLookupCache.scopeKey === scopeKey) {
    return overtimeEntryLookupCache.payload;
  }

  const response = await fetch(apiUrl + "self/options");
  const payload = await parseResponse(response);
  const normalizedPayload = {
    projects: Array.isArray(payload && payload.projects) ? payload.projects : [],
    overtimeCodes: Array.isArray(payload && payload.overtimeCodes) ? payload.overtimeCodes : [],
    paymentOptions: Array.isArray(payload && payload.paymentOptions) ? payload.paymentOptions : [],
    reasonCodes: Array.isArray(payload && payload.reasonCodes) ? payload.reasonCodes : [],
    timeEntryTypes: Array.isArray(payload && payload.timeEntryTypes) ? payload.timeEntryTypes : ["overtime"],
  };

  overtimeEntryLookupCache.apiUrl = currentApiUrl;
  overtimeEntryLookupCache.scopeKey = scopeKey;
  overtimeEntryLookupCache.payload = normalizedPayload;
  return normalizedPayload;
}

async function fetchScopedProjects(forceRefresh = false) {
  const currentApiUrl = window.apiUrl || "";
  const scopeKey = getLookupCacheScopeKey();
  if (!forceRefresh && scopedProjectLookupCache.payload && scopedProjectLookupCache.apiUrl === currentApiUrl && scopedProjectLookupCache.scopeKey === scopeKey) {
    return scopedProjectLookupCache.payload;
  }

  const response = await fetch(apiUrl + "projects");
  const payload = await parseResponse(response);
  const projects = Array.isArray(payload) ? payload : [];
  scopedProjectLookupCache.apiUrl = currentApiUrl;
  scopedProjectLookupCache.scopeKey = scopeKey;
  scopedProjectLookupCache.payload = projects;
  return projects;
}

function clearOvertimeEntryLookupCache() {
  overtimeEntryLookupCache.apiUrl = null;
  overtimeEntryLookupCache.scopeKey = null;
  overtimeEntryLookupCache.payload = null;
}

function clearScopedProjectLookupCache() {
  scopedProjectLookupCache.apiUrl = null;
  scopedProjectLookupCache.scopeKey = null;
  scopedProjectLookupCache.payload = null;
}

function clearLookupCaches() {
  clearOvertimeEntryLookupCache();
  clearScopedProjectLookupCache();
}

function normalizeToastMessage(message) {
  const rawMessage = String(message == null ? "" : message).replace(/<br\s*\/?>/gi, " | ");
  const scratch = document.createElement("div");
  scratch.innerHTML = rawMessage;
  return scratch.textContent.replace(/\s+/g, " ").trim();
}

function localizeAuditHumanDate(dateLabel) {
  const rawDate = String(dateLabel || "").trim();
  if (!rawDate) {
    return t("shared.unknownDate");
  }

  const parsedDate = /^\d{4}-\d{2}-\d{2}$/.test(rawDate) ? parseLocalDate(rawDate) : new Date(rawDate);
  if (!parsedDate || Number.isNaN(parsedDate.getTime())) {
    return rawDate;
  }

  return parsedDate.toLocaleDateString(getCurrentLocale(), { year: "numeric", month: "long", day: "numeric" });
}

function buildTranslatedAuditUpdateFragments(message) {
  const rawMessage = String(message || "");
  const fragments = [];
  const dateMatch = rawMessage.match(/Date from <strong>(\d{4}-\d{2}-\d{2})<\/strong> to <strong>(\d{4}-\d{2}-\d{2})<\/strong>\./i);
  const punchInMatch = rawMessage.match(/Punch In from <strong>(.*?)<\/strong> to <strong>(.*?)<\/strong>\./i);
  const punchOutMatch = rawMessage.match(/Punch Out from <strong>(.*?)<\/strong> to <strong>(.*?)<\/strong>\./i);
  const punchOutRecordedMatch = rawMessage.match(/Punch Out recorded at <strong>(.*?)<\/strong>\./i);
  const projectUpdatedMatch = /Project Code updated\./i.test(rawMessage);
  const overtimeUpdatedMatch = /Overtime Code updated\./i.test(rawMessage);
  const paymentUpdatedMatch = /Payment option updated\./i.test(rawMessage);
  const reasonUpdatedMatch = /Reason code updated\./i.test(rawMessage);

  if (dateMatch) {
    fragments.push(t("history.fragment.dateFromTo", {
      from: localizeAuditHumanDate(dateMatch[1]),
      to: localizeAuditHumanDate(dateMatch[2]),
    }));
  }
  if (punchInMatch) {
    fragments.push(t("history.fragment.punchInFromTo", { from: punchInMatch[1], to: punchInMatch[2] }));
  }
  if (punchOutMatch) {
    fragments.push(t("history.fragment.punchOutFromTo", { from: punchOutMatch[1], to: punchOutMatch[2] }));
  }
  if (punchOutRecordedMatch) {
    fragments.push(t("history.fragment.punchOutRecorded", { time: punchOutRecordedMatch[1] }));
  }
  if (projectUpdatedMatch) {
    fragments.push(t("history.fragment.projectCodeUpdated"));
  }
  if (overtimeUpdatedMatch) {
    fragments.push(t("history.fragment.overtimeCodeUpdated"));
  }
  if (paymentUpdatedMatch) {
    fragments.push(t("history.fragment.paymentOptionUpdated"));
  }
  if (reasonUpdatedMatch) {
    fragments.push(t("history.fragment.reasonCodeUpdated"));
  }

  return fragments.join(" ");
}

function translateAuditMessage(message) {
  const rawMessage = String(message == null ? "" : message).trim();
  if (!rawMessage) {
    return t("shared.noMessage");
  }

  let match = rawMessage.match(/^Added an entry on ([A-Za-z]+ \d{1,2}, \d{4}), starting at <strong>(.*?)<\/strong> and finishing at <strong>(.*?)<\/strong> for project <strong>(.*?)<\/strong>, overtime code <strong>(.*?)<\/strong>, payment <strong>(.*?)<\/strong>, and reason <strong>(.*?)<\/strong>\.$/i);
  if (match) {
    return t("history.message.addedEntryWithOptions", {
      date: localizeAuditHumanDate(match[1]),
      start: match[2],
      end: match[3],
      projectCode: match[4],
      overtimeCode: match[5] || t("shared.overtimeCode"),
      paymentOption: formatPaymentOptionValue(match[6]),
      reasonCode: match[7] || t("shared.reasonCode"),
    });
  }

  match = rawMessage.match(/^Added an entry on ([A-Za-z]+ \d{1,2}, \d{4}), starting at <strong>(.*?)<\/strong> and finishing at <strong>(.*?)<\/strong> for project <strong>(.*?)<\/strong> and overtime code <strong>(.*?)<\/strong>\.$/i);
  if (match) {
    return t("history.message.addedEntry", {
      date: localizeAuditHumanDate(match[1]),
      start: match[2],
      end: match[3],
      projectCode: match[4],
      overtimeCode: match[5] || t("shared.overtimeCode"),
    });
  }

  match = rawMessage.match(/^Updated an entry on ([A-Za-z]+ \d{1,2}, \d{4}),\s*(.*)$/i);
  if (match) {
    const translatedFragments = buildTranslatedAuditUpdateFragments(match[2]);
    if (translatedFragments) {
      return t("history.message.updatedEntry", {
        date: localizeAuditHumanDate(match[1]),
        details: translatedFragments,
      });
    }
  }

  match = rawMessage.match(/^Updated an entry on ([A-Za-z]+ \d{1,2}, \d{4}) from <strong>(.*?)<\/strong> to <strong>(.*?)<\/strong>\.\s*(.*)$/i);
  if (match) {
    const translatedFragments = buildTranslatedAuditUpdateFragments(match[4]);
    if (translatedFragments) {
      return t("history.message.updatedEntryWithSpan", {
        date: localizeAuditHumanDate(match[1]),
        start: match[2],
        end: match[3],
        details: translatedFragments,
      });
    }

    return t("history.message.updatedEntryWithSpanSimple", {
      date: localizeAuditHumanDate(match[1]),
      start: match[2],
      end: match[3],
    });
  }

  match = rawMessage.match(/^Entry on ([A-Za-z]+ \d{1,2}, \d{4}) updated successfully\.$/i);
  if (match) {
    return t("history.message.updatedEntrySimple", {
      date: localizeAuditHumanDate(match[1]),
    });
  }

  match = rawMessage.match(/^Deleted an entry on ([A-Za-z]+ \d{1,2}, \d{4}) from <strong>(.*?)<\/strong> to <strong>(.*?)<\/strong>\.(?: Reason: (.*))?$/i);
  if (match) {
    if (match[4]) {
      return t("history.message.deletedEntryReason", {
        date: localizeAuditHumanDate(match[1]),
        start: match[2],
        end: match[3],
        reason: match[4],
      });
    }
    return t("history.message.deletedEntry", {
      date: localizeAuditHumanDate(match[1]),
      start: match[2],
      end: match[3],
    });
  }

  match = rawMessage.match(/^Deleted an entry on ([A-Za-z]+ \d{1,2}, \d{4}) starting at <strong>(.*?)<\/strong>\.(?: Reason: (.*))?$/i);
  if (match) {
    if (match[3]) {
      return t("history.message.deletedEntryReasonLegacy", {
        date: localizeAuditHumanDate(match[1]),
        time: match[2],
        reason: match[3],
      });
    }
    return t("history.message.deletedEntryLegacy", {
      date: localizeAuditHumanDate(match[1]),
      time: match[2],
    });
  }

  match = rawMessage.match(/^Approved an entry on ([A-Za-z]+ \d{1,2}, \d{4}) from <strong>(.*?)<\/strong> to <strong>(.*?)<\/strong>\.$/i);
  if (match) {
    return t("history.message.approvedEntry", {
      date: localizeAuditHumanDate(match[1]),
      start: match[2],
      end: match[3],
    });
  }

  match = rawMessage.match(/^Approved an entry on ([A-Za-z]+ \d{1,2}, \d{4}) starting at <strong>(.*?)<\/strong>\.$/i);
  if (match) {
    return t("history.message.approvedEntryLegacy", {
      date: localizeAuditHumanDate(match[1]),
      time: match[2],
    });
  }

  match = rawMessage.match(/^Rejected an entry on ([A-Za-z]+ \d{1,2}, \d{4}) from <strong>(.*?)<\/strong> to <strong>(.*?)<\/strong>\.$/i);
  if (match) {
    return t("history.message.rejectedEntry", {
      date: localizeAuditHumanDate(match[1]),
      start: match[2],
      end: match[3],
    });
  }

  match = rawMessage.match(/^Rejected an entry on ([A-Za-z]+ \d{1,2}, \d{4}) starting at <strong>(.*?)<\/strong>\.$/i);
  if (match) {
    return t("history.message.rejectedEntryLegacy", {
      date: localizeAuditHumanDate(match[1]),
      time: match[2],
    });
  }

  match = rawMessage.match(/^Created a sign-in account and set a password for <strong>(.*?)<\/strong>\.$/i);
  if (match) {
    return t("history.message.createdAccount", { name: match[1] });
  }

  match = rawMessage.match(/^Reset the password for <strong>(.*?)<\/strong> and required a password change at next sign-in\.$/i);
  if (match) {
    return t("history.message.resetPasswordRequireChange", { name: match[1] });
  }

  match = rawMessage.match(/^Reset the password for <strong>(.*?)<\/strong>\.$/i);
  if (match) {
    return t("history.message.resetPassword", { name: match[1] });
  }

  match = rawMessage.match(/^Created an employee profile for <strong>(.*?)<\/strong> with code <strong>(.*?)<\/strong>\.$/i);
  if (match) {
    return t("history.message.employeeCreated", { name: match[1], code: match[2] });
  }

  match = rawMessage.match(/^Updated the employee profile for <strong>(.*?)<\/strong>\.$/i);
  if (match) {
    return t("history.message.employeeUpdated", { name: match[1] });
  }

  match = rawMessage.match(/^Removed employee access for <strong>(.*?)<\/strong>\.$/i);
  if (match) {
    return t("history.message.employeeRemoved", { name: match[1] });
  }

  match = rawMessage.match(/^Reinstated employee access for <strong>(.*?)<\/strong>\.$/i);
  if (match) {
    return t("history.message.employeeRestored", { name: match[1] });
  }

  match = rawMessage.match(/^Created a project named <strong>(.*?)<\/strong> with code <strong>(.*?)<\/strong>\.$/i);
  if (match) {
    return t("history.message.projectCreated", { name: match[1], code: match[2] });
  }

  match = rawMessage.match(/^Created a project with code <strong>(.*?)<\/strong>\.$/i);
  if (match) {
    return t("history.message.projectCreatedWithoutName", { code: match[1] });
  }

  match = rawMessage.match(/^Updated the project <strong>(.*?)<\/strong>\.$/i);
  if (match) {
    return t("history.message.projectUpdated", { code: match[1] });
  }

  match = rawMessage.match(/^Removed the project <strong>(.*?)<\/strong>\.$/i);
  if (match) {
    return t("history.message.projectRemoved", { code: match[1] });
  }

  return rawMessage;
}

function sanitizeAuditHtml(message) {
  const scratch = document.createElement("div");
  scratch.innerHTML = String(message == null ? "" : message);

  function renderNode(node) {
    if (node.nodeType === Node.TEXT_NODE) {
      return escapeHtml(node.textContent || "").replace(/\r?\n/g, "<br>");
    }

    if (node.nodeType !== Node.ELEMENT_NODE) {
      return "";
    }

    const tagName = String(node.tagName || "").toLowerCase();
    if (tagName === "br") {
      return "<br>";
    }

    const childHtml = Array.from(node.childNodes || []).map(renderNode).join("");
    if (tagName === "strong") {
      return `<strong>${childHtml}</strong>`;
    }

    return childHtml;
  }

  return Array.from(scratch.childNodes || []).map(renderNode).join("");
}

function renderAuditMessage(message) {
  return sanitizeAuditHtml(translateAuditMessage(message));
}

function auditMessageToText(message) {
  const scratch = document.createElement("div");
  scratch.innerHTML = renderAuditMessage(message);
  return scratch.textContent.replace(/\s+/g, " ").trim();
}

function getExplicitHistoryAuthorName(entry) {
  if (!entry) {
    return "";
  }

  const candidates = [entry.author, entry.actor, entry.performedBy, entry.authorName];
  for (const candidate of candidates) {
    const normalized = String(candidate || "").trim();
    if (normalized) {
      return normalized;
    }
  }

  return "";
}

function getHistoryAuthorName(entry) {
  return getExplicitHistoryAuthorName(entry) || t("history.authorNotRecorded");
}

function isEmployeeTargetedHistoryEntry(entry) {
  const rawMessage = String(entry && entry.message || "");
  return /^(Added|Updated|Deleted|Approved|Rejected) an entry on /i.test(rawMessage)
    || /employee (profile|access)/i.test(rawMessage)
    || /^Created a sign-in account/i.test(rawMessage)
    || /^Reset the password/i.test(rawMessage);
}

function getHistorySubjectName(entry) {
  if (!entry || !isEmployeeTargetedHistoryEntry(entry)) {
    return "";
  }

  const candidates = [entry.targetEmployee, entry.subjectEmployee, entry.employee];
  const explicitAuthorName = getExplicitHistoryAuthorName(entry);
  for (const candidate of candidates) {
    const normalized = String(candidate || "").trim();
    if (!normalized) {
      continue;
    }

    if (explicitAuthorName && normalized.toLowerCase() === explicitAuthorName.toLowerCase()) {
      continue;
    }

    return normalized;
  }

  return "";
}

function renderHistorySubjectLine(entry) {
  const subjectName = getHistorySubjectName(entry);
  if (!subjectName) {
    return "";
  }

  return `<div class="timeline-card-subject">${escapeHtml(t("history.concernedEmployee", { name: subjectName }))}</div>`;
}

function getHistorySearchText(entry) {
  return [
    getHistoryAuthorName(entry),
    getHistorySubjectName(entry),
    entry && entry.authorUsername,
    entry && entry.authorRole,
    entry && entry.employee,
    entry && entry.timestamp,
    entry && entry.action,
    translateHistoryAction(entry && entry.action || "event"),
    auditMessageToText(entry && entry.message || ""),
    formatDateToWords(String(entry && entry.timestamp || "").split(" ")[0] || ""),
  ].join(" ").toLowerCase();
}

function showToast(message, type = "success") {
  const toastContainer = document.getElementById("toastContainer");
  if (!toastContainer) {
    return;
  }

  const tone = type === "error" ? "danger" : type === "info" ? "info" : type;
  const iconClass = tone === "success"
    ? "fa-circle-check"
    : tone === "danger"
      ? "fa-circle-xmark"
      : "fa-circle-info";

  const toast = document.createElement("div");
  toast.className = "toast custom-toast";
  toast.setAttribute("role", "alert");
  toast.setAttribute("aria-live", "assertive");
  toast.setAttribute("aria-atomic", "true");

  toast.innerHTML = `
    <div class="toast-header">
      <i class="fa-solid ${iconClass} me-2 text-${tone}"></i>
      <strong class="me-auto">${escapeHtml(t("app.name"))}</strong>
      <small class="text-muted">${escapeHtml(t("shared.now"))}</small>
      <button type="button" class="btn-close" data-bs-dismiss="toast" aria-label="${escapeHtml(t("shared.close"))}"></button>
    </div>
    <div class="toast-body">${escapeHtml(normalizeToastMessage(message))}</div>
  `;

  toastContainer.appendChild(toast);
  const bsToast = new bootstrap.Toast(toast, { delay: 3600 });
  bsToast.show();
  toast.addEventListener("hidden.bs.toast", () => {
    toast.remove();
  });
}
