import assert from "node:assert/strict";
import { Readable } from "node:stream";
import test from "node:test";
import {
  MAX_BODY_BYTES,
  apnsPayload,
  createRelayRequestHandler,
  notificationContent,
  validateDeliveryRequest
} from "./server.mjs";

function requestBody(overrides = {}) {
  return {
    platform: "apns",
    deviceToken: "a".repeat(64),
    desktopInstanceID: "desktop-1",
    deviceID: "device-1",
    envelope: {
      version: 1,
      envelopeID: "00000000-0000-0000-0000-000000000001",
      desktopInstanceID: "desktop-1",
      deviceID: "device-1",
      category: "agent_needs_input",
      sessionID: "00000000-0000-0000-0000-000000000002",
      createdAt: "2026-07-21T00:00:00Z",
      nonce: "nonce",
      ciphertext: "ciphertext",
      authenticationTag: "tag"
    },
    ...overrides
  };
}

async function invoke(handler, { method, url, body = "" }) {
  const request = Readable.from([Buffer.from(body)]);
  request.method = method;
  request.url = url;
  let status;
  let headers;
  let responseBody = "";
  const response = {
    writeHead(nextStatus, nextHeaders) {
      status = nextStatus;
      headers = nextHeaders;
    },
    end(value = "") {
      responseBody = value;
    }
  };
  await handler(request, response);
  return { status, headers, body: JSON.parse(responseBody) };
}

test("validates opaque delivery requests without inspecting plaintext", () => {
  const validated = validateDeliveryRequest(requestBody());
  assert.equal(validated.envelope.ciphertext, "ciphertext");
  assert.throws(
    () => validateDeliveryRequest(requestBody({
      envelope: { ...requestBody().envelope, version: 2 }
    })),
    /version/
  );
  assert.throws(
    () => validateDeliveryRequest(requestBody({ platform: "smtp" })),
    /platform/
  );
  assert.throws(
    () => validateDeliveryRequest(requestBody({
      deviceID: "other-device"
    })),
    /device identity/
  );
});

test("builds generic provider content and forwards the encrypted envelope", () => {
  assert.deepEqual(notificationContent("completed"), {
    title: "RepoPrompt run completed",
    body: "A remote run is complete."
  });
  const payload = apnsPayload(requestBody().envelope);
  assert.equal(payload.aps.alert.title, "RepoPrompt needs your input");
  assert.deepEqual(payload.remoteEnvelope, requestBody().envelope);
});

test("relay health and notification endpoint return bounded responses", async () => {
  const calls = [];
  const handler = createRelayRequestHandler({
    deliver: async value => {
      calls.push(value);
    },
    logger: { info() {}, error() {} }
  });
  const health = await invoke(handler, { method: "GET", url: "/healthz" });
  assert.equal(health.status, 200);
  assert.deepEqual(health.body, { status: "ok" });

  const response = await invoke(handler, {
    method: "POST",
    url: "/v1/notify",
    body: JSON.stringify(requestBody())
  });
  assert.equal(response.status, 202);
  assert.deepEqual(response.body, { accepted: true });
  assert.equal(calls.length, 1);

  const oversized = await invoke(handler, {
    method: "POST",
    url: "/v1/notify",
    body: JSON.stringify({
      ...requestBody(),
      deviceToken: "x".repeat(MAX_BODY_BYTES)
    })
  });
  assert.equal(oversized.status, 400);
});
