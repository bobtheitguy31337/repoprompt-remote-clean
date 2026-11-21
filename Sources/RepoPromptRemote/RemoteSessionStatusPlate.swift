import SwiftUI

struct RemoteSessionStatusPlate: View {
    let row: RemoteSessionNavigationRow
    let hasWorktree: Bool

    private var color: Color {
        switch row.status {
        case .opening, .working: return .remoteWarmOrange
        case .waiting: return .green
        case .blocked: return .remoteWarmOrange
        case .completed: return .green
        case .failed: return .red
        case .unreadNarrative: return .remoteWarmOrange
        case .idle, .cancelled: return .secondary
        }
    }

    private var hasUnseenHalo: Bool {
        switch row.status {
        case let .waiting(unseen), let .blocked(unseen), let .completed(unseen), let .failed(unseen):
            return unseen
        case .unreadNarrative:
            return true
        default:
            return false
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(color.opacity(hasUnseenHalo ? 0.17 : 0.08))
            RoundedRectangle(cornerRadius: 8)
                .stroke(color.opacity(hasUnseenHalo ? 0.8 : 0.2), lineWidth: hasUnseenHalo ? 1.5 : 1)

            statusGlyph

            if hasWorktree {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(3)
                    .background(.background, in: Circle())
                    .offset(x: 10, y: 10)
            }
        }
        .frame(width: 28, height: 28)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var statusGlyph: some View {
        ZStack {
            identityGlyph
                .opacity(row.status == .idle ? 1 : 0.5)

            switch row.status {
            case .opening, .working:
                ProgressView()
                    .controlSize(.mini)
                    .tint(color)
            case .waiting:
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(color)
                    .offset(x: 7, y: -7)
            case .blocked:
                Image(systemName: "exclamationmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(color)
                    .offset(x: 7, y: -7)
            case let .completed(unseen):
                if unseen {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(color)
                }
            case let .failed(unseen):
                if unseen {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(color)
                }
            case .cancelled:
                Image(systemName: "minus")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(color)
                    .offset(x: 7, y: -7)
            case .unreadNarrative:
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                    .offset(x: 7, y: -7)
            case .idle:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var identityGlyph: some View {
        if row.depth > 0 {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
        } else {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
        }
    }

    private var accessibilityLabel: String {
        let identity = row.depth == 0 ? "Root chat" : "Child chat, level \(row.depth)"
        let state: String
        switch row.status {
        case .idle: state = "idle"
        case .opening: state = "opening"
        case .working: state = "working"
        case .waiting: state = "waiting for your input"
        case .blocked: state = "blocked"
        case .completed: state = "completed"
        case .failed: state = "failed"
        case .cancelled: state = "cancelled"
        case .unreadNarrative: state = "new activity"
        }
        return "\(identity), \(state)"
    }
}
