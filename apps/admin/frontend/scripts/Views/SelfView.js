const selfViewState = {
  entries: [],
  projects: [],
  overtimeCodes: [],
  lookupsLoaded: false,
  selectedProjectCode: localStorage.getItem("selfSelectedProjectCode") || "",
  selectedOvertimeCode: localStorage.getItem("selfSelectedOvertimeCode") || "",
  currentMonthKey: "",
  expandedNotes: {},
};

const SELF_PROJECT_STORAGE_KEY = "selfSelectedProjectCode";
const SELF_OVERTIME_CODE_STORAGE_KEY = "selfSelectedOvertimeCode";

function showSelfConfirmationModal(title, message, callback) {
  const modalTitle = document.getElementById("selfConfirmModalLabel");
  const modalBody = document.getElementById("selfConfirmModalBody");
  const confirmButton = document.getElementById("selfConfirmModalConfirmBtn");

  modalTitle.innerText = title;
  modalBody.innerHTML = message;

  const replacementButton = confirmButton.cloneNode(true);
  confirmButton.parentNode.replaceChild(replacementButton, confirmButton);

  replacementButton.addEventListener("click", async () => {
    await callback();
    const confirmModal = bootstrap.Modal.getInstance(document.getElementById("selfConfirmModal"));
    confirmModal.hide();
  });

  const confirmModal = new bootstrap.Modal(document.getElementById("selfConfirmModal"));
  confirmModal.show();
}

function formatPromptTime(date) {
  return date.toLocaleTimeString(getI18nLocale(), { hour: "2-digit", minute: "2-digit" });
}

function persistSelfSelections() {
  if (selfViewState.selectedProjectCode) {
    localStorage.setItem(SELF_PROJECT_STORAGE_KEY, selfViewState.selectedProjectCode);
  } else {
    localStorage.removeItem(SELF_PROJECT_STORAGE_KEY);
  }

  if (selfViewState.selectedOvertimeCode) {
    localStorage.setItem(SELF_OVERTIME_CODE_STORAGE_KEY, selfViewState.selectedOvertimeCode);
  } else {
    localStorage.removeItem(SELF_OVERTIME_CODE_STORAGE_KEY);
  }
}

function updateSelfPunchAvailability() {
  const primaryButton = document.getElementById("selfPrimaryPunchButton");
  const punchType = primaryButton.getAttribute("data-punch-type") || "in";

  if (punchType === "out") {
    primaryButton.disabled = false;
    return;
  }

  primaryButton.disabled = !selfViewState.lookupsLoaded
    || !selfViewState.selectedProjectCode
    || !selfViewState.selectedOvertimeCode;
}

function renderSelfPunchSelectors() {
  const projectSelect = document.getElementById("selfProjectCodeSelect");
  const overtimeCodeSelect = document.getElementById("selfOvertimeCodeSelect");

  projectSelect.innerHTML = buildProjectOptions(selfViewState.projects, t("shared.project"), selfViewState.selectedProjectCode);
  overtimeCodeSelect.innerHTML = buildOvertimeCodeOptions(selfViewState.overtimeCodes, t("shared.overtimeCode"), selfViewState.selectedOvertimeCode);

  if (selfViewState.selectedProjectCode && projectSelect.value !== selfViewState.selectedProjectCode) {
    selfViewState.selectedProjectCode = "";
  }

  if (selfViewState.selectedOvertimeCode && overtimeCodeSelect.value !== selfViewState.selectedOvertimeCode) {
    selfViewState.selectedOvertimeCode = "";
  }

  projectSelect.value = selfViewState.selectedProjectCode;
  overtimeCodeSelect.value = selfViewState.selectedOvertimeCode;

  persistSelfSelections();
  updateSelfPunchAvailability();
}

async function loadSelfLookups(forceRefresh = false) {
  const payload = await fetchOvertimeEntryLookups(forceRefresh);
  selfViewState.projects = payload.projects;
  selfViewState.overtimeCodes = payload.overtimeCodes;
  selfViewState.lookupsLoaded = true;
  renderSelfPunchSelectors();
}

function applySelfBootstrap(payload) {
  selfViewState.projects = Array.isArray(payload && payload.projects) ? payload.projects : [];
  selfViewState.overtimeCodes = Array.isArray(payload && payload.overtimeCodes) ? payload.overtimeCodes : [];
  selfViewState.lookupsLoaded = true;
  renderSelfPunchSelectors();
}

function initializeSelfView() {
  renderSelfPunchSelectors();
}

window.initializeSelfView = initializeSelfView;

function toSelfMonthKey(dateValue) {
  const parsed = dateValue instanceof Date ? dateValue : parseLocalDate(dateValue);
  if (!parsed) {
    const now = new Date();
    return `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, "0")}`;
  }

  return `${parsed.getFullYear()}-${String(parsed.getMonth() + 1).padStart(2, "0")}`;
}

function shiftSelfMonthKey(monthKey, delta) {
  const [year, month] = String(monthKey || "").split("-").map(Number);
  const base = new Date(Number.isNaN(year) ? new Date().getFullYear() : year, Number.isNaN(month) ? new Date().getMonth() : month - 1, 1);
  base.setMonth(base.getMonth() + delta);
  return toSelfMonthKey(base);
}

function getSelfCalendarWeekdayLabels() {
  const sunday = new Date(2026, 0, 4);
  return Array.from({ length: 7 }, (_, index) => {
    const labelDate = new Date(sunday);
    labelDate.setDate(sunday.getDate() + index);
    return labelDate.toLocaleDateString(getCurrentLocale(), { weekday: "short" });
  });
}

function getDefaultSelfMonthKey(entries) {
  if (selfViewState.currentMonthKey) {
    return selfViewState.currentMonthKey;
  }

  if (Array.isArray(entries) && entries.length > 0) {
    const latest = sortEntriesByDateTime(entries, true)[0];
    return toSelfMonthKey(latest.date);
  }

  return toSelfMonthKey(new Date());
}

function buildSelfMonthBoard(entries, activeMonthKey) {
  const [activeYear] = String(activeMonthKey || "").split("-").map(Number);
  const year = Number.isNaN(activeYear) ? new Date().getFullYear() : activeYear;
  const monthCounts = {};

  (entries || []).forEach(entry => {
    const monthKey = toSelfMonthKey(entry.date);
    if (!monthKey.startsWith(`${year}-`)) {
      return;
    }
    monthCounts[monthKey] = (monthCounts[monthKey] || 0) + 1;
  });

  return Array.from({ length: 12 }, (_, index) => {
    const date = new Date(year, index, 1);
    const monthKey = toSelfMonthKey(date);
    return {
      key: monthKey,
      label: date.toLocaleDateString(getCurrentLocale(), { month: "short" }),
      count: monthCounts[monthKey] || 0,
      active: monthKey === activeMonthKey,
    };
  });
}

function groupSelfEntriesByDate(entries) {
  return (entries || []).reduce((accumulator, entry) => {
    if (!accumulator[entry.date]) {
      accumulator[entry.date] = [];
    }
    accumulator[entry.date].push(entry);
    return accumulator;
  }, {});
}

function getSelfEntryKey(entry) {
  return `${entry.entryId || ""}__${entry.date || ""}__${entry.punchIn || ""}`;
}

function getSelfCalendarEntrySeconds(entry) {
  if (isEntryOpen(entry)) {
    const startedAt = toEntryDateTime(entry);
    return Math.max(0, Math.floor((Date.now() - startedAt.getTime()) / 1000));
  }
  return timeStringToSeconds(entry && entry.overtime);
}

function updateSelfSummaryMetrics(allEntries) {
  const now = new Date();
  const currentMonthEntries = allEntries.filter(entry => {
    const entryDate = new Date(`${entry.date}T00:00:00`);
    return entryDate.getMonth() === now.getMonth() && entryDate.getFullYear() === now.getFullYear();
  });
  const totalMonthSeconds = currentMonthEntries.reduce((accumulator, entry) => accumulator + timeStringToSeconds(entry.overtime), 0);
  const pendingCount = allEntries.filter(entry => String(entry.status || "pending").toLowerCase() === "pending").length;

  document.getElementById("selfTotalOvertime").innerText = secondsToDurationLabel(totalMonthSeconds);
  document.getElementById("selfPendingApprovals").innerText = pendingCount;
}

function updateSelfStatus(entries) {
  const primaryButton = document.getElementById("selfPrimaryPunchButton");
  const punchState = document.getElementById("selfPunchStateText");
  const statusMessage = document.getElementById("selfStatusMessage");
  const currentStatusValue = document.getElementById("selfCurrentStatusValue");
  const currentStatusHint = document.getElementById("selfCurrentStatusHint");
  const heroText = document.getElementById("selfHeroText");
  const selectionSummary = document.getElementById("selfSelectionSummary");
  const punchSelectors = document.getElementById("selfPunchSelectors");
  const latestEntry = getLatestEntry(entries);
  const activeEntry = latestEntry && isEntryOpen(latestEntry) ? latestEntry : null;

  if (activeEntry) {
    const startedAt = toEntryDateTime(activeEntry);
    const elapsedSeconds = Math.max(0, Math.floor((Date.now() - startedAt.getTime()) / 1000));
    primaryButton.textContent = t("self.endOvertime");
    primaryButton.dataset.punchType = "out";
    punchState.textContent = t("self.startedAt", {
      date: formatDateLabel(activeEntry.date),
      time: formatTimeString(getEntryExactPunchIn(activeEntry)),
    });
    statusMessage.textContent = t("self.openDuration", { duration: secondsToDurationLabel(elapsedSeconds) });
    currentStatusValue.textContent = t("status.clockedIn");
    currentStatusHint.textContent = getEntryContextLabel(activeEntry);
    selectionSummary.textContent = getEntryContextLabel(activeEntry);
    punchSelectors.classList.add("d-none");
    if (heroText) {
      heroText.textContent = t("self.hero.live");
    }
    updateSelfPunchAvailability();
    return;
  }

  primaryButton.textContent = t("self.startOvertime");
  primaryButton.dataset.punchType = "in";
  punchSelectors.classList.remove("d-none");
  selectionSummary.textContent = [selfViewState.selectedProjectCode, selfViewState.selectedOvertimeCode].filter(Boolean).join(" | ");

  if (!latestEntry) {
    punchState.textContent = t("status.noHistory");
    statusMessage.textContent = t("status.idle");
    currentStatusValue.textContent = t("status.offClock");
    currentStatusHint.textContent = t("shared.ready");
    if (heroText) {
      heroText.textContent = t("self.hero.idle");
    }
    updateSelfPunchAvailability();
    return;
  }

  const latestStatus = String(latestEntry.status || "pending").toLowerCase();
  const timeRange = `${formatTimeString(getEntryExactPunchIn(latestEntry))}${latestEntry.punchOut ? ` -> ${formatTimeString(getEntryExactPunchOut(latestEntry))}` : ""}`;
  punchState.textContent = t("self.lastEntry", {
    date: formatDateLabel(latestEntry.date),
    timeRange,
  });
  currentStatusValue.textContent = latestStatus === "rejected"
    ? t("status.needsAttention")
    : latestStatus === "approved"
      ? t("status.readyForNext")
      : t("status.awaitingApproval");
  currentStatusHint.textContent = latestStatus === "rejected"
    ? t("status.rejected")
    : latestStatus === "approved"
      ? t("status.approved")
      : t("status.pending");
  statusMessage.textContent = latestStatus === "rejected"
    ? t("shared.reviewRequired")
    : latestStatus === "approved"
      ? t("shared.ready")
      : t("shared.waiting");
  if (heroText) {
    heroText.textContent = latestStatus === "rejected"
      ? t("self.hero.review")
      : latestStatus === "approved"
        ? t("self.hero.ready")
        : t("self.hero.pending");
  }
  updateSelfPunchAvailability();
}

function renderSelfEntries(entries) {
  const container = document.getElementById("selfEntriesContainer");
  const allEntries = Array.isArray(entries) ? sortEntriesByDateTime(entries, true) : [];
  const liveEntries = sortEntriesByDateTime(allEntries.filter(entry => isEntryOpen(entry)), true);
  const activeMonthKey = getDefaultSelfMonthKey(allEntries);
  selfViewState.currentMonthKey = activeMonthKey;

  const [activeYear, activeMonth] = activeMonthKey.split("-").map(Number);
  const monthEntries = sortEntriesByDateTime(allEntries.filter(entry => toSelfMonthKey(entry.date) === activeMonthKey), true);
  const monthBoard = buildSelfMonthBoard(allEntries, activeMonthKey);

  const firstDay = new Date(activeYear, activeMonth - 1, 1);
  const lastDay = new Date(activeYear, activeMonth, 0);
  const gridStart = new Date(firstDay);
  gridStart.setDate(firstDay.getDate() - firstDay.getDay());
  const gridEnd = new Date(lastDay);
  gridEnd.setDate(lastDay.getDate() + (6 - lastDay.getDay()));

  const grouped = groupSelfEntriesByDate(monthEntries);
  const dayCells = [];
  const cursor = new Date(gridStart);

  while (cursor <= gridEnd) {
    const dateKey = `${cursor.getFullYear()}-${String(cursor.getMonth() + 1).padStart(2, "0")}-${String(cursor.getDate()).padStart(2, "0")}`;
    const dayEntries = sortEntriesByDateTime(grouped[dateKey] || [], true);
    const isCurrentMonth = cursor.getMonth() === (activeMonth - 1);
    const totalDaySeconds = dayEntries.reduce((accumulator, entry) => accumulator + getSelfCalendarEntrySeconds(entry), 0);

    const entryMarkup = dayEntries.map(entry => {
      const statusTone = getStatusTone(entry.status);
      const note = String(entry.message || "").trim();
      const entryKey = getSelfEntryKey(entry);
      const isExpanded = Boolean(selfViewState.expandedNotes[entryKey]);
      const noteOverflow = note.length > 120;
      const exactTimeLabel = getEntryExactTimeLabel(entry);

      return `
        <div class="calendar-entry">
          <div class="calendar-entry-main">
            <span class="calendar-entry-time">${escapeHtml(getEntryRoundedTimeRange(entry))}</span>
            <span class="status-badge ${escapeHtml(statusTone)}">${escapeHtml(translateStatus(entry.status || "pending"))}</span>
          </div>
          <div class="calendar-entry-meta">${escapeHtml(getEntryContextLabel(entry))}</div>
          ${exactTimeLabel ? `<div class="calendar-entry-meta">${escapeHtml(exactTimeLabel)}</div>` : ""}
          ${note ? `
            <div class="calendar-entry-note${isExpanded ? " is-expanded" : ""}">
              <div class="calendar-entry-note-label">${escapeHtml(t("employees.managerNoteLabel"))}</div>
              <div class="calendar-entry-note-text">${escapeHtml(note)}</div>
              ${noteOverflow ? `<button type="button" class="calendar-note-toggle" data-self-note-key="${escapeHtml(entryKey)}">${escapeHtml(t(isExpanded ? "action.less" : "action.more"))}</button>` : ""}
            </div>
          ` : ""}
        </div>
      `;
    }).join("");

    dayCells.push(`
      <div class="calendar-day${isCurrentMonth ? "" : " is-muted"}${dayEntries.length > 0 ? " has-entries" : ""}">
        <div class="calendar-day-header">
          <span class="calendar-day-number">${cursor.getDate()}</span>
          ${dayEntries.length > 0 ? `<span class="calendar-day-total">${escapeHtml(secondsToDurationLabel(totalDaySeconds))}</span>` : ""}
        </div>
        <div class="calendar-day-body">${entryMarkup}</div>
      </div>
    `);

    cursor.setDate(cursor.getDate() + 1);
  }

  const monthTotalSeconds = monthEntries.reduce((accumulator, entry) => accumulator + getSelfCalendarEntrySeconds(entry), 0);
  const liveEntriesMarkup = liveEntries.length > 0
    ? `
      <div class="calendar-live-strip">
        ${liveEntries.map(entry => `
          <article class="calendar-live-card">
            <div class="calendar-entry-main">
              <span class="calendar-entry-time">${escapeHtml(formatDateLabel(entry.date))} | ${escapeHtml(formatTimeString(getEntryExactPunchIn(entry)))} -> ${escapeHtml(t("shared.inProgress"))}</span>
              <span class="status-badge approved">${escapeHtml(t("shared.live"))}</span>
            </div>
            <div class="calendar-entry-meta">${escapeHtml(getEntryContextLabel(entry))}</div>
            <div class="calendar-entry-meta">${escapeHtml(secondsToDurationLabel(getSelfCalendarEntrySeconds(entry)))}</div>
          </article>
        `).join("")}
      </div>
    `
    : "";

  container.innerHTML = `
    <div class="employee-calendar-header">
      <div class="employee-calendar-nav">
        <button type="button" class="btn btn-outline-secondary btn-sm employee-calendar-year-button" data-self-calendar-year-nav="prev"><i class="fa-solid fa-chevron-left"></i></button>
        <div class="employee-calendar-label">${escapeHtml(String(activeYear))}</div>
        <button type="button" class="btn btn-outline-secondary btn-sm employee-calendar-year-button" data-self-calendar-year-nav="next"><i class="fa-solid fa-chevron-right"></i></button>
      </div>
      <div class="employee-calendar-summary">${escapeHtml(t("employees.calendarSummary", { count: monthEntries.length, duration: secondsToDurationLabel(monthTotalSeconds) }))}</div>
    </div>
    <div class="employee-month-board-shell">
      <div class="employee-month-board">
        ${monthBoard.map(month => `
          <button type="button" class="employee-month-chip${month.active ? " is-active" : ""}${month.count > 0 ? " has-entries" : ""}" data-self-month-key="${escapeHtml(month.key)}">
            <span class="employee-month-chip-label">${escapeHtml(month.label)}</span>
            <span class="employee-month-chip-count">${escapeHtml(String(month.count))}</span>
          </button>
        `).join("")}
      </div>
    </div>
    ${liveEntriesMarkup}
    ${monthEntries.length === 0 ? createEmptyState(t("employees.noEntriesForMonth")) : `
      <div class="employee-calendar-grid">
        ${getSelfCalendarWeekdayLabels().map(label => `<div class="calendar-weekday">${escapeHtml(label)}</div>`).join("")}
        ${dayCells.join("")}
      </div>
    `}
  `;
}

function renderSelfState(entries) {
  const allEntries = sortEntriesByDateTime(entries, true);
  updateSelfSummaryMetrics(allEntries);
  updateSelfStatus(allEntries);
  renderSelfEntries(allEntries);
}

async function refreshSelfView() {
  initializeSelfView();

  try {
    setLoadingState("selfEntriesContainer", "detail", 1);
    const response = await fetch(apiUrl + "self/bootstrap");
    const payload = await parseResponse(response);
    applySelfBootstrap(payload);
    const entries = Array.isArray(payload && payload.entries) ? payload.entries : [];
    selfViewState.entries = entries;
    renderSelfState(entries);
  } catch (error) {
    console.error("Error fetching self-service entries:", error);
    showToast(t("self.fetchError", { message: error.message }), "error");
  }
}

window.refreshSelfView = refreshSelfView;

async function submitSelfPunch(type) {
  const actionLabel = type === "in" ? t("self.startOvertime") : t("self.endOvertime");
  const now = new Date();
  const promptTime = formatPromptTime(now);
  const projectCode = selfViewState.selectedProjectCode;
  const overtimeCode = selfViewState.selectedOvertimeCode;

  if (type === "in" && (!projectCode || !overtimeCode)) {
    showToast(t("self.selectionRequired"), "info");
    return;
  }

  const confirmationMessage = type === "in"
    ? t("self.startConfirm", {
      time: escapeHtml(promptTime),
      project: escapeHtml(projectCode),
      code: escapeHtml(overtimeCode),
    })
    : t("self.endConfirm", { time: escapeHtml(promptTime) });

  showSelfConfirmationModal(
    actionLabel,
    confirmationMessage,
    async () => {
      try {
        const response = await fetch(apiUrl + "self/punch", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ type, projectCode, overtimeCode }),
        });
        const result = await parseResponse(response);
        const formattedTime = formatTimeString(result.time);
        const statusMessage = t("self.punchSuccess", { action: actionLabel, time: formattedTime });

        document.getElementById("selfStatusMessage").textContent = statusMessage;
        showToast(statusMessage, "success");
        await refreshSelfView();
      } catch (error) {
        console.error(`Error during ${actionLabel.toLowerCase()}:`, error);
        showToast(t("self.actionError", { action: actionLabel.toLowerCase(), message: error.message }), "error");
      }
    }
  );
}

document.getElementById("selfPrimaryPunchButton").addEventListener("click", event => {
  const type = event.currentTarget.getAttribute("data-punch-type") || "in";
  submitSelfPunch(type);
});

document.getElementById("selfProjectCodeSelect").addEventListener("change", event => {
  selfViewState.selectedProjectCode = event.target.value;
  persistSelfSelections();
  updateSelfStatus(selfViewState.entries);
});

document.getElementById("selfOvertimeCodeSelect").addEventListener("change", event => {
  selfViewState.selectedOvertimeCode = event.target.value;
  persistSelfSelections();
  updateSelfStatus(selfViewState.entries);
});

document.getElementById("selfEntriesContainer").addEventListener("click", event => {
  const yearNavButton = event.target.closest(".employee-calendar-year-button");
  if (yearNavButton) {
    const direction = yearNavButton.getAttribute("data-self-calendar-year-nav");
    const currentMonthKey = selfViewState.currentMonthKey || toSelfMonthKey(new Date());
    selfViewState.currentMonthKey = shiftSelfMonthKey(currentMonthKey, direction === "prev" ? -12 : 12);
    renderSelfEntries(selfViewState.entries);
    return;
  }

  const monthChip = event.target.closest(".employee-month-chip");
  if (monthChip) {
    const monthKey = monthChip.getAttribute("data-self-month-key");
    if (monthKey) {
      selfViewState.currentMonthKey = monthKey;
      renderSelfEntries(selfViewState.entries);
    }
    return;
  }

  const noteToggle = event.target.closest(".calendar-note-toggle");
  if (noteToggle) {
    const noteKey = noteToggle.getAttribute("data-self-note-key");
    if (noteKey) {
      selfViewState.expandedNotes[noteKey] = !selfViewState.expandedNotes[noteKey];
      renderSelfEntries(selfViewState.entries);
    }
  }
});
