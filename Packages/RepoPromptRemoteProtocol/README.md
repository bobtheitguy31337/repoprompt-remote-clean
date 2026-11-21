# RepoPrompt Remote Protocol

This Foundation-only package is the single Codable contract shared by RepoPrompt
CE on macOS and RepoPrompt Remote on iOS. It intentionally contains no SwiftUI,
MCP, provider, filesystem, or networking code.

The protocol is versioned independently from MCP. `RemoteProtocol.currentVersion`
and `RemoteProtocol.versionedPath` are the compatibility anchors for gateways and
clients. A released package version must continue decoding snapshots and events
from the previous supported protocol version before a breaking version is
introduced.

## Compatibility policy

- A client sends its supported protocol version during pairing.
- The desktop advertises the highest compatible version in the pairing response.
- Minor additions use optional Codable fields and preserve existing enum values.
- A desktop rejects unsupported commands with a bounded protocol error; it never
  silently interprets a newer command as an older one.
- A stale event cursor requires a complete snapshot before event replay resumes.
