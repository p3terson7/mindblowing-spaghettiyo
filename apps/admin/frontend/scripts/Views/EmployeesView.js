const employeesViewState = {
  employees: [],
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
    document.getElementById("employeeEditorRemoveButton").classList.remove("d-none");
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

function getEmployeeInitials(name) {
  const parts = String(name || "").trim().split(/\s+/).filter(Boolean);
  if (parts.length === 0) {
    return "EM";
  }

  return parts.slice(0, 2).map(part => part[0].toUpperCase()).join("");
}

function renderEmployeesDirectory(employees) {
  const container = document.getElementById("employeesDirectoryContainer");
  document.getElementById("employeesDirectoryCount").textContent = tn("shared.employee", employees.length);

  if (!employees || employees.length === 0) {
    container.innerHTML = createEmptyState(t("employees.none"));
    return;
  }

  container.innerHTML = employees.map(employee => `
    <article class="employee-card">
      <div class="employee-card-header">
        <div class="d-flex align-items-center gap-3">
          <div class="employee-avatar">${escapeHtml(getEmployeeInitials(employee.name))}</div>
          <div>
            <div class="employee-card-title">${escapeHtml(employee.name)}</div>
            <div class="employee-card-note">${escapeHtml(t("shared.employeeAccount"))}</div>
          </div>
        </div>
      </div>
      <div class="employee-card-meta">
        <span class="inline-code-pill">EMP ${escapeHtml(employee.code)}</span>
        <span class="meta-pill">${escapeHtml(t("employees.entryCount", { count: employee.entryCount || 0 }))}</span>
      </div>
      <div class="employee-card-actions">
        <button type="button" class="btn btn-outline-secondary btn-sm employee-edit-button" data-employee-code="${escapeHtml(employee.code)}">${escapeHtml(t("action.edit"))}</button>
      </div>
    </article>
  `).join("");
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
  return fetch(apiUrl + "employees")
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
document.getElementById("employeeEditorSaveButton").addEventListener("click", submitEmployeeEditor);
document.getElementById("employeeEditorForm").addEventListener("submit", event => {
  event.preventDefault();
  submitEmployeeEditor();
});
document.getElementById("employeesSearchInput").addEventListener("input", applyEmployeeSearchFilter);
document.getElementById("employeesDirectoryCount").textContent = tn("shared.employee", 0);
