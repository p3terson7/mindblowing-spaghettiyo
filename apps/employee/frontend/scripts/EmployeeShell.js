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

function getCurrentEmployeeApiUrl() {
  return normalizeEmployeeApiUrl(window.apiUrl || getEmployeeApiUrl(), window.defaultApiUrl);
}

function getEmployeeFetchTargetUrl(resource) {
  if (typeof resource === "string") {
    return resource;
  }

  if (resource && typeof resource.url === "string") {
    return resource.url;
  }

  if (resource && typeof resource.href === "string") {
    return resource.href;
  }

  return "";
}

function getEmployeeBearerTokenFromHeader(headerValue) {
  const match = String(headerValue || "").match(/^Bearer\s+(.+)$/i);
  return match ? match[1].trim() : null;
}

function isEmployeeApiRequestUrl(targetUrl, routePrefix) {
  const activeApiUrl = getCurrentEmployeeApiUrl();
  if (!targetUrl || !activeApiUrl) {
    return false;
  }

  try {
    const requestUrl = new URL(targetUrl, window.location.href);
    const apiBaseUrl = new URL(activeApiUrl, window.location.href);
    if (requestUrl.origin !== apiBaseUrl.origin) {
      return false;
    }

    const basePath = apiBaseUrl.pathname.endsWith("/") ? apiBaseUrl.pathname : `${apiBaseUrl.pathname}/`;
    if (basePath !== "/" && requestUrl.pathname.indexOf(basePath) !== 0 && requestUrl.pathname !== apiBaseUrl.pathname) {
      return false;
    }

    if (!routePrefix) {
      return true;
    }

    const relativePath = basePath === "/"
      ? requestUrl.pathname.replace(/^\//, "")
      : requestUrl.pathname.slice(basePath.length);
    return relativePath.indexOf(routePrefix) === 0;
  } catch (error) {
    const normalizedApiUrl = normalizeEmployeeApiUrl(activeApiUrl, window.defaultApiUrl);
    if (String(targetUrl).indexOf(normalizedApiUrl) !== 0) {
      return false;
    }

    return routePrefix
      ? String(targetUrl).indexOf(normalizedApiUrl + routePrefix) === 0
      : true;
  }
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
    const headers = new Headers(requestOptions.headers || (resource && resource.headers) || {});
    const targetUrl = getEmployeeFetchTargetUrl(resource);
    const token = getEmployeeSessionToken();
    let requestToken = getEmployeeBearerTokenFromHeader(headers.get("Authorization"));

    if (token && isEmployeeApiRequestUrl(targetUrl) && !headers.has("Authorization")) {
      headers.set("Authorization", `Bearer ${token}`);
      requestToken = token;
    }

    requestOptions.headers = headers;

    return employeeShellState.nativeFetch(resource, requestOptions).then(response => {
      const isAuthRequest = isEmployeeApiRequestUrl(targetUrl, "auth/");
      if (response.status === 401 && !isAuthRequest) {
        const currentToken = getEmployeeSessionToken();
        if (!currentToken || (requestToken && currentToken === requestToken)) {
          handleEmployeeSessionExpired();
        }
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

  const restoreToken = session.token;
  try {
    const response = await fetch(apiUrl + "auth/me");
    const currentUser = await parseResponse(response);
    const latestSession = getStoredEmployeeSession();
    if (!latestSession || latestSession.token !== restoreToken) {
      return;
    }

    await applyEmployeeSession({
      token: restoreToken,
      user: currentUser,
    });
  } catch (error) {
    const latestSession = getStoredEmployeeSession();
    if (latestSession && latestSession.token !== restoreToken) {
      return;
    }

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
