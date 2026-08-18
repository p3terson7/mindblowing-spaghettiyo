const selfViewState = {
  entries: [],
  projects: [],
  overtimeCodes: [],
  paymentOptions: [],
  reasonCodes: [],
  timeEntryTypes: ["overtime"],
  lookupsLoaded: false,
  selectedEntryType: localStorage.getItem("selfSelectedEntryType") || "overtime",
  selectedProjectCode: localStorage.getItem("selfSelectedProjectCode") || "",
  selectedOvertimeCode: localStorage.getItem("selfSelectedOvertimeCode") || "",
  selectedPaymentOption: localStorage.getItem("selfSelectedPaymentOption") || "",
  selectedReasonCode: localStorage.getItem("selfSelectedReasonCode") || "",
  currentMonthKey: "",
  statsFilter: {
    range: ["month", "year", "all", "custom"].includes(localStorage.getItem("selfStatsRange")) ? localStorage.getItem("selfStatsRange") : "month",
    projectCode: "",
    status: "",
    startDate: "",
    endDate: "",
  },
};

const SELF_PROJECT_STORAGE_KEY = "selfSelectedProjectCode";
const SELF_ENTRY_TYPE_STORAGE_KEY = "selfSelectedEntryType";
const SELF_OVERTIME_CODE_STORAGE_KEY = "selfSelectedOvertimeCode";
const SELF_PAYMENT_OPTION_STORAGE_KEY = "selfSelectedPaymentOption";
const SELF_REASON_CODE_STORAGE_KEY = "selfSelectedReasonCode";
const SELF_STATS_RANGE_STORAGE_KEY = "selfStatsRange";

function showSelfConfirmationModal(title, message, callback) {
  const modalTitle = document.getElementById("selfConfirmModalLabel");
  const modalBody = document.getElementById("selfConfirmModalBody");
  const confirmButton = document.getElementById("selfConfirmModalConfirmBtn");

  modalTitle.innerText = title;
  modalBody.innerHTML = message;

  const replacementButton = confirmButton.cloneNode(true);
  confirmButton.parentNode.replaceChild(replacementButton, confirmButton);

  replacementButton.addEventListener("click", async () => {
    await runButtonAction(replacementButton, callback, { key: "self-punch" });
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
  if (selfViewState.selectedEntryType) {
    localStorage.setItem(SELF_ENTRY_TYPE_STORAGE_KEY, selfViewState.selectedEntryType);
  } else {
    localStorage.removeItem(SELF_ENTRY_TYPE_STORAGE_KEY);
  }

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

  if (selfViewState.selectedPaymentOption) {
    localStorage.setItem(SELF_PAYMENT_OPTION_STORAGE_KEY, selfViewState.selectedPaymentOption);
  } else {
    localStorage.removeItem(SELF_PAYMENT_OPTION_STORAGE_KEY);
  }

  if (selfViewState.selectedReasonCode) {
    localStorage.setItem(SELF_REASON_CODE_STORAGE_KEY, selfViewState.selectedReasonCode);
  } else {
    localStorage.removeItem(SELF_REASON_CODE_STORAGE_KEY);
  }
}

function normalizeSelfEntryType(value) {
  return String(value || "").trim().toLowerCase() === "diverse" ? "diverse" : "overtime";
}

function getAllowedSelfEntryTypes() {
  const seen = new Set();
  const source = Array.isArray(selfViewState.timeEntryTypes) && selfViewState.timeEntryTypes.length > 0
    ? selfViewState.timeEntryTypes
    : ["overtime"];

  source.forEach(type => {
    seen.add(normalizeSelfEntryType(type));
  });

  return Array.from(seen);
}

function updateSelfPunchAvailability() {
  const primaryButton = document.getElementById("selfPrimaryPunchButton");
  const punchType = primaryButton.getAttribute("data-punch-type") || "in";

  if (punchType === "out") {
    const workCommentInput = document.getElementById("selfWorkCommentInput");
    primaryButton.disabled = !workCommentInput || !String(workCommentInput.value || "").trim();
    return;
  }

  if (selfViewState.selectedEntryType === "diverse") {
    const reasonInput = document.getElementById("selfDiverseReasonInput");
    primaryButton.disabled = !selfViewState.lookupsLoaded || !reasonInput || !String(reasonInput.value || "").trim();
    return;
  }

  primaryButton.disabled = !selfViewState.lookupsLoaded
    || !selfViewState.selectedProjectCode
    || !selfViewState.selectedPaymentOption;
}

function isSelfEntryTypeAllowed(entryType) {
  return getAllowedSelfEntryTypes().includes(normalizeSelfEntryType(entryType));
}

function syncSelfEntryTypeControls() {
  const typeSelect = document.getElementById("selfEntryTypeSelect");
  const typeShell = document.getElementById("selfEntryTypeShell");
  const overtimeSelectors = document.getElementById("selfOvertimeSelectors");
  const diverseStartFields = document.getElementById("selfDiverseStartFields");
  const workCommentFields = document.getElementById("selfWorkCommentFields");
  const allowedTypes = getAllowedSelfEntryTypes();
  const shouldShowTypeSelect = allowedTypes.length > 1;

  if (!isSelfEntryTypeAllowed(selfViewState.selectedEntryType)) {
    selfViewState.selectedEntryType = allowedTypes[0] || "overtime";
  } else {
    selfViewState.selectedEntryType = normalizeSelfEntryType(selfViewState.selectedEntryType);
  }

  if (typeSelect) {
    typeSelect.innerHTML = allowedTypes.map(type => {
      const value = String(type || "").trim().toLowerCase() === "diverse" ? "diverse" : "overtime";
      const label = value === "diverse" ? t("shared.diverse") : t("shared.overtime");
      return `<option value="${escapeHtml(value)}"${value === selfViewState.selectedEntryType ? " selected" : ""}>${escapeHtml(label)}</option>`;
    }).join("");
    typeSelect.value = selfViewState.selectedEntryType;
  }

  if (typeShell) {
    typeShell.classList.toggle("d-none", !shouldShowTypeSelect);
  } else if (typeSelect) {
    typeSelect.classList.toggle("d-none", !shouldShowTypeSelect);
  }
  if (overtimeSelectors) {
    overtimeSelectors.classList.toggle("d-none", selfViewState.selectedEntryType === "diverse");
  }
  if (diverseStartFields) {
    diverseStartFields.classList.toggle("d-none", selfViewState.selectedEntryType !== "diverse");
  }
  if (workCommentFields) {
    workCommentFields.classList.add("d-none");
  }

  persistSelfSelections();
}

function renderSelfPunchSelectors() {
  const projectSelect = document.getElementById("selfProjectCodeSelect");
  const overtimeCodeSelect = document.getElementById("selfOvertimeCodeSelect");
  const paymentOptionSelect = document.getElementById("selfPaymentOptionSelect");
  const reasonCodeSelect = document.getElementById("selfReasonCodeSelect");

  projectSelect.innerHTML = buildProjectOptions(selfViewState.projects, t("shared.project"), selfViewState.selectedProjectCode);
  overtimeCodeSelect.innerHTML = buildOvertimeCodeOptions(selfViewState.overtimeCodes, t("shared.overtimeCode"), selfViewState.selectedOvertimeCode);
  paymentOptionSelect.innerHTML = buildPaymentOptionOptions(selfViewState.paymentOptions, t("shared.paymentOption"), selfViewState.selectedPaymentOption);
  reasonCodeSelect.innerHTML = buildReasonCodeOptions(selfViewState.reasonCodes, t("shared.reasonCode"), selfViewState.selectedReasonCode);

  if (selfViewState.selectedProjectCode && projectSelect.value !== selfViewState.selectedProjectCode) {
    selfViewState.selectedProjectCode = "";
  }

  if (selfViewState.selectedOvertimeCode && overtimeCodeSelect.value !== selfViewState.selectedOvertimeCode) {
    selfViewState.selectedOvertimeCode = "";
  }

  if (selfViewState.selectedPaymentOption && paymentOptionSelect.value !== selfViewState.selectedPaymentOption) {
    selfViewState.selectedPaymentOption = "";
  }

  if (selfViewState.selectedReasonCode && reasonCodeSelect.value !== selfViewState.selectedReasonCode) {
    selfViewState.selectedReasonCode = "";
  }

  projectSelect.value = selfViewState.selectedProjectCode;
  overtimeCodeSelect.value = selfViewState.selectedOvertimeCode;
  paymentOptionSelect.value = selfViewState.selectedPaymentOption;
  reasonCodeSelect.value = selfViewState.selectedReasonCode;

  syncSelfEntryTypeControls();
  persistSelfSelections();
  updateSelfPunchAvailability();
}

async function loadSelfLookups(forceRefresh = false) {
  const payload = await fetchOvertimeEntryLookups(forceRefresh);
  selfViewState.projects = payload.projects;
  selfViewState.overtimeCodes = payload.overtimeCodes;
  selfViewState.paymentOptions = payload.paymentOptions;
  selfViewState.reasonCodes = payload.reasonCodes;
  selfViewState.timeEntryTypes = Array.isArray(payload.timeEntryTypes) && payload.timeEntryTypes.length > 0 ? payload.timeEntryTypes : ["overtime"];
  selfViewState.lookupsLoaded = true;
  renderSelfPunchSelectors();
}

function applySelfBootstrap(payload) {
  selfViewState.projects = Array.isArray(payload && payload.projects) ? payload.projects : [];
  selfViewState.overtimeCodes = Array.isArray(payload && payload.overtimeCodes) ? payload.overtimeCodes : [];
  selfViewState.paymentOptions = Array.isArray(payload && payload.paymentOptions) ? payload.paymentOptions : [];
  selfViewState.reasonCodes = Array.isArray(payload && payload.reasonCodes) ? payload.reasonCodes : [];
  selfViewState.timeEntryTypes = Array.isArray(payload && payload.timeEntryTypes) && payload.timeEntryTypes.length > 0 ? payload.timeEntryTypes : ["overtime"];
  if (payload && payload.gc179Profile && typeof updateStoredUserGc179Profile === "function") {
    updateStoredUserGc179Profile(payload.gc179Profile);
  }
  selfViewState.lookupsLoaded = true;
  renderSelfPunchSelectors();
}

function initializeSelfView() {
  renderSelfPunchSelectors();
}

window.initializeSelfView = initializeSelfView;

function getDefaultSelfMonthKey(entries) {
  return window.Saphir.calendarMonths.resolveActiveMonth(entries, selfViewState.currentMonthKey, {
    getTimestamp(entry) {
      return toEntryDateTime(entry).getTime();
    },
    getEntryDate(entry) {
      return entry.date;
    },
    toMonthKey: toCalendarMonthKey,
    referenceDate: new Date(),
  });
}

function buildSelfMonthBoard(entries, activeMonthKey) {
  return window.Saphir.calendarMonths.buildYear(entries, activeMonthKey, {
    getEntryDate(entry) {
      return entry.date;
    },
    toMonthKey: toCalendarMonthKey,
    formatMonthLabel(date) {
      return date.toLocaleDateString(getCurrentLocale(), { month: "short" });
    },
    referenceDate: new Date(),
  }).map(month => {
    return {
      key: month.monthKey,
      label: month.label,
      count: month.count,
      active: month.active,
    };
  });
}

function buildSelfCalendarDays(entries, activeMonthKey) {
  return window.Saphir.calendarDays.buildMonth(entries, activeMonthKey, {
    getEntryDate(entry) {
      return entry.date;
    },
    getDurationSeconds: getEntryDurationSeconds,
    orderDayEntries(dayEntries) {
      return sortEntriesByDateTime(dayEntries, true);
    },
  });
}

function getSelfActiveEntry(entries) {
  return sortEntriesByDateTime(entries || [], true).find(entry => isEntryOpen(entry)) || null;
}

function getSelfStatsDateRange() {
  return window.Saphir.dateRanges.resolveSelf(
    selfViewState.statsFilter.range,
    selfViewState.statsFilter,
    new Date(),
  );
}

function getSelfStatsStatus(entry) {
  return window.Saphir.entryStats.resolveStatus(entry, isEntryOpen);
}

function getSelfProjectName(projectCode) {
  const match = findProjectByCode(selfViewState.projects, projectCode);
  return match ? String(match.projectName || projectCode) : String(projectCode || "");
}

function getSelfProjectByCode(projectCode) {
  return findProjectByCode(selfViewState.projects, projectCode);
}

function buildSelfStatsProjectFilterOptions(entries) {
  const projectMap = {};
  (selfViewState.projects || []).forEach(project => {
    const code = String(project.projectCode || "").trim();
    if (code) {
      projectMap[code] = {
        projectCode: code,
        projectName: String(project.projectName || code),
      };
    }
  });

  (entries || []).forEach(entry => {
    const code = String(entry.projectCode || "").trim();
    if (code && !projectMap[code]) {
      projectMap[code] = { projectCode: code, projectName: code };
    }
  });

  const options = Object.values(projectMap).sort((left, right) => left.projectCode.localeCompare(right.projectCode));
  return buildProjectOptions(options, t("filters.allProjects"), selfViewState.statsFilter.projectCode);
}

function syncSelfStatsControls(entries) {
  const rangeButtons = document.querySelectorAll("[data-self-stats-range]");
  rangeButtons.forEach(button => {
    button.classList.toggle("active", button.getAttribute("data-self-stats-range") === selfViewState.statsFilter.range);
  });

  const range = getSelfStatsDateRange();
  const startInput = document.getElementById("selfStatsStartDate");
  const endInput = document.getElementById("selfStatsEndDate");
  if (startInput && endInput) {
    startInput.value = selfViewState.statsFilter.range === "custom" ? selfViewState.statsFilter.startDate : range.startDate;
    endInput.value = selfViewState.statsFilter.range === "custom" ? selfViewState.statsFilter.endDate : range.endDate;
    startInput.disabled = selfViewState.statsFilter.range !== "custom";
    endInput.disabled = selfViewState.statsFilter.range !== "custom";
  }

  const projectSelect = document.getElementById("selfStatsProjectFilter");
  if (projectSelect) {
    projectSelect.innerHTML = buildSelfStatsProjectFilterOptions(entries);
    projectSelect.value = selfViewState.statsFilter.projectCode || "";
    if (selfViewState.statsFilter.projectCode && projectSelect.value !== selfViewState.statsFilter.projectCode) {
      selfViewState.statsFilter.projectCode = "";
      projectSelect.value = "";
    }
  }

  const statusSelect = document.getElementById("selfStatsStatusFilter");
  if (statusSelect) {
    statusSelect.value = selfViewState.statsFilter.status || "";
  }
}

function getFilteredSelfStatsEntries(entries) {
  const range = getSelfStatsDateRange();
  return (entries || []).filter(entry => {
    if (isDiverseEntry(entry)) {
      return false;
    }
    if (!isDateWithinRange(entry.date, range.startDate, range.endDate)) {
      return false;
    }
    if (selfViewState.statsFilter.projectCode && String(entry.projectCode || "") !== selfViewState.statsFilter.projectCode) {
      return false;
    }
    if (selfViewState.statsFilter.status && getSelfStatsStatus(entry) !== selfViewState.statsFilter.status) {
      return false;
    }
    return true;
  });
}

function getTopSelfStatsBucket(buckets) {
  return window.Saphir.entryStats.selectTopBucket(buckets);
}

function buildSelfStatsModel(entries) {
  const filteredEntries = getFilteredSelfStatsEntries(entries);
  return window.Saphir.entryStats.summarize(filteredEntries, {
    getDurationSeconds: getEntryDurationSeconds,
    getStatus: getSelfStatsStatus,
    getTimestamp: toEntryDateTime,
    getProjectCode(entry) {
      return String(entry.projectCode || "").trim() || "__NO_PROJECT__";
    },
    getProject(projectCode, entry) {
      const rawProjectCode = String(entry.projectCode || "").trim();
      const projectRecord = rawProjectCode ? getSelfProjectByCode(projectCode) : null;
      return {
        projectCode,
        projectName: rawProjectCode ? getSelfProjectName(projectCode) : t("shared.noProject"),
        colorKey: projectRecord ? getProjectColorKey(projectRecord) : getProjectColorKey(projectCode),
      };
    },
    getOvertimeCode(entry) {
      return String(entry.overtimeCode || "").trim() || t("shared.uncoded");
    },
    includeSourceEntries: true,
    includeProjectEntries: false,
  });
}

function renderSelfStats(entries) {
  const summaryContainer = document.getElementById("selfStatsSummary");
  const projectsContainer = document.getElementById("selfProjectStatsContainer");
  if (!summaryContainer || !projectsContainer) {
    return;
  }

  syncSelfStatsControls(entries);
  const model = buildSelfStatsModel(entries);
  const averageSeconds = model.totals.count > 0 ? Math.round(model.totals.seconds / model.totals.count) : 0;
  const topCodeLabel = model.topOvertimeCode
    ? `${model.topOvertimeCode.code} | ${secondsToDurationLabel(model.topOvertimeCode.seconds)}`
    : t("shared.uncoded");

  const summaryCards = [
    { label: t("self.statsTotal"), value: secondsToDurationLabel(model.totals.seconds), hint: t("self.statsFilteredSummary", { count: model.totals.count, duration: secondsToDurationLabel(model.totals.seconds) }) },
    { label: t("self.statsApproved"), value: secondsToDurationLabel(model.totals.approvedSeconds), hint: t("status.approved") },
    { label: t("self.statsAverage"), value: secondsToDurationLabel(averageSeconds), hint: t("self.statsMax") + " " + secondsToDurationLabel(model.totals.maxSeconds) },
    { label: t("self.statsPendingRejected"), value: `${model.totals.pending} / ${model.totals.rejected}`, hint: `${t("self.statsLive")}: ${model.totals.live}` },
    { label: t("self.statsTopCode"), value: topCodeLabel, hint: `${t("self.statsSupervisorNotes")}: ${model.totals.notes}` },
  ];

  summaryContainer.innerHTML = summaryCards.map(card => `
    <article class="self-stat-card">
      <span class="metric-label">${escapeHtml(card.label)}</span>
      <strong class="metric-value mono">${escapeHtml(card.value)}</strong>
      <span class="metric-hint">${escapeHtml(card.hint)}</span>
    </article>
  `).join("");

  if (model.projects.length === 0) {
    projectsContainer.innerHTML = createEmptyState(t("self.statsNoEntries"));
    return;
  }

  projectsContainer.innerHTML = `
    <div class="self-project-stats-header">
      <span class="panel-kicker">${escapeHtml(t("self.statsProjectBreakdown"))}</span>
      <span class="panel-note">${escapeHtml(t("self.statsFilteredSummary", { count: model.totals.count, duration: secondsToDurationLabel(model.totals.seconds) }))}</span>
    </div>
    <div class="self-project-stat-list">
      ${model.projects.map(project => {
        const average = project.count > 0 ? Math.round(project.seconds / project.count) : 0;
        const topProjectCode = getTopSelfStatsBucket(project.overtimeCodes);
        const latestLabel = project.latestEntry
          ? `${formatDateLabel(project.latestEntry.date)} | ${getEntryRoundedTimeRange(project.latestEntry)}`
          : t("employees.noRecentEntry");
        return `
          <article class="self-project-stat-card${project.projectCode === "__NO_PROJECT__" ? "" : " project-colored-surface"}" style="${project.projectCode === "__NO_PROJECT__" ? "" : getProjectColorStyle(project)}">
            <div class="self-project-stat-main">
              <div>
                <div class="self-project-stat-title d-flex align-items-center gap-2">${project.projectCode === "__NO_PROJECT__" ? "" : renderProjectColorDot(project)}<span>${escapeHtml(project.projectCode === "__NO_PROJECT__" ? t("shared.noProject") : project.projectCode)}</span></div>
                <div class="worklog-secondary">${escapeHtml(project.projectName || project.projectCode)}</div>
              </div>
              <span class="inline-code-pill">${escapeHtml(secondsToDurationLabel(project.seconds))}</span>
            </div>
            <div class="self-project-stat-grid">
              <span><strong>${escapeHtml(String(project.count))}</strong> ${escapeHtml(t("self.statsEntries"))}</span>
              <span><strong>${escapeHtml(secondsToDurationLabel(project.approvedSeconds))}</strong> ${escapeHtml(t("self.statsApproved"))}</span>
              <span><strong>${escapeHtml(String(project.pending))}/${escapeHtml(String(project.rejected))}</strong> ${escapeHtml(t("self.statsPendingRejected"))}</span>
              <span><strong>${escapeHtml(secondsToDurationLabel(average))}</strong> ${escapeHtml(t("self.statsAverage"))}</span>
              <span><strong>${escapeHtml(secondsToDurationLabel(project.maxSeconds))}</strong> ${escapeHtml(t("self.statsMax"))}</span>
              <span><strong>${escapeHtml(topProjectCode ? topProjectCode.code : t("shared.uncoded"))}</strong> ${escapeHtml(t("self.statsTopCode"))}</span>
            </div>
            <div class="self-project-stat-footer">
              <span>${escapeHtml(latestLabel)}</span>
              <span>${escapeHtml(t("self.statsSupervisorNotes"))}: ${escapeHtml(String(project.notes))}</span>
            </div>
          </article>
        `;
      }).join("")}
    </div>
  `;
}

function updateSelfSummaryMetrics(allEntries) {
  const now = new Date();
  const currentMonthEntries = allEntries.filter(entry => {
    if (isDiverseEntry(entry)) {
      return false;
    }
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
  const trackingCard = document.getElementById("selfTrackingCard");
  const lastEntryShell = document.getElementById("selfLastEntryShell");
  const punchState = document.getElementById("selfPunchStateText");
  const statusMessage = document.getElementById("selfStatusMessage");
  const currentStatusValue = document.getElementById("selfCurrentStatusValue");
  const currentStatusHint = document.getElementById("selfCurrentStatusHint");
  const heroText = document.getElementById("selfHeroText");
  const selectionSummary = document.getElementById("selfSelectionSummary");
  const punchSelectors = document.getElementById("selfPunchSelectors");
  const workCommentFields = document.getElementById("selfWorkCommentFields");
  const latestEntry = getLatestEntry(entries);
  const activeEntry = getSelfActiveEntry(entries);

  if (trackingCard) {
    trackingCard.classList.toggle("is-live", Boolean(activeEntry));
  }

  if (activeEntry) {
    const startedAt = toEntryDateTime(activeEntry);
    const elapsedSeconds = Math.max(0, Math.floor((Date.now() - startedAt.getTime()) / 1000));
    primaryButton.textContent = isDiverseEntry(activeEntry) ? t("self.endDiverse") : t("self.endOvertime");
    primaryButton.dataset.punchType = "out";
    if (lastEntryShell) {
      lastEntryShell.classList.remove("d-none");
    }
    if (punchState) {
      punchState.textContent = t("self.startedAt", {
        date: formatDateLabel(activeEntry.date),
        time: formatTimeString(getEntryExactPunchIn(activeEntry)),
      });
    }
    if (statusMessage) {
      statusMessage.textContent = t("self.openDuration", { duration: secondsToDurationLabel(elapsedSeconds) });
    }
    if (currentStatusValue) {
      currentStatusValue.textContent = t("status.clockedIn");
    }
    if (currentStatusHint) {
      currentStatusHint.textContent = getEntryContextLabel(activeEntry);
    }
    if (selectionSummary) {
      selectionSummary.textContent = getEntryContextLabel(activeEntry);
    }
    punchSelectors.classList.add("d-none");
    if (workCommentFields) {
      workCommentFields.classList.remove("d-none");
    }
    if (heroText) {
      heroText.textContent = t("self.hero.live");
    }
    updateSelfPunchAvailability();
    return;
  }

  primaryButton.textContent = selfViewState.selectedEntryType === "diverse" ? t("self.startDiverse") : t("self.startOvertime");
  primaryButton.dataset.punchType = "in";
  punchSelectors.classList.remove("d-none");
  if (workCommentFields) {
    workCommentFields.classList.add("d-none");
  }
  syncSelfEntryTypeControls();
  if (selectionSummary) {
    const selectionParts = [
      selfViewState.selectedEntryType === "diverse" ? t("shared.diverse") : selfViewState.selectedProjectCode,
      selfViewState.selectedEntryType === "diverse" ? document.getElementById("selfDiverseReasonInput")?.value : selfViewState.selectedOvertimeCode,
      selfViewState.selectedEntryType === "diverse" ? "" : (selfViewState.selectedPaymentOption ? formatPaymentOptionValue(selfViewState.selectedPaymentOption) : ""),
      selfViewState.selectedEntryType === "diverse" ? "" : selfViewState.selectedReasonCode,
    ].filter(Boolean);
    selectionSummary.textContent = selectionParts.length > 0
      ? selectionParts.join(" · ")
      : t("self.selectionHint");
  }

  if (!latestEntry) {
    if (lastEntryShell) {
      lastEntryShell.classList.add("d-none");
    }
    if (punchState) {
      punchState.textContent = "";
    }
    if (statusMessage) {
      statusMessage.textContent = t("status.idle");
    }
    if (currentStatusValue) {
      currentStatusValue.textContent = t("status.offClock");
    }
    if (currentStatusHint) {
      currentStatusHint.textContent = t("shared.ready");
    }
    if (heroText) {
      heroText.textContent = t("self.hero.idle");
    }
    updateSelfPunchAvailability();
    return;
  }

  const latestStatus = String(latestEntry.status || "pending").toLowerCase();
  const timeRange = latestEntry.punchOut
    ? buildTimeRangeText(formatTimeString(getEntryExactPunchIn(latestEntry)), formatTimeString(getEntryExactPunchOut(latestEntry)))
    : formatTimeString(getEntryExactPunchIn(latestEntry));
  if (lastEntryShell) {
    lastEntryShell.classList.remove("d-none");
  }
  if (punchState) {
    punchState.textContent = t("self.lastEntry", {
      date: formatDateLabel(latestEntry.date),
      timeRange,
    });
  }
  if (currentStatusValue) {
    currentStatusValue.textContent = latestStatus === "rejected"
      ? t("status.needsAttention")
      : latestStatus === "approved"
        ? t("status.readyForNext")
        : t("status.awaitingApproval");
  }
  if (currentStatusHint) {
    currentStatusHint.textContent = latestStatus === "rejected"
      ? t("status.rejected")
      : latestStatus === "approved"
        ? t("status.approved")
        : t("status.pending");
  }
  if (statusMessage) {
    statusMessage.textContent = latestStatus === "rejected"
      ? t("shared.reviewRequired")
      : latestStatus === "approved"
        ? t("shared.ready")
        : t("shared.waiting");
  }
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

  const monthEntries = sortEntriesByDateTime(allEntries.filter(entry => toCalendarMonthKey(entry.date) === activeMonthKey), true);
  const monthBoard = buildSelfMonthBoard(allEntries, activeMonthKey);
  const calendarMonth = buildSelfCalendarDays(monthEntries, activeMonthKey);
  const activeYear = calendarMonth.year;
  const dayCells = [];

  calendarMonth.days.forEach(day => {
    const dayEntries = day.entries;
    const isCurrentMonth = day.isCurrentMonth;
    const totalDaySeconds = day.totalSeconds;

    const entryMarkup = dayEntries.map(entry => {
      const statusTone = getStatusTone(entry);
      const exactTimeLabel = getEntryExactTimeLabel(entry);
      const projectRecord = getSelfProjectByCode(entry.projectCode) || entry.projectCode;
      const projectIdentity = !isDiverseEntry(entry) && entry.projectCode
        ? renderProjectIdentityPill(projectRecord, entry.projectCode)
        : "";

      return `
        <div class="calendar-entry">
          <div class="calendar-entry-main">
            <span class="calendar-entry-time">${getEntryRoundedTimeRangeMarkup(entry)}</span>
            <span class="status-badge ${escapeHtml(statusTone)}">${escapeHtml(getEntryStatusLabel(entry))}</span>
          </div>
          <div class="calendar-entry-meta project-entry-context">${projectIdentity}${projectIdentity ? `<span>${escapeHtml([entry.overtimeCode, entry.paymentOption ? formatPaymentOptionValue(entry.paymentOption) : "", entry.reasonCode].filter(Boolean).join(" | "))}</span>` : escapeHtml(getEntryContextLabel(entry))}</div>
          ${exactTimeLabel ? `<div class="calendar-entry-meta">${escapeHtml(exactTimeLabel)}</div>` : ""}
          ${renderEntryNotesPreview(entry)}
        </div>
      `;
    }).join("");

    dayCells.push(`
      <div class="calendar-day${isCurrentMonth ? "" : " is-muted"}${dayEntries.length > 0 ? " has-entries" : ""}">
        <div class="calendar-day-header">
          <span class="calendar-day-number">${day.dayNumber}</span>
          ${dayEntries.length > 0 ? `<span class="calendar-day-total">${escapeHtml(secondsToDurationLabel(totalDaySeconds))}</span>` : ""}
        </div>
        <div class="calendar-day-body">${entryMarkup}</div>
      </div>
    `);
  });

  const monthTotalSeconds = monthEntries.reduce((accumulator, entry) => accumulator + getEntryDurationSeconds(entry), 0);
  const liveEntriesMarkup = liveEntries.length > 0
    ? `
      <div class="calendar-live-strip">
        ${liveEntries.map(entry => `
          <article class="calendar-live-card">
            <div class="calendar-entry-main">
              <span class="calendar-entry-time">${escapeHtml(formatDateLabel(entry.date))} | ${buildTimeRangeMarkup(formatTimeString(getEntryExactPunchIn(entry)), t("shared.inProgress"))}</span>
              <span class="status-badge approved">${escapeHtml(t("shared.live"))}</span>
            </div>
            <div class="calendar-entry-meta project-entry-context">${!isDiverseEntry(entry) && entry.projectCode ? renderProjectIdentityPill(getSelfProjectByCode(entry.projectCode) || entry.projectCode, entry.projectCode) : escapeHtml(getEntryContextLabel(entry))}</div>
            <div class="calendar-entry-meta">${escapeHtml(secondsToDurationLabel(getEntryDurationSeconds(entry)))}</div>
          </article>
        `).join("")}
      </div>
    `
    : "";

  container.innerHTML = `
    <div class="employee-calendar-header">
      <div class="employee-calendar-nav">
        <button type="button" class="btn btn-outline-secondary btn-sm employee-calendar-year-button" data-self-calendar-year-nav="prev" aria-label="${escapeHtml(t("action.previousYear"))}" title="${escapeHtml(t("action.previousYear"))}"><i class="fa-solid fa-chevron-left" aria-hidden="true"></i></button>
        <div class="employee-calendar-label">${escapeHtml(String(activeYear))}</div>
        <button type="button" class="btn btn-outline-secondary btn-sm employee-calendar-year-button" data-self-calendar-year-nav="next" aria-label="${escapeHtml(t("action.nextYear"))}" title="${escapeHtml(t("action.nextYear"))}"><i class="fa-solid fa-chevron-right" aria-hidden="true"></i></button>
      </div>
      <div class="employee-calendar-actions">
        <div class="employee-calendar-summary">${escapeHtml(t("employees.calendarSummary", { count: monthEntries.length, duration: secondsToDurationLabel(monthTotalSeconds) }))}</div>
        <button type="button" class="btn btn-outline-secondary btn-sm self-gc179-fdf-button" data-self-gc179-month="${escapeHtml(activeMonthKey)}">
          <i class="fa-solid fa-file-export"></i> ${escapeHtml(t("export.downloadGc179Fdf"))}
        </button>
      </div>
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
        ${getCalendarWeekdayLabels().map(label => `<div class="calendar-weekday">${escapeHtml(label)}</div>`).join("")}
        ${dayCells.join("")}
      </div>
    `}
  `;
}

function renderSelfState(entries) {
  const allEntries = sortEntriesByDateTime(entries, true);
  updateSelfSummaryMetrics(allEntries);
  updateSelfStatus(allEntries);
  renderSelfStats(allEntries);
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
    return true;
  } catch (error) {
    console.error("Error fetching self-service entries:", error);
    showToast(t("self.fetchError", { message: error.message }), "error");
    return false;
  }
}

window.refreshSelfView = refreshSelfView;

window.rerenderSelfViewForLanguageChange = function () {
  initializeSelfView();
  renderSelfState(selfViewState.entries || []);
};

async function submitSelfPunch(type) {
  const activeEntry = getSelfActiveEntry(selfViewState.entries);
  const selectedEntryType = type === "out" && activeEntry ? getEntryType(activeEntry) : selfViewState.selectedEntryType;
  const actionLabel = type === "in"
    ? (selectedEntryType === "diverse" ? t("self.startDiverse") : t("self.startOvertime"))
    : (selectedEntryType === "diverse" ? t("self.endDiverse") : t("self.endOvertime"));
  const now = new Date();
  const promptTime = formatPromptTime(now);
  const projectCode = selfViewState.selectedProjectCode;
  const overtimeCode = selfViewState.selectedOvertimeCode;
  const paymentOption = selfViewState.selectedPaymentOption;
  const reasonCode = selfViewState.selectedReasonCode;
  const diverseReason = String(document.getElementById("selfDiverseReasonInput")?.value || "").trim();
  const workComment = String(document.getElementById("selfWorkCommentInput")?.value || "").trim();

  if (type === "in" && selectedEntryType === "diverse" && !diverseReason) {
    showToast(t("self.diverseReasonRequired"), "info");
    return;
  }

  if (type === "out" && !workComment) {
    showToast(t(selectedEntryType === "diverse" ? "self.diverseSummaryRequired" : "self.workCommentRequired"), "info");
    return;
  }

  if (type === "in" && selectedEntryType !== "diverse" && (!projectCode || !paymentOption)) {
    showToast(t("self.selectionRequired"), "info");
    return;
  }

  const punchPayload = { type, entryType: selectedEntryType, projectCode, overtimeCode, paymentOption, reasonCode, diverseReason };
  if (type === "out") {
    if (selectedEntryType === "diverse") {
      punchPayload.diverseSummary = workComment;
    } else {
      punchPayload.workComment = workComment;
    }
  }

  const confirmationMessage = type === "in" && selectedEntryType === "diverse"
    ? t("self.startDiverseConfirm", {
      time: escapeHtml(promptTime),
      reason: escapeHtml(diverseReason),
    })
    : type === "in"
    ? t("self.startConfirm", {
      time: escapeHtml(promptTime),
      project: escapeHtml(projectCode),
      code: escapeHtml(overtimeCode || t("shared.overtimeCode")),
      payment: escapeHtml(formatPaymentOptionValue(paymentOption)),
      reason: escapeHtml(reasonCode || t("shared.reasonCode")),
    })
    : selectedEntryType === "diverse"
      ? t("self.endDiverseConfirm", { time: escapeHtml(promptTime), comment: escapeHtml(workComment) })
      : t("self.endConfirm", { time: escapeHtml(promptTime), comment: escapeHtml(workComment) });

  showSelfConfirmationModal(
    actionLabel,
    confirmationMessage,
    async () => {
      try {
        const response = await fetch(apiUrl + "self/punch", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(punchPayload),
        });
        const result = await parseResponse(response);
        const formattedTime = formatTimeString(result.time);
        const statusMessage = result && result.requiresClockOutReview
          ? t("self.clockOutNeedsReview", { date: formatDateLabel(result.reviewEntryDate) })
          : t("self.punchSuccess", { action: actionLabel, time: formattedTime });

        const statusMessageElement = document.getElementById("selfStatusMessage");
        if (statusMessageElement) {
          statusMessageElement.textContent = statusMessage;
        }
        showToast(statusMessage, result && result.requiresClockOutReview ? "warning" : "success");
        if (type === "out") {
          document.getElementById("selfWorkCommentInput").value = "";
        }
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

document.getElementById("selfEntryTypeSelect").addEventListener("change", event => {
  selfViewState.selectedEntryType = event.target.value || "overtime";
  syncSelfEntryTypeControls();
  persistSelfSelections();
  updateSelfStatus(selfViewState.entries);
});

document.getElementById("selfDiverseReasonInput").addEventListener("input", () => {
  updateSelfStatus(selfViewState.entries);
});

document.getElementById("selfWorkCommentInput").addEventListener("input", updateSelfPunchAvailability);

document.getElementById("selfOvertimeCodeSelect").addEventListener("change", event => {
  selfViewState.selectedOvertimeCode = event.target.value;
  persistSelfSelections();
  updateSelfStatus(selfViewState.entries);
});

document.getElementById("selfPaymentOptionSelect").addEventListener("change", event => {
  selfViewState.selectedPaymentOption = event.target.value;
  persistSelfSelections();
  updateSelfStatus(selfViewState.entries);
});

document.getElementById("selfReasonCodeSelect").addEventListener("change", event => {
  selfViewState.selectedReasonCode = event.target.value;
  persistSelfSelections();
  updateSelfStatus(selfViewState.entries);
});

document.getElementById("selfStatsRangeGroup").addEventListener("click", event => {
  const rangeButton = event.target.closest("[data-self-stats-range]");
  if (!rangeButton) {
    return;
  }

  selfViewState.statsFilter.range = rangeButton.getAttribute("data-self-stats-range") || "month";
  localStorage.setItem(SELF_STATS_RANGE_STORAGE_KEY, selfViewState.statsFilter.range);
  renderSelfStats(selfViewState.entries);
});

document.getElementById("selfStatsProjectFilter").addEventListener("change", event => {
  selfViewState.statsFilter.projectCode = event.target.value;
  renderSelfStats(selfViewState.entries);
});

document.getElementById("selfStatsStatusFilter").addEventListener("change", event => {
  selfViewState.statsFilter.status = event.target.value;
  renderSelfStats(selfViewState.entries);
});

["selfStatsStartDate", "selfStatsEndDate"].forEach(id => {
  document.getElementById(id).addEventListener("input", () => {
    selfViewState.statsFilter.range = "custom";
    selfViewState.statsFilter.startDate = document.getElementById("selfStatsStartDate").value;
    selfViewState.statsFilter.endDate = document.getElementById("selfStatsEndDate").value;
    localStorage.setItem(SELF_STATS_RANGE_STORAGE_KEY, "custom");
    renderSelfStats(selfViewState.entries);
  });
});

document.getElementById("selfStatsResetFiltersBtn").addEventListener("click", () => {
  selfViewState.statsFilter = {
    range: "month",
    projectCode: "",
    status: "",
    startDate: "",
    endDate: "",
  };
  localStorage.setItem(SELF_STATS_RANGE_STORAGE_KEY, "month");
  renderSelfStats(selfViewState.entries);
});

document.getElementById("selfEntriesContainer").addEventListener("click", event => {
  const gc179Button = event.target.closest(".self-gc179-fdf-button");
  if (gc179Button) {
    const monthKey = gc179Button.getAttribute("data-self-gc179-month") || selfViewState.currentMonthKey;
    runButtonAction(gc179Button, () => downloadGc179FdfExport({
      self: true,
      monthKey,
    }), { key: `self-gc179-export:${monthKey}` });
    return;
  }

  const yearNavButton = event.target.closest(".employee-calendar-year-button");
  if (yearNavButton) {
    const direction = yearNavButton.getAttribute("data-self-calendar-year-nav");
    const currentMonthKey = selfViewState.currentMonthKey || toCalendarMonthKey(new Date());
    selfViewState.currentMonthKey = shiftCalendarMonthKey(currentMonthKey, direction === "prev" ? -12 : 12);
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
});
