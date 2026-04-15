const employeesViewState = {
  employees: [],
  selectedEmployeeCode: "",
  entriesByEmployee: {},
  currentMonthByEmployee: {},
  expandedNotes: {},
};

function setEmployeeEditorMessage(message, type) {
  const messageBox = document.getElementById("employeeEditorMessage");
  if (!message) {
    messageBox.className = "alert d-none";
    messageBox.textContent = "";
    return;
  }

  messageBox.className = `alert alert-${type || "danger"}`;
  messageBox.textContent = message;
}

function resetEmployeeEditorForm() {
  document.getElementById("employeeEditorMode").value = "create";
  document.getElementById("employeeEditorModalLabel").textContent = t("employees.addEmployee");
  document.getElementById("employeeEditorOriginalNameInput").value = "";
  document.getElementById("employeeEditorCodeInput").value = "";
  document.getElementById("employeeEditorCodeInput").readOnly = false;
  document.getElementById("employeeEditorNameInput").value = "";
  document.getElementById("employeeEditorPasswordInput").value = "";
  document.getElementById("employeeEditorPasswordConfirmInput").value = "";
  document.getElementById("employeeEditorMustChangeInput").checked = true;
  document.getElementById("employeeEditorPasswordHint").textContent = t("employees.passwordHintCreate");
  document.getElementById("employeeEditorRemoveButton").classList.add("d-none");
  document.getElementById("employeeEditorRestoreButton").classList.add("d-none");
  setEmployeeEditorMessage("");
}

function openEmployeeEditorModal(mode, employee) {
  resetEmployeeEditorForm();

  if (mode === "edit" && employee) {
    document.getElementById("employeeEditorMode").value = "edit";
    document.getElementById("employeeEditorModalLabel").textContent = t("employees.editEmployee");
    document.getElementById("employeeEditorOriginalNameInput").value = employee.name || "";
    document.getElementById("employeeEditorCodeInput").value = employee.code || "";
    document.getElementById("employeeEditorCodeInput").readOnly = true;
    document.getElementById("employeeEditorNameInput").value = employee.name || "";
    document.getElementById("employeeEditorPasswordHint").textContent = t("employees.passwordHintEdit");

    if (employee.archived) {
      document.getElementById("employeeEditorRestoreButton").classList.remove("d-none");
    } else {
      document.getElementById("employeeEditorRemoveButton").classList.remove("d-none");
    }
  }

  const modal = new bootstrap.Modal(document.getElementById("employeeEditorModal"));
  modal.show();
}

async function submitEmployeeEditor() {
  setEmployeeEditorMessage("");

  const mode = document.getElementById("employeeEditorMode").value;
  const employeeCode = document.getElementById("employeeEditorCodeInput").value.trim();
  const employeeName = document.getElementById("employeeEditorNameInput").value.trim();
  const originalName = document.getElementById("employeeEditorOriginalNameInput").value.trim();
  const newPassword = document.getElementById("employeeEditorPasswordInput").value;
  const confirmPassword = document.getElementById("employeeEditorPasswordConfirmInput").value;
  const mustChangePassword = document.getElementById("employeeEditorMustChangeInput").checked;
  const hasPasswordChange = Boolean(newPassword || confirmPassword);

  if (!employeeCode || !employeeName) {
    setEmployeeEditorMessage(t("employees.codeAndNameRequired"), "danger");
    return;
  }

  if (hasPasswordChange && newPassword !== confirmPassword) {
    setEmployeeEditorMessage(t("employees.passwordsDoNotMatch"), "danger");
    return;
  }

  if (mode === "create") {
    try {
      const response = await fetch(apiUrl + "employees", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          code: employeeCode,
          name: employeeName,
          initialPassword: newPassword,
          mustChangePassword,
        }),
      });

      const result = await parseResponse(response);
      const modal = bootstrap.Modal.getInstance(document.getElementById("employeeEditorModal"));
      if (modal) {
        modal.hide();
      }
      resetEmployeeEditorForm();
      const temporaryPassword = result && result.temporaryPassword ? result.temporaryPassword : newPassword;
      if (temporaryPassword) {
        showToast(t("employees.createdWithPassword", { name: employeeName, password: temporaryPassword }), "success");
      } else {
        showToast(t("employees.employeeCreated"), "success");
      }
      await loadEmployeesView();
    } catch (error) {
      console.error("Error creating employee:", error);
      setEmployeeEditorMessage(error.message || t("employees.createError"), "danger");
    }
    return;
  }

  if (employeeName === originalName && !hasPasswordChange) {
    setEmployeeEditorMessage(t("dashboard.noChanges"), "info");
    return;
  }

  try {
    if (employeeName !== originalName) {
      const response = await fetch(apiUrl + "employees/" + encodeURIComponent(employeeCode), {
        method: "PUT",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          name: employeeName,
        }),
      });

      await parseResponse(response);
    }

    if (hasPasswordChange) {
      const passwordResponse = await fetch(apiUrl + "employee/password/" + encodeURIComponent(employeeCode), {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          newPassword,
          mustChangePassword,
        }),
      });

      await parseResponse(passwordResponse);
    }

    const modal = bootstrap.Modal.getInstance(document.getElementById("employeeEditorModal"));
    if (modal) {
      modal.hide();
    }
    resetEmployeeEditorForm();
    let successKey = "employees.employeeUpdated";
    if (employeeName !== originalName && hasPasswordChange) {
      successKey = "employees.employeeUpdatedAndPassword";
    } else if (hasPasswordChange) {
      successKey = "employees.passwordUpdated";
    }
    showToast(t(successKey), "success");
    await loadEmployeesView();
  } catch (error) {
    console.error("Error updating employee:", error);
    setEmployeeEditorMessage(error.message || t("employees.updateError"), "danger");
  }
}

async function removeEmployee(employee) {
  if (!employee || !employee.code) {
    return;
  }

  const confirmed = window.confirm(t("employees.removeConfirm", { name: employee.name, code: employee.code }));
  if (!confirmed) {
    return;
  }

  try {
    const response = await fetch(apiUrl + "employees/" + encodeURIComponent(employee.code), {
      method: "DELETE",
    });
    await parseResponse(response);
    showToast(t("employees.employeeRemoved"), "success");
    await loadEmployeesView();
  } catch (error) {
    console.error("Error removing employee:", error);
    showToast(error.message || t("employees.removeError"), "error");
  }
}

async function restoreEmployee(employee) {
  if (!employee || !employee.code) {
    return;
  }

  const confirmed = window.confirm(t("employees.restoreConfirm", { name: employee.name, code: employee.code }));
  if (!confirmed) {
    return;
  }

  try {
    const response = await fetch(apiUrl + "employees/" + encodeURIComponent(employee.code) + "/restore", {
      method: "POST",
    });
    await parseResponse(response);
    showToast(t("employees.employeeRestored"), "success");
    await loadEmployeesView();
  } catch (error) {
    console.error("Error restoring employee:", error);
    showToast(error.message || t("employees.restoreError"), "error");
  }
}

function getEmployeeInitials(name) {
  const parts = String(name || "").trim().split(/\s+/).filter(Boolean);
  if (parts.length === 0) {
    return "EM";
  }

  return parts.slice(0, 2).map(part => part[0].toUpperCase()).join("");
}

async function fetchEmployeeDetailEntries(employeeCode) {
  const response = await fetch(apiUrl + "employee/" + encodeURIComponent(employeeCode));
  if (response.status === 404) {
    return [];
  }
  const payload = await parseResponse(response);
  return Array.isArray(payload) ? payload : (payload ? [payload] : []);
}

function groupEmployeeEntriesByDate(entries) {
  return (entries || []).reduce((accumulator, entry) => {
    if (!accumulator[entry.date]) {
      accumulator[entry.date] = [];
    }
    accumulator[entry.date].push(entry);
    return accumulator;
  }, {});
}

function toMonthKey(dateValue) {
  const date = dateValue instanceof Date ? dateValue : parseLocalDate(dateValue);
  if (!date) {
    const now = new Date();
    return `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, "0")}`;
  }
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}`;
}

function shiftMonthKey(monthKey, delta) {
  const [year, month] = String(monthKey || "").split("-").map(Number);
  const baseDate = new Date(Number.isNaN(year) ? new Date().getFullYear() : year, Number.isNaN(month) ? new Date().getMonth() : month - 1, 1);
  baseDate.setMonth(baseDate.getMonth() + delta);
  return toMonthKey(baseDate);
}

function formatCalendarMonthLabel(monthKey) {
  const [year, month] = String(monthKey || "").split("-").map(Number);
  const date = new Date(Number.isNaN(year) ? new Date().getFullYear() : year, Number.isNaN(month) ? new Date().getMonth() : month - 1, 1);
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

function getDefaultEmployeeMonthKey(employeeCode, entries) {
  if (employeesViewState.currentMonthByEmployee[employeeCode]) {
    return employeesViewState.currentMonthByEmployee[employeeCode];
  }

  if (Array.isArray(entries) && entries.length > 0) {
    const sortedEntries = [...entries].sort((left, right) => new Date(right.date) - new Date(left.date));
    return toMonthKey(sortedEntries[0].date);
  }

  return toMonthKey(new Date());
}

function getEmployeeEntryKey(employeeCode, entry) {
  return `${employeeCode}__${entry.entryId || ""}__${entry.date || ""}__${entry.punchIn || ""}`;
}

function getEmployeeCalendarEntrySeconds(entry) {
  if (isEntryOpen(entry)) {
    const startedAt = toEntryDateTime(entry);
    return Math.max(0, Math.floor((Date.now() - startedAt.getTime()) / 1000));
  }
  return timeStringToSeconds(entry && entry.overtime);
}

function buildEmployeeMonthBoard(entries, activeMonthKey) {
  const [activeYear] = String(activeMonthKey || "").split("-").map(Number);
  const year = Number.isNaN(activeYear) ? new Date().getFullYear() : activeYear;
  const monthCounts = {};

  (entries || []).forEach(entry => {
    const monthKey = toMonthKey(entry.date);
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
      label: monthDate.toLocaleDateString(getCurrentLocale(), { month: "short" }),
      count: monthCounts[monthKey] || 0,
      active: monthKey === activeMonthKey,
    };
  });
}

function setDashboardEmployeeContext(employeeCode) {
  const employeeSelect = document.getElementById("employeeSelect");
  if (employeeSelect) {
    employeeSelect.value = employeeCode || "";
  }
  if (employeeCode) {
    localStorage.setItem("selectedEmployee", employeeCode);
  }
}

async function refreshPeopleEmployeeDetail(employeeCode) {
  if (!employeeCode) {
    return;
  }

  employeesViewState.entriesByEmployee[employeeCode] = undefined;
  if (typeof dashboardState !== "undefined") {
    dashboardState.entriesByEmployee[employeeCode] = undefined;
    dashboardState.historyLoaded = false;
    dashboardState.bootstrap = null;
  }

  const currentSearchValue = document.getElementById("employeesSearchInput").value;
  const currentScope = document.getElementById("employeesScopeSelect").value || "active";
  employeesViewState.selectedEmployeeCode = employeeCode;

  try {
    const response = await fetch(apiUrl + "employees?scope=" + encodeURIComponent(currentScope));
    const employees = await parseResponse(response);
    employeesViewState.employees = Array.isArray(employees) ? employees : [];
    document.getElementById("employeesSearchInput").value = currentSearchValue;
    applyEmployeeSearchFilter();
    await loadEmployeeDetail(employeeCode);
  } catch (error) {
    console.error("Error refreshing people employee detail:", error);
    showToast(t("employees.loadError"), "error");
  }
}

window.refreshPeopleEmployeeDetail = refreshPeopleEmployeeDetail;

function renderEmployeesDirectory(employees) {
  const container = document.getElementById("employeesDirectoryContainer");
  const detailContainer = document.getElementById("employeeDetailContainer");
  document.getElementById("employeesDirectoryCount").textContent = tn("shared.employee", employees.length);

  if (!employees || employees.length === 0) {
    container.innerHTML = createEmptyState(t("employees.none"));
    detailContainer.innerHTML = "";
    employeesViewState.selectedEmployeeCode = "";
    return;
  }

  if (!employees.some(employee => employee.code === employeesViewState.selectedEmployeeCode)) {
    employeesViewState.selectedEmployeeCode = "";
  }

  container.innerHTML = employees.map(employee => `
    <article class="employee-card${employeesViewState.selectedEmployeeCode === employee.code ? " is-active" : ""}" data-employee-code="${escapeHtml(employee.code)}">
      <div class="employee-card-header">
        <div class="d-flex align-items-center gap-3">
          <div class="employee-avatar">${escapeHtml(getEmployeeInitials(employee.name))}</div>
          <div>
            <div class="employee-card-title">${escapeHtml(employee.name)}</div>
            <div class="employee-card-note">${escapeHtml(employee.archived ? t("employees.archived") : t("shared.employeeAccount"))}</div>
          </div>
        </div>
      </div>
      <div class="employee-card-meta">
        <span class="inline-code-pill">EMP ${escapeHtml(employee.code)}</span>
        <span class="meta-pill">${escapeHtml(t("employees.entryCount", { count: employee.entryCount || 0 }))}</span>
        ${employee.archived ? `<span class="status-badge rejected">${escapeHtml(t("employees.archived"))}</span>` : ""}
      </div>
      <div class="employee-card-actions">
        <button type="button" class="btn btn-outline-secondary btn-sm employee-edit-button" data-employee-code="${escapeHtml(employee.code)}">${escapeHtml(t("action.edit"))}</button>
      </div>
    </article>
  `).join("");

  renderEmployeeDetail(getEmployeeByCode(employeesViewState.selectedEmployeeCode));
}

function renderEmployeeDetail(employee) {
  const container = document.getElementById("employeeDetailContainer");
  if (!employee) {
    container.innerHTML = "";
    return;
  }

  const entries = Array.isArray(employeesViewState.entriesByEmployee[employee.code]) ? employeesViewState.entriesByEmployee[employee.code] : [];
  const liveEntries = sortEntriesByDateTime(entries.filter(entry => isEntryOpen(entry)), true);
  const activeMonthKey = getDefaultEmployeeMonthKey(employee.code, entries);
  employeesViewState.currentMonthByEmployee[employee.code] = activeMonthKey;

  const monthEntries = entries.filter(entry => toMonthKey(entry.date) === activeMonthKey);
  const monthBoard = buildEmployeeMonthBoard(entries, activeMonthKey);
  const groupedEntries = groupEmployeeEntriesByDate(monthEntries);
  const [activeYear, activeMonth] = activeMonthKey.split("-").map(Number);
  const firstDayOfMonth = new Date(activeYear, activeMonth - 1, 1);
  const lastDayOfMonth = new Date(activeYear, activeMonth, 0);
  const gridStart = new Date(firstDayOfMonth);
  gridStart.setDate(firstDayOfMonth.getDate() - firstDayOfMonth.getDay());
  const gridEnd = new Date(lastDayOfMonth);
  gridEnd.setDate(lastDayOfMonth.getDate() + (6 - lastDayOfMonth.getDay()));
  const dayCells = [];
  const rollingDate = new Date(gridStart);

  while (rollingDate <= gridEnd) {
    const dateKey = `${rollingDate.getFullYear()}-${String(rollingDate.getMonth() + 1).padStart(2, "0")}-${String(rollingDate.getDate()).padStart(2, "0")}`;
    const dayEntries = groupedEntries[dateKey] || [];
    const isCurrentMonth = rollingDate.getMonth() === (activeMonth - 1);
    const totalDaySeconds = dayEntries.reduce((accumulator, entry) => accumulator + getEmployeeCalendarEntrySeconds(entry), 0);
    const entryPreview = dayEntries.map(entry => {
      const statusTone = getStatusTone(entry.status);
      const entryKey = getEmployeeEntryKey(employee.code, entry);
      const note = String(entry.message || "").trim();
      const showOverflowToggle = note.length > 120;
      const isExpanded = Boolean(employeesViewState.expandedNotes[entryKey]);
      const noteMarkup = note
        ? `
          <div class="calendar-entry-note${isExpanded ? " is-expanded" : ""}">
            <div class="calendar-entry-note-label">${escapeHtml(t("employees.managerNoteLabel"))}</div>
            <div class="calendar-entry-note-text">${escapeHtml(note)}</div>
            ${showOverflowToggle ? `<button type="button" class="calendar-note-toggle" data-note-key="${escapeHtml(entryKey)}">${escapeHtml(t(isExpanded ? "action.less" : "action.more"))}</button>` : ""}
          </div>
        `
        : "";

      const entryIdAttribute = ` data-entryid="${escapeHtml(entry.entryId || "")}"`;
      const exactPunchInAttribute = ` data-exactpunchin="${escapeHtml(getEntryExactPunchIn(entry))}"`;
      const exactPunchOutAttribute = ` data-exactpunchout="${escapeHtml(getEntryExactPunchOut(entry))}"`;
      const overtimeCodeAttribute = ` data-overtimecode="${escapeHtml(entry.overtimeCode || "")}"`;
      const messageAttribute = ` data-message="${escapeHtml(entry.message || "")}"`;
      const reviewButtons = String(entry.status || "pending").toLowerCase() === "pending" && !isEntryOpen(entry)
        ? `
          <button type="button" class="btn btn-success btn-sm action-btn calendar-entry-action-btn calendar-review-btn people-calendar-approve" data-employee-code="${escapeHtml(employee.code)}" data-date="${escapeHtml(entry.date)}" data-punchin="${escapeHtml(entry.punchIn)}"${entryIdAttribute} title="${escapeHtml(t("action.approve"))}">
            <i class="fa-solid fa-check"></i>
          </button>
          <button type="button" class="btn btn-danger btn-sm action-btn calendar-entry-action-btn calendar-review-btn people-calendar-reject" data-employee-code="${escapeHtml(employee.code)}" data-date="${escapeHtml(entry.date)}" data-punchin="${escapeHtml(entry.punchIn)}"${entryIdAttribute} title="${escapeHtml(t("action.reject"))}">
            <i class="fa-solid fa-ban"></i>
          </button>
        `
        : "";

      return `
        <div class="calendar-entry">
          <div class="calendar-entry-main">
            <span class="calendar-entry-time">${escapeHtml(getEntryRoundedTimeRange(entry))}</span>
            <span class="status-badge ${escapeHtml(statusTone)}">${escapeHtml(translateStatus(entry.status || "pending"))}</span>
          </div>
          <div class="calendar-entry-meta">${escapeHtml(getEntryContextLabel(entry))}</div>
          ${noteMarkup}
          ${reviewButtons ? `<div class="calendar-entry-actions calendar-entry-actions-review">${reviewButtons}</div>` : ""}
          <div class="calendar-entry-actions calendar-entry-actions-manage">
            <button type="button" class="btn btn-outline-secondary btn-sm action-btn calendar-entry-action-btn calendar-manage-btn people-calendar-edit" data-employee-code="${escapeHtml(employee.code)}" data-date="${escapeHtml(entry.date)}" data-punchin="${escapeHtml(entry.punchIn)}" data-punchout="${escapeHtml(entry.punchOut || "")}" data-projectcode="${escapeHtml(entry.projectCode || "")}"${overtimeCodeAttribute}${entryIdAttribute}${messageAttribute}${exactPunchInAttribute}${exactPunchOutAttribute} title="${escapeHtml(t("action.edit"))}">
              <i class="fa-solid fa-pen"></i> <span class="calendar-action-label">${escapeHtml(t("action.edit"))}</span>
            </button>
            <button type="button" class="btn btn-outline-secondary btn-sm action-btn calendar-entry-action-btn calendar-manage-btn people-calendar-delete" data-employee-code="${escapeHtml(employee.code)}" data-date="${escapeHtml(entry.date)}" data-punchin="${escapeHtml(entry.punchIn)}"${entryIdAttribute} title="${escapeHtml(t("action.delete"))}">
              <i class="fa-solid fa-trash"></i> <span class="calendar-action-label">${escapeHtml(t("action.delete"))}</span>
            </button>
          </div>
        </div>
      `;
    }).join("");

    dayCells.push(`
      <div class="calendar-day${isCurrentMonth ? "" : " is-muted"}${dayEntries.length > 0 ? " has-entries" : ""}">
        <div class="calendar-day-header">
          <span class="calendar-day-number">${rollingDate.getDate()}</span>
          ${dayEntries.length > 0 ? `<span class="calendar-day-total">${escapeHtml(secondsToDurationLabel(totalDaySeconds))}</span>` : ""}
        </div>
        <div class="calendar-day-body">
          ${entryPreview}
        </div>
      </div>
    `);

    rollingDate.setDate(rollingDate.getDate() + 1);
  }

  const monthTotalSeconds = monthEntries.reduce((accumulator, entry) => accumulator + getEmployeeCalendarEntrySeconds(entry), 0);
  const liveEntriesMarkup = liveEntries.length > 0
    ? `
      <div class="calendar-live-strip">
        ${liveEntries.map(entry => {
          const elapsedSeconds = getEmployeeCalendarEntrySeconds(entry);
          const entryIdAttribute = ` data-entryid="${escapeHtml(entry.entryId || "")}"`;
          const exactPunchInAttribute = ` data-exactpunchin="${escapeHtml(getEntryExactPunchIn(entry))}"`;
          const exactPunchOutAttribute = ` data-exactpunchout="${escapeHtml(getEntryExactPunchOut(entry))}"`;
          const overtimeCodeAttribute = ` data-overtimecode="${escapeHtml(entry.overtimeCode || "")}"`;
          const messageAttribute = ` data-message="${escapeHtml(entry.message || "")}"`;
          return `
            <article class="calendar-live-card">
              <div class="calendar-entry-main">
                <span class="calendar-entry-time">${escapeHtml(formatDateLabel(entry.date))} | ${escapeHtml(formatTimeString(getEntryExactPunchIn(entry)))} -> ${escapeHtml(t("shared.inProgress"))}</span>
                <span class="status-badge approved">${escapeHtml(t("shared.live"))}</span>
              </div>
              <div class="calendar-entry-meta">${escapeHtml(getEntryContextLabel(entry))}</div>
              <div class="calendar-entry-actions calendar-entry-actions-manage">
                <button type="button" class="btn btn-outline-secondary btn-sm action-btn calendar-entry-action-btn calendar-manage-btn people-calendar-edit" data-employee-code="${escapeHtml(employee.code)}" data-date="${escapeHtml(entry.date)}" data-punchin="${escapeHtml(entry.punchIn)}" data-punchout="${escapeHtml(entry.punchOut || "")}" data-projectcode="${escapeHtml(entry.projectCode || "")}"${overtimeCodeAttribute}${entryIdAttribute}${messageAttribute}${exactPunchInAttribute}${exactPunchOutAttribute} title="${escapeHtml(t("action.edit"))}">
                  <i class="fa-solid fa-pen"></i> <span class="calendar-action-label">${escapeHtml(t("action.edit"))}</span>
                </button>
                <button type="button" class="btn btn-outline-secondary btn-sm action-btn calendar-entry-action-btn calendar-manage-btn people-calendar-delete" data-employee-code="${escapeHtml(employee.code)}" data-date="${escapeHtml(entry.date)}" data-punchin="${escapeHtml(entry.punchIn)}"${entryIdAttribute} title="${escapeHtml(t("action.delete"))}">
                  <i class="fa-solid fa-trash"></i> <span class="calendar-action-label">${escapeHtml(t("action.delete"))}</span>
                </button>
                <span class="inline-code-pill">${escapeHtml(secondsToDurationLabel(elapsedSeconds))}</span>
              </div>
            </article>
          `;
        }).join("")}
      </div>
    `
    : "";
  const calendarMarkup = monthEntries.length > 0
    ? `
      <div class="employee-calendar-header">
        <div class="employee-calendar-nav">
          <button type="button" class="btn btn-outline-secondary btn-sm employee-calendar-year-button" data-calendar-year-nav="prev" data-employee-code="${escapeHtml(employee.code)}">
            <i class="fa-solid fa-chevron-left"></i>
          </button>
          <div class="employee-calendar-label">${escapeHtml(String(activeYear))}</div>
          <button type="button" class="btn btn-outline-secondary btn-sm employee-calendar-year-button" data-calendar-year-nav="next" data-employee-code="${escapeHtml(employee.code)}">
            <i class="fa-solid fa-chevron-right"></i>
          </button>
        </div>
        <div class="employee-calendar-summary">${escapeHtml(t("employees.calendarSummary", { count: monthEntries.length, duration: secondsToDurationLabel(monthTotalSeconds) }))}</div>
      </div>
      <div class="employee-month-board-shell">
        <div class="employee-month-board">
          ${monthBoard.map(month => `
            <button type="button" class="employee-month-chip${month.active ? " is-active" : ""}${month.count > 0 ? " has-entries" : ""}" data-month-key="${escapeHtml(month.monthKey)}" data-employee-code="${escapeHtml(employee.code)}">
              <span class="employee-month-chip-label">${escapeHtml(month.label)}</span>
              <span class="employee-month-chip-count">${escapeHtml(String(month.count))}</span>
            </button>
          `).join("")}
        </div>
      </div>
      ${liveEntriesMarkup}
      <div class="employee-calendar-grid">
        ${getCalendarWeekdayLabels().map(label => `<div class="calendar-weekday">${escapeHtml(label)}</div>`).join("")}
        ${dayCells.join("")}
      </div>
    `
    : `
      <div class="employee-calendar-header">
        <div class="employee-calendar-nav">
          <button type="button" class="btn btn-outline-secondary btn-sm employee-calendar-year-button" data-calendar-year-nav="prev" data-employee-code="${escapeHtml(employee.code)}">
            <i class="fa-solid fa-chevron-left"></i>
          </button>
          <div class="employee-calendar-label">${escapeHtml(String(activeYear))}</div>
          <button type="button" class="btn btn-outline-secondary btn-sm employee-calendar-year-button" data-calendar-year-nav="next" data-employee-code="${escapeHtml(employee.code)}">
            <i class="fa-solid fa-chevron-right"></i>
          </button>
        </div>
      </div>
      <div class="employee-month-board-shell">
        <div class="employee-month-board">
          ${monthBoard.map(month => `
            <button type="button" class="employee-month-chip${month.active ? " is-active" : ""}${month.count > 0 ? " has-entries" : ""}" data-month-key="${escapeHtml(month.monthKey)}" data-employee-code="${escapeHtml(employee.code)}">
              <span class="employee-month-chip-label">${escapeHtml(month.label)}</span>
              <span class="employee-month-chip-count">${escapeHtml(String(month.count))}</span>
            </button>
          `).join("")}
        </div>
      </div>
      ${liveEntriesMarkup}
      ${createEmptyState(t("employees.noEntriesForMonth"))}
    `;

  container.innerHTML = `
    <section class="panel-shell employee-detail-card">
      <div class="employee-detail-header">
        <div class="d-flex align-items-center gap-3">
          <div class="employee-avatar employee-avatar-large">${escapeHtml(getEmployeeInitials(employee.name))}</div>
          <div>
            <div class="employee-detail-title">${escapeHtml(employee.name)}</div>
            <div class="employee-card-note">${escapeHtml(employee.archived ? t("employees.archived") : t("shared.employeeAccount"))}</div>
          </div>
        </div>
        <div class="employee-detail-actions">
          <button type="button" class="btn btn-outline-secondary btn-sm employee-edit-button" data-employee-code="${escapeHtml(employee.code)}">${escapeHtml(t("action.edit"))}</button>
        </div>
      </div>
      <div class="employee-detail-meta">
        <span class="inline-code-pill">EMP ${escapeHtml(employee.code)}</span>
        <span class="meta-pill">${escapeHtml(t("employees.entryCount", { count: employee.entryCount || 0 }))}</span>
        ${employee.archived ? `<span class="status-badge rejected">${escapeHtml(t("employees.archived"))}</span>` : `<span class="status-badge approved">${escapeHtml(t("employees.scopeActive"))}</span>`}
      </div>
      <div class="employee-detail-section">
        <div class="panel-kicker">${escapeHtml(t("employees.calendar"))}</div>
        <div class="employee-detail-entries">
          ${calendarMarkup}
        </div>
      </div>
    </section>
  `;
}

async function loadEmployeeDetail(employeeCode) {
  const employee = getEmployeeByCode(employeeCode);
  const container = document.getElementById("employeeDetailContainer");
  if (!employee || !container) {
    return;
  }

  if (employeesViewState.entriesByEmployee[employeeCode]) {
    renderEmployeeDetail(employee);
    return;
  }

  setLoadingState("employeeDetailContainer", "detail", 1);

  try {
    const entries = await fetchEmployeeDetailEntries(employeeCode);
    employeesViewState.entriesByEmployee[employeeCode] = Array.isArray(entries) ? entries : [];
    renderEmployeeDetail(employee);
  } catch (error) {
    console.error("Error loading employee detail entries:", error);
    container.innerHTML = createEmptyState(t("dashboard.timelineLoadError"));
  }
}

function applyEmployeeSearchFilter() {
  const searchValue = document.getElementById("employeesSearchInput").value.trim().toLowerCase();
  if (!searchValue) {
    renderEmployeesDirectory(employeesViewState.employees);
    return;
  }

  const filteredEmployees = employeesViewState.employees.filter(employee => {
    const haystack = `${employee.name} ${employee.code}`.toLowerCase();
    return haystack.includes(searchValue);
  });
  renderEmployeesDirectory(filteredEmployees);
}

function loadEmployeesView() {
  setLoadingState("employeesDirectoryContainer", "grid", 4);
  document.getElementById("employeeDetailContainer").innerHTML = "";
  const scope = document.getElementById("employeesScopeSelect").value || "active";
  return fetch(apiUrl + "employees?scope=" + encodeURIComponent(scope))
    .then(parseResponse)
    .then(employees => {
      employeesViewState.employees = Array.isArray(employees) ? employees : [];
      applyEmployeeSearchFilter();
    })
    .catch(error => {
      console.error("Error loading employees view:", error);
      showToast(t("employees.loadError"), "error");
    });
}

function getEmployeeByCode(employeeCode) {
  return employeesViewState.employees.find(employee => employee.code === employeeCode) || null;
}

document.getElementById("employeesDirectoryContainer").addEventListener("click", event => {
  const editButton = event.target.closest(".employee-edit-button");
  if (editButton) {
    const employee = getEmployeeByCode(editButton.getAttribute("data-employee-code"));
    if (employee) {
      openEmployeeEditorModal("edit", employee);
    }
    return;
  }
  const employeeCard = event.target.closest(".employee-card");
  if (!employeeCard) {
    return;
  }

  const employeeCode = employeeCard.getAttribute("data-employee-code");
  if (!employeeCode) {
    return;
  }

  employeesViewState.selectedEmployeeCode = employeeCode;
  applyEmployeeSearchFilter();
  loadEmployeeDetail(employeeCode);
});

document.getElementById("employeeDetailContainer").addEventListener("click", async event => {
  const yearButton = event.target.closest(".employee-calendar-year-button");
  if (yearButton) {
    const employeeCode = yearButton.getAttribute("data-employee-code");
    const direction = yearButton.getAttribute("data-calendar-year-nav");
    if (employeeCode && direction) {
      const currentMonthKey = employeesViewState.currentMonthByEmployee[employeeCode] || toMonthKey(new Date());
      employeesViewState.currentMonthByEmployee[employeeCode] = shiftMonthKey(currentMonthKey, direction === "prev" ? -12 : 12);
      renderEmployeeDetail(getEmployeeByCode(employeeCode));
    }
    return;
  }

  const monthChip = event.target.closest(".employee-month-chip");
  if (monthChip) {
    const employeeCode = monthChip.getAttribute("data-employee-code");
    const monthKey = monthChip.getAttribute("data-month-key");
    if (employeeCode && monthKey) {
      employeesViewState.currentMonthByEmployee[employeeCode] = monthKey;
      renderEmployeeDetail(getEmployeeByCode(employeeCode));
    }
    return;
  }

  const noteToggle = event.target.closest(".calendar-note-toggle");
  if (noteToggle) {
    const noteKey = noteToggle.getAttribute("data-note-key");
    if (noteKey) {
      employeesViewState.expandedNotes[noteKey] = !employeesViewState.expandedNotes[noteKey];
      renderEmployeeDetail(getEmployeeByCode(employeesViewState.selectedEmployeeCode));
    }
    return;
  }

  const approveButton = event.target.closest(".people-calendar-approve");
  if (approveButton) {
    const employeeCode = approveButton.getAttribute("data-employee-code");
    if (employeeCode) {
      try {
        const response = await fetch(apiUrl + "employee/approval/" + employeeCode, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            entryId: approveButton.getAttribute("data-entryid") || "",
            date: approveButton.getAttribute("data-date"),
            punchIn: approveButton.getAttribute("data-punchin"),
            status: "approved",
            message: "",
          }),
        });
        await parseResponse(response);
        showToast(t("dashboard.entryUpdated"), "success");
        await refreshPeopleEmployeeDetail(employeeCode);
        if (typeof refreshDashboardView === "function") {
          refreshDashboardView();
        }
      } catch (error) {
        console.error("Error approving entry from calendar:", error);
        showToast(t("dashboard.approvalError", { message: error.message }), "error");
      }
    }
    return;
  }

  const rejectButton = event.target.closest(".people-calendar-reject");
  if (rejectButton) {
    const employeeCode = rejectButton.getAttribute("data-employee-code");
    const managerMessage = window.prompt(t("dashboard.rejectManagerMessagePrompt"), "");
    if (managerMessage === null) {
      return;
    }
    if (!String(managerMessage).trim()) {
      showToast(t("dashboard.managerMessageRequired"), "error");
      return;
    }
    if (employeeCode) {
      try {
        const response = await fetch(apiUrl + "employee/approval/" + employeeCode, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            entryId: rejectButton.getAttribute("data-entryid") || "",
            date: rejectButton.getAttribute("data-date"),
            punchIn: rejectButton.getAttribute("data-punchin"),
            status: "rejected",
            message: managerMessage.trim(),
          }),
        });
        await parseResponse(response);
        showToast(t("dashboard.entryUpdated"), "success");
        await refreshPeopleEmployeeDetail(employeeCode);
        if (typeof refreshDashboardView === "function") {
          refreshDashboardView();
        }
      } catch (error) {
        console.error("Error rejecting entry from calendar:", error);
        showToast(t("dashboard.approvalError", { message: error.message }), "error");
      }
    }
    return;
  }

  const deleteButton = event.target.closest(".people-calendar-delete");
  if (deleteButton) {
    const employeeCode = deleteButton.getAttribute("data-employee-code");
    const managerMessage = window.prompt(t("dashboard.deleteManagerMessagePrompt"), "");
    if (!window.confirm(t("dashboard.deleteConfirm"))) {
      return;
    }
    if (managerMessage === null) {
      return;
    }
    if (!String(managerMessage).trim()) {
      showToast(t("dashboard.managerMessageRequired"), "error");
      return;
    }
    if (employeeCode) {
      try {
        const response = await fetch(apiUrl + "employee/" + employeeCode, {
          method: "DELETE",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            entryId: deleteButton.getAttribute("data-entryid") || "",
            date: deleteButton.getAttribute("data-date"),
            punchIn: deleteButton.getAttribute("data-punchin"),
            message: managerMessage.trim(),
          }),
        });
        await parseResponse(response);
        showToast(t("dashboard.entryDeleted"), "success");
        await refreshPeopleEmployeeDetail(employeeCode);
        if (typeof refreshDashboardView === "function") {
          refreshDashboardView();
        }
      } catch (error) {
        console.error("Error deleting entry from calendar:", error);
        showToast(t("dashboard.entryDeleteError", { message: error.message }), "error");
      }
    }
    return;
  }

  const editButton = event.target.closest(".employee-edit-button");
  if (editButton) {
    const employee = getEmployeeByCode(editButton.getAttribute("data-employee-code"));
    if (employee) {
      openEmployeeEditorModal("edit", employee);
    }
    return;
  }

  const entryEditButton = event.target.closest(".people-calendar-edit");
  if (entryEditButton) {
    const employeeCode = entryEditButton.getAttribute("data-employee-code");
    if (employeeCode) {
      setDashboardEmployeeContext(employeeCode);
      if (typeof openUpdateModal === "function") {
        openUpdateModal(entryEditButton);
        document.getElementById("updateEntryForm").dataset.refreshPeopleEmployee = employeeCode;
      }
    }
  }
});

document.getElementById("addEmployeeButton").addEventListener("click", () => {
  openEmployeeEditorModal("create");
});
document.getElementById("employeeEditorRemoveButton").addEventListener("click", async () => {
  const employee = getEmployeeByCode(document.getElementById("employeeEditorCodeInput").value.trim());
  const modal = bootstrap.Modal.getInstance(document.getElementById("employeeEditorModal"));
  if (modal) {
    modal.hide();
  }
  await removeEmployee(employee);
});
document.getElementById("employeeEditorRestoreButton").addEventListener("click", async () => {
  const employee = getEmployeeByCode(document.getElementById("employeeEditorCodeInput").value.trim());
  const modal = bootstrap.Modal.getInstance(document.getElementById("employeeEditorModal"));
  if (modal) {
    modal.hide();
  }
  await restoreEmployee(employee);
});
document.getElementById("employeeEditorSaveButton").addEventListener("click", submitEmployeeEditor);
document.getElementById("employeeEditorForm").addEventListener("submit", event => {
  event.preventDefault();
  submitEmployeeEditor();
});
document.getElementById("employeesSearchInput").addEventListener("input", applyEmployeeSearchFilter);
document.getElementById("employeesScopeSelect").addEventListener("change", loadEmployeesView);
document.getElementById("employeesResetFiltersBtn").addEventListener("click", () => {
  document.getElementById("employeesSearchInput").value = "";
  document.getElementById("employeesScopeSelect").value = "active";
  loadEmployeesView();
});
document.getElementById("employeesDirectoryCount").textContent = tn("shared.employee", 0);
