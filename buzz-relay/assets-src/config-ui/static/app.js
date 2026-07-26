const form = document.querySelector("#setup-form");
const ownerInput = document.querySelector("#owner-key");
const ownerMessage = document.querySelector("#owner-message");
const ownerHex = document.querySelector("#owner-hex");
const ownerNpub = document.querySelector("#owner-npub");
const hexConfirmRow = document.querySelector("#hex-confirm-row");
const confirmPublicHex = document.querySelector("#confirm-public-hex");
const relayUrl = document.querySelector("#relay-url");
const mediaUrl = document.querySelector("#media-url");
const corsOrigins = document.querySelector("#cors-origins");
const resetPanel = document.querySelector("#reset-panel");
const confirmReset = document.querySelector("#confirm-reset");
const resetPhrase = document.querySelector("#reset-phrase");
const submitButton = document.querySelector("#submit-button");
const actionTitle = document.querySelector("#action-title");
const actionDetail = document.querySelector("#action-detail");
const result = document.querySelector("#result");
const statusBadge = document.querySelector("#relay-status");
const statusText = document.querySelector("#relay-status-text");

let status = null;
let preview = null;
let previewTimer = null;
let formTouched = false;

async function api(path, options = {}) {
  const response = await fetch(path, {
    ...options,
    headers: {
      "Content-Type": "application/json",
      "X-Buzz-Setup": "1",
      ...(options.headers || {}),
    },
  });
  const payload = await response.json();
  if (!response.ok) {
    const error = new Error(payload.error || `Request failed (${response.status})`);
    error.payload = payload;
    throw error;
  }
  return payload;
}

function setStatus(state, text) {
  statusBadge.dataset.state = state;
  statusText.textContent = text;
}

function renderStatus(nextStatus) {
  status = nextStatus;
  if (status.resetting) {
    setStatus("working", "Resetting application data");
  } else if (status.restarting) {
    setStatus("working", "Restarting relay");
  } else if (status.relayReady) {
    setStatus("ready", "Relay ready");
  } else if (status.configured) {
    setStatus("working", "Relay initializing");
  } else {
    setStatus("waiting", "Setup required");
  }

  if (!formTouched) {
    ownerInput.value = status.ownerNpub || "";
    relayUrl.value = status.relayUrl || defaultRelayUrl();
    mediaUrl.value = status.mediaBaseUrl || deriveMediaUrl(relayUrl.value);
    corsOrigins.value = status.corsOrigins || deriveOrigin(relayUrl.value);
    if (ownerInput.value) {
      previewOwnerKey();
    }
  }
  updateOwnerChangeState();
}

function defaultRelayUrl() {
  return status?.defaultRelayUrl || "";
}

function deriveMediaUrl(value) {
  try {
    const url = new URL(value);
    url.protocol = url.protocol === "wss:" ? "https:" : "http:";
    url.pathname = "/media";
    url.search = "";
    url.hash = "";
    return url.toString().replace(/\/$/, "");
  } catch (_error) {
    return "";
  }
}

function deriveOrigin(value) {
  try {
    const url = new URL(value);
    url.protocol = url.protocol === "wss:" ? "https:" : "http:";
    return `${url.protocol}//${url.host}`;
  } catch (_error) {
    return "";
  }
}

function showResult(kind, message) {
  result.className = `result ${kind}`;
  result.textContent = message;
}

function clearPreview(message = "") {
  preview = null;
  ownerHex.textContent = "Not validated";
  ownerNpub.textContent = "Not validated";
  ownerMessage.textContent = message;
  ownerMessage.dataset.kind = message ? "error" : "";
  hexConfirmRow.classList.add("hidden");
  confirmPublicHex.checked = false;
  updateOwnerChangeState();
}

async function previewOwnerKey() {
  const value = ownerInput.value.trim();
  if (!value) {
    clearPreview();
    return;
  }
  if (/^(nostr:)?nsec/i.test(value) || /private key/i.test(value)) {
    clearPreview("Private keys and nsec values are rejected.");
    return;
  }
  try {
    const response = await api("api/preview-key", {
      method: "POST",
      body: JSON.stringify({ ownerKey: value }),
    });
    if (ownerInput.value.trim() !== value) {
      return;
    }
    preview = response;
    ownerHex.textContent = preview.ownerHex;
    ownerNpub.textContent = preview.ownerNpub;
    ownerMessage.textContent = "Valid public-key format.";
    ownerMessage.dataset.kind = "success";
    hexConfirmRow.classList.toggle("hidden", !preview.rawHex);
  } catch (error) {
    clearPreview(error.message);
  }
  updateOwnerChangeState();
}

function updateOwnerChangeState() {
  const ownerChanged = Boolean(
    status?.ownerConfigured && preview?.ownerHex && preview.ownerHex !== status.ownerHex
  );
  resetPanel.classList.toggle("hidden", !ownerChanged);
  if (ownerChanged) {
    submitButton.textContent = "Reset data and apply owner";
    submitButton.classList.add("danger-button");
    actionTitle.textContent = "Destructive owner change";
    actionDetail.textContent = "All application data and generated relay identity will be reset.";
  } else if (status?.ownerConfigured) {
    submitButton.textContent = "Apply settings";
    submitButton.classList.remove("danger-button");
    actionTitle.textContent = "Relay configured";
    actionDetail.textContent = "Network-setting changes restart the relay without deleting data.";
  } else {
    submitButton.textContent = "Save and start relay";
    submitButton.classList.remove("danger-button");
    actionTitle.textContent = "Ready to configure";
    actionDetail.textContent = "Only public key material is written to the owner file.";
  }
}

ownerInput.addEventListener("input", () => {
  formTouched = true;
  preview = null;
  confirmPublicHex.checked = false;
  hexConfirmRow.classList.add("hidden");
  ownerMessage.textContent = "Validating public-key format...";
  ownerMessage.dataset.kind = "";
  updateOwnerChangeState();
  window.clearTimeout(previewTimer);
  previewTimer = window.setTimeout(previewOwnerKey, 250);
});

relayUrl.addEventListener("input", () => {
  formTouched = true;
});

relayUrl.addEventListener("change", () => {
  if (!mediaUrl.value || mediaUrl.value === status?.mediaBaseUrl) {
    mediaUrl.value = deriveMediaUrl(relayUrl.value);
  }
  if (!corsOrigins.value || corsOrigins.value === status?.corsOrigins) {
    corsOrigins.value = deriveOrigin(relayUrl.value);
  }
});

[mediaUrl, corsOrigins, confirmPublicHex, confirmReset, resetPhrase].forEach((element) => {
  element.addEventListener("input", () => {
    formTouched = true;
  });
});

form.addEventListener("submit", async (event) => {
  event.preventDefault();
  showResult("working", "Validating and applying configuration...");
  submitButton.disabled = true;
  try {
    await previewOwnerKey();
    if (!preview) {
      throw new Error(ownerMessage.textContent || "Enter a valid public key.");
    }
    const payload = {
      ownerKey: ownerInput.value,
      confirmPublicHex: confirmPublicHex.checked,
      relayUrl: relayUrl.value,
      mediaBaseUrl: mediaUrl.value,
      corsOrigins: corsOrigins.value,
      confirmReset: confirmReset.checked,
      resetPhrase: resetPhrase.value,
    };
    const response = await api("api/apply", {
      method: "POST",
      body: JSON.stringify(payload),
    });
    showResult("success", response.message);
    resetPhrase.value = "";
    confirmReset.checked = false;
    formTouched = false;
    await refreshStatus();
  } catch (error) {
    showResult("error", error.message);
  } finally {
    submitButton.disabled = false;
  }
});

async function refreshStatus() {
  try {
    const response = await fetch("api/status", { cache: "no-store" });
    if (!response.ok) {
      throw new Error(`Status request failed (${response.status})`);
    }
    renderStatus(await response.json());
  } catch (_error) {
    setStatus("error", "Setup service unavailable");
  }
}

refreshStatus();
window.setInterval(refreshStatus, 3000);
