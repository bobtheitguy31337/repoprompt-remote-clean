import { createServer } from "node:http";
import { createSign } from "node:crypto";
import { pathToFileURL } from "node:url";

export const MAX_BODY_BYTES = 128 * 1024;
const NOTIFICATION_CATEGORIES = new Set([
  "agent_needs_input",
  "approval_required",
  "completed",
  "failed"
]);

export class RelayValidationError extends Error {}

function base64url(value) {
  return Buffer.from(value)
    .toString("base64")
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replaceAll("=", "");
}

function requireString(value, name, maximum = 512) {
  if (typeof value !== "string" || value.length === 0 || value.length > maximum) {
    throw new RelayValidationError("Invalid " + name + ".");
  }
  return value;
}

export function validateDeliveryRequest(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new RelayValidationError("The delivery request must be an object.");
  }
  const platform = requireString(value.platform, "platform", 8);
  if (platform !== "apns" && platform !== "fcm") {
    throw new RelayValidationError("Unsupported notification platform.");
  }
  const category = value.envelope?.category;
  if (!NOTIFICATION_CATEGORIES.has(category)) {
    throw new RelayValidationError("Unsupported notification category.");
  }
  const envelope = value.envelope;
  if (!envelope || envelope.version !== 1) {
    throw new RelayValidationError("Unsupported notification envelope version.");
  }
  for (const field of [
    "envelopeID",
    "desktopInstanceID",
    "deviceID",
    "nonce",
    "ciphertext",
    "authenticationTag"
  ]) {
    requireString(envelope[field], "envelope." + field, field === "ciphertext" ? 100_000 : 4_096);
  }
  if (envelope.sessionID !== null && envelope.sessionID !== undefined) {
    requireString(envelope.sessionID, "envelope.sessionID", 128);
  }
  if (envelope.desktopInstanceID !== value.desktopInstanceID) {
    throw new RelayValidationError("The desktop identity does not match the envelope.");
  }
  if (envelope.deviceID !== value.deviceID) {
    throw new RelayValidationError("The device identity does not match the envelope.");
  }
  return {
    platform,
    deviceToken: requireString(value.deviceToken, "deviceToken", 4_096),
    desktopInstanceID: requireString(value.desktopInstanceID, "desktopInstanceID"),
    deviceID: requireString(value.deviceID, "deviceID"),
    envelope
  };
}

export function notificationContent(category) {
  switch (category) {
    case "agent_needs_input":
      return {
        title: "RepoPrompt needs your input",
        body: "Open RepoPrompt Remote to continue."
      };
    case "approval_required":
      return {
        title: "RepoPrompt needs approval",
        body: "Review the pending approval on your paired Mac."
      };
    case "completed":
      return {
        title: "RepoPrompt run completed",
        body: "A remote run is complete."
      };
    case "failed":
      return {
        title: "RepoPrompt run failed",
        body: "A remote run needs attention."
      };
    default:
      throw new RelayValidationError("Unsupported notification category.");
  }
}

export function apnsPayload(envelope) {
  const content = notificationContent(envelope.category);
  return {
    aps: {
      alert: content,
      category: "REPOPROMPT_" + envelope.category.toUpperCase(),
      sound: "default"
    },
    remoteEnvelope: envelope
  };
}

function apnsProviderToken({ keyID, teamID, privateKey, now = Math.floor(Date.now() / 1_000) }) {
  const header = base64url(JSON.stringify({ alg: "ES256", kid: keyID }));
  const payload = base64url(JSON.stringify({ iss: teamID, iat: now }));
  const signingInput = header + "." + payload;
  const signer = createSign("sha256");
  signer.update(signingInput);
  signer.end();
  const signature = signer.sign({
    key: privateKey.replaceAll("\\n", "\n"),
    dsaEncoding: "ieee-p1363"
  });
  return signingInput + "." + base64url(signature);
}

async function deliverAPNs(request, environment) {
  const keyID = requireString(environment.APNS_KEY_ID, "APNS_KEY_ID", 128);
  const teamID = requireString(environment.APNS_TEAM_ID, "APNS_TEAM_ID", 128);
  const bundleID = requireString(environment.APNS_BUNDLE_ID, "APNS_BUNDLE_ID", 256);
  const privateKey = requireString(environment.APNS_PRIVATE_KEY, "APNS_PRIVATE_KEY", 16_384);
  const { connect } = await import("node:http2");
  const host = environment.APNS_PRODUCTION === "1"
    ? "api.push.apple.com"
    : "api.sandbox.push.apple.com";
  const client = connect("https://" + host);
  const token = apnsProviderToken({ keyID, teamID, privateKey });
  const body = JSON.stringify(apnsPayload(request.envelope));
  return new Promise((resolve, reject) => {
    let status = 0;
    let responseBody = "";
    const timeout = setTimeout(() => {
      client.close();
      reject(new Error("APNs request timed out."));
    }, 10_000);
    const providerRequest = client.request({
      ":method": "POST",
      ":path": "/3/device/" + encodeURIComponent(request.deviceToken),
      "authorization": "bearer " + token,
      "apns-topic": bundleID,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "content-type": "application/json"
    });
    providerRequest.setEncoding("utf8");
    providerRequest.on("response", headers => {
      status = headers[":status"] ?? 0;
    });
    providerRequest.on("data", chunk => {
      responseBody += chunk;
    });
    providerRequest.on("error", error => {
      clearTimeout(timeout);
      client.close();
      reject(error);
    });
    providerRequest.on("end", () => {
      clearTimeout(timeout);
      client.close();
      if (status !== 200) {
        reject(new Error("APNs returned HTTP " + (status || "unknown") + "."));
        return;
      }
      resolve({ provider: "apns", responseBody });
    });
    providerRequest.end(body);
  });
}

function serviceAccount(environment) {
  const raw = requireString(environment.FCM_SERVICE_ACCOUNT_JSON, "FCM_SERVICE_ACCOUNT_JSON", 32_768);
  try {
    const parsed = JSON.parse(raw);
    return {
      clientEmail: requireString(parsed.client_email, "service account client_email", 512),
      privateKey: requireString(parsed.private_key, "service account private_key", 16_384),
      projectID: requireString(
        environment.FCM_PROJECT_ID || parsed.project_id,
        "FCM_PROJECT_ID",
        256
      )
    };
  } catch (error) {
    if (error instanceof RelayValidationError) throw error;
    throw new RelayValidationError("FCM_SERVICE_ACCOUNT_JSON is not valid JSON.");
  }
}

async function fcmAccessToken(account, now = Math.floor(Date.now() / 1_000)) {
  const header = base64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const payload = base64url(JSON.stringify({
    iss: account.clientEmail,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3_600
  }));
  const signingInput = header + "." + payload;
  const signer = createSign("RSA-SHA256");
  signer.update(signingInput);
  signer.end();
  const assertion = signingInput + "." + base64url(
    signer.sign(account.privateKey.replaceAll("\\n", "\n"))
  );
  const response = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion
    })
  });
  if (!response.ok) throw new Error("Google OAuth returned HTTP " + response.status + ".");
  const body = await response.json();
  if (typeof body.access_token !== "string" || body.access_token.length === 0) {
    throw new Error("Google OAuth response did not include an access token.");
  }
  return body.access_token;
}

async function deliverFCM(request, environment) {
  const account = serviceAccount(environment);
  const accessToken = await fcmAccessToken(account);
  const content = notificationContent(request.envelope.category);
  const response = await fetch(
    "https://fcm.googleapis.com/v1/projects/" +
      encodeURIComponent(account.projectID) +
      "/messages:send",
    {
      method: "POST",
      headers: {
        authorization: "Bearer " + accessToken,
        "content-type": "application/json"
      },
      body: JSON.stringify({
        message: {
          token: request.deviceToken,
          notification: content,
          data: {
            category: request.envelope.category,
            sessionID: request.envelope.sessionID ?? "",
            remoteEnvelope: JSON.stringify(request.envelope)
          }
        }
      })
    }
  );
  if (!response.ok) throw new Error("FCM returned HTTP " + response.status + ".");
  return { provider: "fcm" };
}

export async function deliverNotification(request, environment = process.env) {
  if (request.platform === "apns") return deliverAPNs(request, environment);
  if (request.platform === "fcm") return deliverFCM(request, environment);
  throw new RelayValidationError("Unsupported notification platform.");
}

async function readJSON(request) {
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > MAX_BODY_BYTES) throw new RelayValidationError("Request body is too large.");
    chunks.push(chunk);
  }
  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch {
    throw new RelayValidationError("Request body is not valid JSON.");
  }
}

function sendJSON(response, status, value) {
  const body = JSON.stringify(value);
  response.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(body),
    "cache-control": "no-store",
    connection: "close"
  });
  response.end(body);
}

export function createRelayRequestHandler({
  environment = process.env,
  deliver = deliverNotification,
  logger = console
} = {}) {
  return async (request, response) => {
    if (request.method === "GET" && request.url === "/healthz") {
      sendJSON(response, 200, { status: "ok" });
      return;
    }
    if (request.method !== "POST" || request.url !== "/v1/notify") {
      sendJSON(response, 404, { error: "not_found" });
      return;
    }
    try {
      const validated = validateDeliveryRequest(await readJSON(request));
      await deliver(validated, environment);
      logger.info?.(
        "Delivered " +
          validated.platform +
          " " +
          validated.envelope.category +
          " envelope " +
          validated.envelope.envelopeID +
          "."
      );
      sendJSON(response, 202, { accepted: true });
    } catch (error) {
      const isValidationError = error instanceof RelayValidationError;
      if (!isValidationError) {
        logger.error?.("Notification provider delivery failed: " + error.message);
      }
      sendJSON(response, isValidationError ? 400 : 502, {
        error: isValidationError ? "invalid_request" : "provider_unavailable"
      });
    }
  };
}

export function createRelayServer(options = {}) {
  return createServer(createRelayRequestHandler(options));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const port = Number(process.env.PORT || 8787);
  createRelayServer().listen(port, "0.0.0.0", () => {
    console.log("RepoPrompt Remote relay listening on port " + port + ".");
  });
}
