import AppKit
import SwiftUI

struct AboutView: View {
    @ScaledMetric(relativeTo: .largeTitle) private var iconSize: CGFloat = 80

    var body: some View {
        ZStack {
            VisualEffectView()
                .ignoresSafeArea()

            VStack(spacing: 0) {
                VStack(spacing: 12) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .frame(width: iconSize, height: iconSize)
                        .accessibilityHidden(true)

                    VStack(spacing: 2) {
                        Text("Lumina")
                            .font(.title.bold())
                        Text("Version 1.0")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 28)
                .padding(.bottom, 20)

                Divider()

                VStack(spacing: 2) {
                    Text("Open-source display power control")
                        .font(.headline.weight(.semibold))
                    Text("Built for macOS menu bar workflows")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 12)

                Divider()

                VStack(spacing: 10) {
                    Text("Built to fix monitors that won't sleep.")
                        .font(.headline.weight(.semibold))
                        .italic()

                    Text("Lumina uses BetterDisplay commands to disconnect, power down, reconnect, and wake selected external displays when macOS locks, sleeps, wakes, or unlocks.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 16)
                .padding(.horizontal, 32)

                Divider()

                VStack(spacing: 6) {
                    Text("SYSTEM ARCHITECTURE")
                        .font(.system(.caption2, design: .monospaced).weight(.bold))
                        .foregroundStyle(.secondary)

                    Text("Hooks into native macOS sleep events to dispatch strict, serialized BetterDisplay commands for selected external displays.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 16)
                .padding(.horizontal, 32)
            }
        }
        .frame(width: 360)
    }
}
