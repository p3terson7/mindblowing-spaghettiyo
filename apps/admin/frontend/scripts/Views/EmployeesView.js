const employeesViewState = {
  employees: [],
};

function setEmployeePasswordMessage(message, type) {
  const messageBox = document.getElementById("employeePasswordMessage");
  if (!message) {
    messageBox.className = "alert d-none";
    messageBox.textContent = "";
    return;
  }

  messageBox.className = `alert alert-${type || "danger"}`;
  messageBox.textContent = message;
}

function resetEmployeePasswordForm() {
  document.getElementById("employeePasswordCodeInput").value = "";
  document.getElementById("employeePasswordNameInput").value = "";
  document.getElementById("employeePasswordValueInput").value = "";
  document.getElementById("employeePasswordConfirmInput").value = "";
  document.getElementById("employeePasswordMustChangeInput").checked = true;
  setEmployeePasswordMessage("");
}

function openEmployeePasswordModal(employeeCode, employeeName) {
  resetEmployeePasswordForm();
  document.getElementById("employeePasswordCodeInput").value = employeeCode;
  document.getElementById("employeePasswordNameInput").value = `${employeeName} (${employeeCode})`;
  const modal = new bootstrap.Modal(document.getElementById("employeePasswordModal"));
  modal.show();
}

async function submitEmployeePasswordReset() {
  setEmployeePasswordMessage("");

  const employeeCode = document.getElementById("employeePasswordCodeInput").value;
  const newPassword = document.getElementById("employeePasswordValueInput").value;
  const confirmPassword = document.getElementById("employeePasswordConfirmInput").value;
  const mustChangePassword = document.getElementById("employeePasswordMustChangeInput").checked;

  if (!employeeCode || !newPassword || !confirmPassword) {
    setEmployeePasswordMessage("Employee code and both password fields are required.", "danger");
    return;
  }

  if (newPassword !== confirmPassword) {
    setEmployeePasswordMessage("The new passwords do not match.", "danger");
    return;
  }

  try {
    const response = await fetch(apiUrl + "employee/password/" + encodeURIComponent(employeeCode), {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        newPassword,
        mustChangePassword,
      }),
    });

    const result = await parseResponse(response);
    const modal = bootstrap.Modal.getInstance(document.getElementById("employeePasswordModal"));
    if (modal) {
      modal.hide();
    }
    resetEmployeePasswordForm();
    showToast(result.message || "Password updated successfully.", "success");
    await loadEmployeesView();
  } catch (error) {
    console.error("Error updating employee password:", error);
    setEmployeePasswordMessage(error.message || "Unable to update employee password.", "danger");
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
  document.getElementById("employeesDirectoryCount").textContent = `${employees.length} employee${employees.length === 1 ? "" : "s"}`;

  if (!employees || employees.length === 0) {
    container.innerHTML = createEmptyState("No employees match the current search.");
    return;
  }

  container.innerHTML = employees.map(employee => `
    <article class="employee-card">
      <div class="employee-card-header">
        <div class="d-flex align-items-center gap-3">
          <div class="employee-avatar">${escapeHtml(getEmployeeInitials(employee.name))}</div>
          <div>
            <div class="employee-card-title">${escapeHtml(employee.name)}</div>
            <div class="employee-card-note">Employee account</div>
          </div>
        </div>
      </div>
      <div class="employee-card-meta">
        <span class="inline-code-pill">EMP ${escapeHtml(employee.code)}</span>
        <span class="meta-pill">Password managed by admin</span>
      </div>
      <div class="employee-card-actions">
        <button type="button" class="btn btn-primary btn-sm employee-password-button" data-employee-code="${escapeHtml(employee.code)}" data-employee-name="${escapeHtml(employee.name)}">Set / Reset Password</button>
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
      showToast("Unable to load employees.", "error");
    });
}

document.getElementById("employeesDirectoryContainer").addEventListener("click", event => {
  const button = event.target.closest(".employee-password-button");
  if (!button) {
    return;
  }

  openEmployeePasswordModal(button.getAttribute("data-employee-code"), button.getAttribute("data-employee-name"));
});

document.getElementById("employeePasswordSaveButton").addEventListener("click", submitEmployeePasswordReset);
document.getElementById("employeePasswordForm").addEventListener("submit", event => {
  event.preventDefault();
  submitEmployeePasswordReset();
});
document.getElementById("employeesSearchInput").addEventListener("input", applyEmployeeSearchFilter);
