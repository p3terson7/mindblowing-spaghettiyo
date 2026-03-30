const selfViewState = {
  filtersInitialized: false,
  selectedRange: "today",
  entries: [],
  projects: [],
  overtimeCodes: [],
  lookupsLoaded: false,
  selectedProjectCode: localStorage.getItem("selfSelectedProjectCode") || "",
  selectedOvertimeCode: localStorage.getItem("selfSelectedOvertimeCode") || "",
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

function initializeSelfView() {
  if (!selfViewState.filtersInitialized) {
    const now = new Date();
    document.getElementById("selfMonthFilter").value = now.getMonth() + 1;
    document.getElementById("selfYearFilter").value = now.getFullYear();
    selfViewState.filtersInitialized = true;
  }

  setSelfRange(selfViewState.selectedRange, false);
  renderSelfPunchSelectors();
}

window.initializeSelfView = initializeSelfView;

function setSelfRange(range, shouldRefresh = true) {
  selfViewState.selectedRange = range;
  document.querySelectorAll("#selfPresetFilters .chip-button").forEach(button => {
    button.classList.toggle("active", button.getAttribute("data-range") === range);
  });
  document.getElementById("selfCustomFilterPanel").classList.toggle("d-none", range !== "custom");

  if (shouldRefresh && selfViewState.entries.length > 0) {
    renderSelfState(selfViewState.entries);
  }
}

function getCurrentWeekBounds() {
  const now = new Date();
  const day = now.getDay();
  const diff = day === 0 ? -6 : 1 - day;
  const start = new Date(now.getFullYear(), now.getMonth(), now.getDate() + diff);
  start.setHours(0, 0, 0, 0);
  const end = new Date(start);
  end.setDate(end.getDate() + 7);
  return { start, end };
}

function getFilteredSelfEntries(entries) {
  const allEntries = Array.isArray(entries) ? entries : [];
  const now = new Date();
  const todayKey = now.toISOString().slice(0, 10);
  const currentMonth = now.getMonth();
  const currentYear = now.getFullYear();

  switch (selfViewState.selectedRange) {
    case "today":
      return allEntries.filter(entry => entry.date === todayKey);
    case "week": {
      const bounds = getCurrentWeekBounds();
      return allEntries.filter(entry => {
        const entryDate = new Date(`${entry.date}T00:00:00`);
        return entryDate >= bounds.start && entryDate < bounds.end;
      });
    }
    case "month":
      return allEntries.filter(entry => {
        const entryDate = new Date(`${entry.date}T00:00:00`);
        return entryDate.getMonth() === currentMonth && entryDate.getFullYear() === currentYear;
      });
    case "custom": {
      const monthFilter = Number(document.getElementById("selfMonthFilter").value);
      const yearFilter = Number(document.getElementById("selfYearFilter").value);
      return allEntries.filter(entry => {
        const entryDate = new Date(`${entry.date}T00:00:00`);
        if (monthFilter && entryDate.getMonth() + 1 !== monthFilter) {
          return false;
        }
        if (yearFilter && entryDate.getFullYear() !== yearFilter) {
          return false;
        }
        return true;
      });
    }
    case "all":
    default:
      return allEntries;
  }
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
      time: formatTimeString(activeEntry.punchIn),
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
  const timeRange = `${formatTimeString(latestEntry.punchIn)}${latestEntry.punchOut ? ` -> ${formatTimeString(latestEntry.punchOut)}` : ""}`;
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
  container.innerHTML = "";

  if (!entries || entries.length === 0) {
    container.innerHTML = `<div class="empty-state">${escapeHtml(t("self.noEntries"))}</div>`;
    return;
  }

  const groupedEntries = entries.reduce((accumulator, entry) => {
    if (!accumulator[entry.date]) {
      accumulator[entry.date] = [];
    }
    accumulator[entry.date].push(entry);
    return accumulator;
  }, {});

  const sortedDates = Object.keys(groupedEntries).sort((left, right) => new Date(right) - new Date(left));
  sortedDates.forEach(date => {
    const group = document.createElement("div");
    group.className = "entry-date-group";
    const dayEntries = sortEntriesByDateTime(groupedEntries[date], true);
    const totalDaySeconds = dayEntries.reduce((accumulator, entry) => accumulator + timeStringToSeconds(entry.overtime), 0);

    group.innerHTML = `
      <div class="entry-date-header">
        <strong>${escapeHtml(formatDateToWords(date))}</strong>
        <span>${escapeHtml(secondsToDurationLabel(totalDaySeconds))}</span>
      </div>
    `;

    dayEntries.forEach(entry => {
      const card = document.createElement("article");
      const isOpen = isEntryOpen(entry);
      card.className = `worklog-card${isOpen ? " is-open" : ""}`;
      card.innerHTML = `
        <div class="worklog-main">
          <div>
            <div class="worklog-title">${escapeHtml(formatTimeString(entry.punchIn))}${entry.punchOut ? ` -> ${escapeHtml(formatTimeString(entry.punchOut))}` : ` -> ${escapeHtml(t("shared.inProgress"))}`}</div>
            <div class="worklog-secondary">${escapeHtml(getEntryContextLabel(entry))}</div>
          </div>
          <div class="meta-row">
            <span class="inline-code-pill">${escapeHtml(entry.overtime ? secondsToDurationLabel(timeStringToSeconds(entry.overtime)) : t("shared.inProgress"))}</span>
            <span class="status-badge ${getStatusTone(entry.status)}">${escapeHtml(translateStatus(entry.status || "pending"))}</span>
          </div>
        </div>
        ${entry.message ? `<div class="worklog-message">${escapeHtml(entry.message)}</div>` : ""}
      `;
      group.appendChild(card);
    });

    container.appendChild(group);
  });
}

function renderSelfState(entries) {
  const allEntries = sortEntriesByDateTime(entries, true);
  const filteredEntries = sortEntriesByDateTime(getFilteredSelfEntries(allEntries), true);

  updateSelfSummaryMetrics(allEntries);
  updateSelfStatus(allEntries);
  renderSelfEntries(filteredEntries);
}

async function refreshSelfView() {
  initializeSelfView();

  try {
    await loadSelfLookups();
    const response = await fetch(apiUrl + "self/entries");
    const payload = await parseResponse(response);
    const entries = Array.isArray(payload) ? payload : (payload ? [payload] : []);
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

document.querySelectorAll("#selfPresetFilters .chip-button").forEach(button => {
  button.addEventListener("click", () => {
    setSelfRange(button.getAttribute("data-range"));
  });
});

document.getElementById("selfApplyFilterButton").addEventListener("click", () => {
  setSelfRange("custom");
});

document.getElementById("selfClearFilterButton").addEventListener("click", () => {
  selfViewState.filtersInitialized = false;
  initializeSelfView();
  setSelfRange("today");
});
