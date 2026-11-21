# RepoPrompt Remote notification relay

This small Node 20 service forwards the opaque notification envelope produced by
the desktop gateway to APNs or FCM. It does not decrypt envelopes and does not
receive prompts, paths, commands, transcript text, or secrets in plaintext.

Run locally:

    npm test
    npm start

For an optional local development check, leave `APNS_PRODUCTION` unset so APNs
uses the sandbox, and make `APNS_BUNDLE_ID` match the development-signed iOS
app. Configure CE on the Mac with
`http://127.0.0.1:8787/v1/notify`; the Mac resolves that loopback address and
calls the relay—the iPhone does not. A notification is only an attention/wake
signal: the phone must reconnect to the paired Mac over the trusted LAN for
authoritative state. Exercise this only after Simulator manual pairing and the
physical-device camera, Bonjour, and LAN flow work. It requires a registered
device, development provisioning with `aps-environment=development`, and local
APNs credentials; never commit the key, team, or provisioning values.

Local loopback HTTP is a development-only exception. It does not validate a
deployed relay, production APNs, or FCM, and APNs/physical-device acceptance
remains environment-dependent.

The desktop relay URL should be the deployed service URL ending in
/v1/notify. GET /healthz is a provider-independent health check.

## APNs

Set these environment variables:

- APNS_KEY_ID
- APNS_TEAM_ID
- APNS_BUNDLE_ID (com.repoprompt.remote for the bundled app)
- APNS_PRIVATE_KEY (the .p8 contents; use \n for line breaks)
- APNS_PRODUCTION=1 for production, otherwise the sandbox endpoint is used

The relay constructs a generic alert from the authenticated envelope category
and forwards the complete envelope in the custom remoteEnvelope field.

## FCM

Set FCM_SERVICE_ACCOUNT_JSON to the service-account JSON and optionally set
FCM_PROJECT_ID to override its project_id. The service account is used only to
mint a short-lived OAuth token and send the data message; it is never returned
to the desktop or phone.

Deploy behind HTTPS and a private access control layer. Provider credentials
must be injected by the deployment environment, never committed to this
repository. The relay is not an authority boundary: the phone authenticates the
envelope and reconnects to the paired Mac for authoritative state.
