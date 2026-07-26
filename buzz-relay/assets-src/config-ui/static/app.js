const form = document.querySelector("#setup-form");
const configuredView = document.querySelector("#configured-view");
const ownerInput = document.querySelector("#owner-key");
const ownerMessage = document.querySelector("#owner-message");
const verifiedKey = document.querySelector("#verified-key");
const ownerHex = document.querySelector("#owner-hex");
const ownerNpub = document.querySelector("#owner-npub");
const hexConfirmRow = document.querySelector("#hex-confirm-row");
const confirmPublicHex = document.querySelector("#confirm-public-hex");
const modeInputs = [...document.querySelectorAll('input[name="communityMode"]')];
const localDetail = document.querySelector("#local-detail");
const publicDetail = document.querySelector("#public-detail");
const localCommunityUrl = document.querySelector("#local-community-url");
const publicCommunityUrl = document.querySelector("#public-community-url");
const reviewOwner = document.querySelector("#review-owner");
const reviewCommunityUrl = document.querySelector("#review-community-url");
const resetPanel = document.querySelector("#reset-panel");
const confirmReset = document.querySelector("#confirm-reset");
const resetPhrase = document.querySelector("#reset-phrase");
const submitButton = document.querySelector("#submit-button");
const actionTitle = document.querySelector("#action-title");
const actionDetail = document.querySelector("#action-detail");
const result = document.querySelector("#result");
const statusBadge = document.querySelector("#relay-status");
const statusText = document.querySelector("#relay-status-text");
const configuredCommunityUrl = document.querySelector("#configured-community-url");
const configuredOwner = document.querySelector("#configured-owner");
const configuredMode = document.querySelector("#configured-mode");
const editButton = document.querySelector("#edit-button");
const copyCommunityUrl = document.querySelector("#copy-community-url");

let status = null;
let preview = null;
let previewTimer = null;
let formTouched = false;
let editing = false;

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

function selectedMode() {
  return modeInputs.find((input) => input.checked)?.value || "local";
}

function selectedCommunityUrl() {
  return selectedMode() === "local"
    ? status?.localCommunityUrl || ""
    : publicCommunityUrl.value.trim();
}

function setSelectedMode(mode) {
  const selected = modeInputs.find((input) => input.value === mode) || modeInputs[0];
  selected.checked = true;
}

function renderMode() {
  const local = selectedMode() === "local";
  localDetail.classList.toggle("hidden", !local);
  publicDetail.classList.toggle("hidden", local);
  publicCommunityUrl.required = !local;
  syncReview();
}

function syncReview() {
  reviewOwner.textContent = preview?.ownerNpub || "Not verified";
  reviewCommunityUrl.textContent = selectedCommunityUrl() || "Not selected";
}

function populateConfiguredView() {
  configuredCommunityUrl.textContent = status?.communityUrl || "Unavailable";
  configuredOwner.textContent = status?.ownerNpub || "Unavailable";
  configuredMode.textContent = status?.communityMode === "public"
    ? "Public community"
    : "Local testing";
}

function hydrateForm() {
  ownerInput.value = status?.ownerNpub || "";
  setSelectedMode(status?.communityMode || "local");
  publicCommunityUrl.value = status?.communityMode === "public"
    ? status.communityUrl || ""
    : "";
  localCommunityUrl.textContent = status?.localCommunityUrl || "Unavailable";
  renderMode();
  if (ownerInput.value) {
    void previewOwnerKey();
  } else {
    clearPreview();
  }
}

function renderStatus(nextStatus) {
  status = nextStatus;
  if (status.resetting) {
    setStatus("working", "Resetting application data");
  } else if (status.restarting) {
    setStatus("working", "Restarting relay");
  } else if (status.relayReady) {
    setStatus("ready", "Relay ready");
  } else if (!status.configured) {
    setStatus("waiting", "Setup required");
  } else if (status.relayState === "retrying-after-exit") {
    setStatus("error", "Relay start failed; retrying");
  } else if (status.relayState === "waiting-for-storage") {
    setStatus("working", "Waiting for object storage");
  } else if (status.relayState === "stopping") {
    setStatus("working", "Relay stopping");
  } else {
    setStatus("working", "Relay starting");
  }

  localCommunityUrl.textContent = status.localCommunityUrl || "Unavailable";
  const showConfigured = status.configured && !editing;
  configuredView.classList.toggle("hidden", !showConfigured);
  form.classList.toggle("hidden", showConfigured);
  if (showConfigured) {
    populateConfiguredView();
  } else if (!formTouched) {
    hydrateForm();
  }
  updateOwnerChangeState();
}

function showResult(kind, message) {
  result.className = `result ${kind}`;
  result.textContent = message;
}

function hideResult() {
  result.className = "result hidden";
  result.textContent = "";
}

function clearPreview(message = "") {
  preview = null;
  verifiedKey.classList.add("hidden");
  ownerHex.textContent = "";
  ownerNpub.textContent = "";
  ownerMessage.textContent = message;
  ownerMessage.dataset.kind = message ? "error" : "";
  hexConfirmRow.classList.add("hidden");
  confirmPublicHex.checked = false;
  syncReview();
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
    ownerMessage.textContent = "Owner public key verified.";
    ownerMessage.dataset.kind = "success";
    verifiedKey.classList.remove("hidden");
    hexConfirmRow.classList.toggle("hidden", !preview.rawHex);
  } catch (error) {
    clearPreview(error.message);
  }
  syncReview();
  updateOwnerChangeState();
}

function updateOwnerChangeState() {
  const ownerChanged = Boolean(
    status?.ownerConfigured && preview?.ownerHex && preview.ownerHex !== status.ownerHex
  );
  resetPanel.classList.toggle("hidden", !ownerChanged);
  if (ownerChanged) {
    submitButton.textContent = "Reset data and change owner";
    submitButton.classList.add("danger-button");
    actionTitle.textContent = "Destructive owner change";
    actionDetail.textContent = "A full application data reset is required.";
  } else if (status?.ownerConfigured) {
    submitButton.textContent = "Save configuration";
    submitButton.classList.remove("danger-button");
    actionTitle.textContent = "Review changes";
    actionDetail.textContent = "Changing the Community URL restarts the relay.";
  } else {
    submitButton.textContent = "Save and start relay";
    submitButton.classList.remove("danger-button");
    actionTitle.textContent = "Ready to configure";
    actionDetail.textContent = "Only the verified public key is saved.";
  }
}

ownerInput.addEventListener("input", () => {
  formTouched = true;
  preview = null;
  verifiedKey.classList.add("hidden");
  confirmPublicHex.checked = false;
  hexConfirmRow.classList.add("hidden");
  ownerMessage.textContent = "Verifying public key...";
  ownerMessage.dataset.kind = "";
  syncReview();
  updateOwnerChangeState();
  window.clearTimeout(previewTimer);
  previewTimer = window.setTimeout(previewOwnerKey, 250);
});

modeInputs.forEach((input) => {
  input.addEventListener("change", () => {
    formTouched = true;
    renderMode();
  });
});

publicCommunityUrl.addEventListener("input", () => {
  formTouched = true;
  syncReview();
});

[confirmPublicHex, confirmReset, resetPhrase].forEach((element) => {
  element.addEventListener("input", () => {
    formTouched = true;
  });
});

editButton.addEventListener("click", () => {
  editing = true;
  formTouched = false;
  hideResult();
  renderStatus(status);
  ownerInput.focus();
});

copyCommunityUrl.addEventListener("click", async () => {
  const value = status?.communityUrl || "";
  if (!value) return;
  try {
    await navigator.clipboard.writeText(value);
    copyCommunityUrl.textContent = "Copied";
    window.setTimeout(() => {
      copyCommunityUrl.textContent = "Copy community URL";
    }, 1600);
  } catch (_error) {
    showResult("error", "Copy failed. Select and copy the Community URL manually.");
  }
});

form.addEventListener("submit", async (event) => {
  event.preventDefault();
  showResult("working", "Saving configuration...");
  submitButton.disabled = true;
  try {
    await previewOwnerKey();
    if (!preview) {
      throw new Error(ownerMessage.textContent || "Enter a valid public key.");
    }
    const communityMode = selectedMode();
    const communityUrl = selectedCommunityUrl();
    if (!communityUrl) {
      throw new Error("Enter or select a Community URL.");
    }
    const response = await api("api/apply", {
      method: "POST",
      body: JSON.stringify({
        ownerKey: ownerInput.value,
        confirmPublicHex: confirmPublicHex.checked,
        communityMode,
        communityUrl: communityMode === "public" ? communityUrl : "",
        confirmReset: confirmReset.checked,
        resetPhrase: resetPhrase.value,
      }),
    });
    showResult("success", response.message);
    resetPhrase.value = "";
    confirmReset.checked = false;
    formTouched = false;
    editing = false;
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
