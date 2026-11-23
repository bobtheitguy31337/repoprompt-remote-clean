# RepoPrompt Remote Protocol

This Foundation-only package is the single Codable contract shared by RepoPrompt
CE on macOS and RepoPrompt Remote on iOS. It intentionally contains no SwiftUI,
MCP, provider, filesystem, or networking code.

The application protocol and Iroh frames have their own versions, independent
of MCP. The Mac and iOS app build against the same protocol sources and fixtures.

## Version and replay checks

- The client includes its protocol version during pairing.
- Each Iroh frame includes a wire version. Unsupported versions and operations
  receive bounded protocol errors.
- A stale event cursor requires a complete snapshot before event replay resumes.
