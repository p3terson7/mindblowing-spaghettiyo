const employeeShellState = {
  nativeFetch: window.fetch.bind(window),
  initialized: false,
  syncTimerId: null,
  lastSyncVersion: null,
};

function normalizeEmployeeApiUrl(value, fallbackValue) {
  const rawValue = (value || fallbackValue || "").trim();
  if (!rawValue) {
    return "";
  }

  return rawValue.endsWith("/") ? rawValue : `${rawValue}/`;
}

function getEmployeeApiUrl() {
  return normalizeEmployeeApiUrl(localStorage.getItem("employeeApiUrl"), window.defaultApiUrl);
}

function setEmployeeApiUrl(value) {
  window.apiUrl = normalizeEmployeeApiUrl(value, window.defaultApiUrl);
  localStorage.setItem("employeeApiUrl", window.apiUrl);
  document.getElementById("employeeApiUrlInput").value = window.apiUrl;
}

function getStoredEmployeeSession() {
  try {
    const raw = localStorage.getItem("employeeSession");
    return raw ? JSON.parse(raw) : null;
  } catch (error) {
    return null;
  }
}

function setStoredEmployeeSession(session) {
  localStorage.setItem("employeeSession", JSON.stringify(session));
}

function clearStoredEmployeeSession() {
  localStorage.removeItem("employeeSession");
}

function getEmployeeSessionToken() {
  const session = getStoredEmployeeSession();
  return session && session.token ? session.token : null;
}

function getEmployeeUser() {
  const session = getStoredEmployeeSession();
  return session && session.user ? session.user : null;
}

function updateEmployeeSessionSummary() {
  const summary = document.getElementById("employeeSessionSummary");
  const logoutButton = document.getElementById("employeeLogoutButton");
  const user = getEmployeeUser();

  if (user) {
    const identity = user.displayName || user.username;
    const codeSuffix = user.employeeCode ? ` (${user.employeeCode})` : "";
    summary.textContent = identity + codeSuffix;
    logoutButton.classList.remove("d-none");
  } else {
    summary.textContent = "Not signed in";
    logoutButton.classList.add("d-none");
  }
}

function setEmployeeAuthMessage(message, type) {
  const messageBox = document.getElementById("employeeAuthMessage");
  if (!message) {
    messageBox.className = "alert d-none";
    messageBox.textContent = "";
    return;
  }

  messageBox.className = `alert alert-${type || "danger"}`;
  messageBox.textContent = message;
}

function showEmployeeAuthOverlay(requirePasswordChange) {
  document.getElementById("employeeAuthOverlay").classList.remove("d-none");
  document.getElementById("employeePasswordChangeSection").classList.toggle("d-none", !requirePasswordChange);
  document.getElementById("employeeLoginSubmitButton").classList.toggle("d-none", requirePasswordChange);
  document.getElementById("employeeChangePasswordButton").classList.toggle("d-none", !requirePasswordChange);
}

function hideEmployeeAuthOverlay() {
  document.getElementById("employeeAuthOverlay").classList.add("d-none");
  setEmployeeAuthMessage("");
}

function stopEmployeeSyncPolling() {
  if (employeeShellState.syncTimerId) {
    window.clearInterval(employeeShellState.syncTimerId);
    employeeShellState.syncTimerId = null;
  }
}

function installEmployeeFetchWrapper() {
  window.fetch = function (resource, options) {
    const requestOptions = options ? { ...options } : {};
    const headers = new Headers(requestOptions.headers || {});
    const targetUrl = typeof resource === "string" ? resource : resource.url;
    const token = getEmployeeSessionToken();

    if (token && typeof targetUrl === "string" && targetUrl.indexOf(apiUrl) === 0 && !headers.has("Authorization")) {
      headers.set("Authorization", `Bearer ${token}`);
    }

    requestOptions.headers = headers;

    return employeeShellState.nativeFetch(resource, requestOptions).then(response => {
      const isAuthRequest = typeof targetUrl === "string" && targetUrl.indexOf(apiUrl + "auth/") === 0;
      if (response.status === 401 && !isAuthRequest) {
        handleEmployeeSessionExpired();
      }
      return response;
    });
  };
}

function handleEmployeeSessionExpired() {
  stopEmployeeSyncPolling();
  employeeShellState.lastSyncVersion = null;
  clearStoredEmployeeSession();
  updateEmployeeSessionSummary();
  showEmployeeAuthOverlay(false);
  setEmployeeAuthMessage("Your session expired. Sign in again to continue.", "warning");
}

async function refreshEmployeeView() {
  if (typeof fetchEntries === "function") {
    await fetchEntries();
  }
}

async function pollEmployeeSyncState() {
  const token = getEmployeeSessionToken();
  if (!token) {
    return;
  }

  try {
    const response = await fetch(apiUrl + "sync/status");
    const syncState = await parseResponse(response);
    const nextVersion = syncState && typeof syncState.version === "number" ? syncState.version : 0;

    if (employeeShellState.lastSyncVersion === null) {
      employeeShellState.lastSyncVersion = nextVersion;
      return;
    }

    if (nextVersion !== employeeShellState.lastSyncVersion) {
      employeeShellState.lastSyncVersion = nextVersion;
      await refreshEmployeeView();
    }
  } catch (error) {
    console.error("Unable to refresh employee sync state:", error);
  }
}

function startEmployeeSyncPolling() {
  stopEmployeeSyncPolling();
  employeeShellState.syncTimerId = window.setInterval(() => {
    pollEmployeeSyncState();
  }, 2500);
}

async function bootstrapEmployeeApplication() {
  if (typeof setDefaultFilters === "function") {
    setDefaultFilters();
  }

  await refreshEmployeeView();
  await pollEmployeeSyncState();
  startEmployeeSyncPolling();
  employeeShellState.initialized = true;
}

async function applyEmployeeSession(authResult) {
  if (!authResult || !authResult.token || !authResult.user) {
    throw new Error("Authentication response was incomplete.");
  }

  if (!authResult.user.employeeCode) {
    clearStoredEmployeeSession();
    updateEmployeeSessionSummary();
    showEmployeeAuthOverlay(false);
    throw new Error("This interface requires an employee account.");
  }

  setStoredEmployeeSession({
    token: authResult.token,
    user: authResult.user,
  });
  updateEmployeeSessionSummary();

  if (authResult.user.mustChangePassword) {
    showEmployeeAuthOverlay(true);
    setEmployeeAuthMessage("Password change required before continuing.", "warning");
    return;
  }

  hideEmployeeAuthOverlay();

  if (!employeeShellState.initialized) {
    await bootstrapEmployeeApplication();
  } else {
    await refreshEmployeeView();
    await pollEmployeeSyncState();
    startEmployeeSyncPolling();
  }
}

async function submitEmployeeLogin(event) {
  event.preventDefault();

  setEmployeeApiUrl(document.getElementById("employeeApiUrlInput").value);
  setEmployeeAuthMessage("");

  const username = document.getElementById("employeeUsernameInput").value.trim();
  const password = document.getElementById("employeePasswordInput").value;

  if (!username || !password) {
    setEmployeeAuthMessage("Employee code and password are required.", "danger");
    return;
  }

  try {
    const response = await employeeShellState.nativeFetch(apiUrl + "auth/login", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ username, password }),
    });

    const authResult = await parseResponse(response);
    await applyEmployeeSession(authResult);
  } catch (error) {
    setEmployeeAuthMessage(error.message || "Unable to sign in.", "danger");
  }
}

async function submitEmployeePasswordChange() {
  setEmployeeAuthMessage("");

  const currentPassword = document.getElementById("employeePasswordInput").value;
  const newPassword = document.getElementById("employeeNewPasswordInput").value;
  const confirmPassword = document.getElementById("employeeConfirmPasswordInput").value;

  if (!currentPassword || !newPassword || !confirmPassword) {
    setEmployeeAuthMessage("Current password and both new password fields are required.", "danger");
    return;
  }

  if (newPassword !== confirmPassword) {
    setEmployeeAuthMessage("The new passwords do not match.", "danger");
    return;
  }

  try {
    const response = await fetch(apiUrl + "auth/change-password", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        currentPassword,
        newPassword,
      }),
    });

    await parseResponse(response);

    const session = getStoredEmployeeSession();
    if (session && session.user) {
      session.user.mustChangePassword = false;
      setStoredEmployeeSession(session);
    }

    document.getElementById("employeeNewPasswordInput").value = "";
    document.getElementById("employeeConfirmPasswordInput").value = "";
    updateEmployeeSessionSummary();
    hideEmployeeAuthOverlay();

    if (!employeeShellState.initialized) {
      await bootstrapEmployeeApplication();
    } else {
      await refreshEmployeeView();
      await pollEmployeeSyncState();
      startEmployeeSyncPolling();
    }

    showToast("Password updated successfully.", "success");
  } catch (error) {
    setEmployeeAuthMessage(error.message || "Unable to update password.", "danger");
  }
}

async function submitEmployeeLogout() {
  stopEmployeeSyncPolling();

  const token = getEmployeeSessionToken();
  if (token) {
    try {
      await employeeShellState.nativeFetch(apiUrl + "auth/logout", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
        },
      });
    } catch (error) {
      console.error("Unable to sign out cleanly:", error);
    }
  }

  employeeShellState.lastSyncVersion = null;
  clearStoredEmployeeSession();
  updateEmployeeSessionSummary();
  showEmployeeAuthOverlay(false);
  setEmployeeAuthMessage("Signed out successfully.", "success");
}

async function restoreEmployeeSession() {
  const session = getStoredEmployeeSession();
  if (!session || !session.token) {
    showEmployeeAuthOverlay(false);
    return;
  }

  try {
    const response = await fetch(apiUrl + "auth/me");
    const currentUser = await parseResponse(response);
    await applyEmployeeSession({
      token: session.token,
      user: currentUser,
    });
  } catch (error) {
    clearStoredEmployeeSession();
    updateEmployeeSessionSummary();
    showEmployeeAuthOverlay(false);
    setEmployeeAuthMessage("Sign in to continue.", "warning");
  }
}

document.addEventListener("DOMContentLoaded", () => {
  window.apiUrl = getEmployeeApiUrl();
  document.getElementById("employeeApiUrlInput").value = window.apiUrl;
  document.getElementById("employeeLoginForm").addEventListener("submit", submitEmployeeLogin);
  document.getElementById("employeeChangePasswordButton").addEventListener("click", submitEmployeePasswordChange);
  document.getElementById("employeeLogoutButton").addEventListener("click", submitEmployeeLogout);
  updateEmployeeSessionSummary();
  installEmployeeFetchWrapper();
  restoreEmployeeSession();
});
