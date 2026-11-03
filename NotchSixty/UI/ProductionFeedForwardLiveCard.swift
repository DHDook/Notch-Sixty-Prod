import SwiftUI

/// E4 S25 arming (flag `e4.feedforward-live`): the one control that lets the feed-forward canceller
/// play. Owner approval of 2 Nov 2026: it starts only from this button, only while Quiet Zone is
/// armed, fades in over 3 s after its checks pass, and any trip or change returns it to off. The
/// switch is never remembered between launches.
struct ProductionFeedForwardLiveCard: View {
    @ObservedObject var quietZone: ActiveQuietZoneController
    @ObservedObject var arming: FeedForwardLiveArmingController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Feed-Forward Output")
                        .font(.headline)
                    Text("Plays the upstream-reference anti-noise through the speakers. It starts only when you turn it on, after the seat baseline, timing and safety lease checks pass, and fades in over 3 seconds. Any fault turns it off again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(stateName.uppercased())
                    .font(.caption.bold())
                    .tracking(1)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: .capsule)
            }

            if case .fadingIn = arming.phase {
                ProgressView(value: arming.fadeProgress)
            }
            if case .waiting(let why) = arming.phase {
                Text("Waiting: \(why).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let message = arming.statusMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            HStack {
                if arming.isRequested {
                    Button("Turn Off") { arming.cancel() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Turn On") { _ = quietZone.requestFeedForwardLive() }
                        .disabled(!quietZone.feedForwardLiveFacts().armed)
                }
                if !arming.isRequested, !quietZone.feedForwardLiveFacts().armed {
                    Text("Arm Quiet Zone first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private var stateName: String {
        switch arming.phase {
        case .off: return "Off"
        case .waiting: return "Waiting"
        case .fadingIn: return "Fading in"
        case .live: return "Live"
        }
    }
}
