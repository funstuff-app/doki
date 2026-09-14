import AppKit
import SwiftUI

/// Brand colors.
private enum Doki {
    static let coral = Color(red: 1.00, green: 0.353, blue: 0.373)      // #FF5A5F
    static let coralSoft = Color(red: 1.00, green: 0.557, blue: 0.569)  // #FF8E91
}

struct DokiMenuView: View {
    @ObservedObject var state: DokiState
    @State private var demoBounce = false
    @State private var ripplePulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            accessibilityRow
            footer
        }
        .padding(14)
        .frame(width: 312)
        .onAppear { state.refreshAccessibility() }
    }

    // MARK: header
    private var header: some View {
        HStack(spacing: 10) {
            AppIconView(bouncing: demoBounce, landed: ripplePulse)
                .frame(width: 38, height: 38)
            Text("Doki").font(.system(size: 14, weight: .bold))
            Spacer()
        }
    }

    // MARK: accessibility (per-icon hover cancel needs it to read Dock tiles)
    private var accessibilityRow: some View {
        HStack {
            Text("accessibility").font(.system(size: 13))
            Spacer()
            if state.accessibilityGranted {
                Text("granted")
                    .font(.system(size: 11.5))
                    .padding(.horizontal, 9).padding(.vertical, 2)
                    .background(Capsule().fill(.green.opacity(0.15)))
                    .foregroundStyle(.green)
            } else {
                Button("grant…") { state.requestAccessibility() }
                    .font(.system(size: 11.5))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: footer
    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                runDemoBounce()
                state.onTestTap()
            } label: {
                Text("test tap").frame(maxWidth: .infinity)
            }
            Button("quit") { NSApp.terminate(nil) }
                .foregroundStyle(.secondary)
        }
        .controlSize(.small)
    }

    /// Blob hops on the real impulse rhythm: 500 / 826 / 1038 ms → deltas 0 / 326 / 212.
    /// Ripples stay anchored; they pulse on each landing (the moment the tap fires).
    private func runDemoBounce() {
        for delay in [0.0, 0.326, 0.538] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                demoBounce = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) {
                    demoBounce = false
                    ripplePulse = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                        ripplePulse = false
                    }
                }
            }
        }
    }
}

/// The app icon, drawn in vectors so the demo can animate it: pink squircle,
/// blob hops inside, ripples stay anchored and pulse on landing. This is the
/// icon's one job — it only ever appears in the Dock when `bouncer` demos.
private struct AppIconView: View {
    var bouncing: Bool
    var landed: Bool

    private enum Palette {
        static let bg = Color(red: 1.00, green: 0.906, blue: 0.894)        // #FFE7E4
        static let ripple1 = Color(red: 1.00, green: 0.557, blue: 0.569)   // #FF8E91
        static let ripple2 = Color(red: 1.00, green: 0.725, blue: 0.733)   // #FFB9BB
    }

    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width
            ZStack {
                RoundedRectangle(cornerRadius: s * 0.22).fill(Palette.bg)

                blob(side: s * 0.46)
                    .rotationEffect(.degrees(8))
                    .position(x: s * 0.5, y: s * 0.40)
                    .offset(y: bouncing ? -s * 0.13 : 0)
                    .animation(.spring(response: 0.13, dampingFraction: 0.55),
                               value: bouncing)

                RippleShape()
                    .stroke(Palette.ripple1,
                            style: StrokeStyle(lineWidth: landed ? 3.2 : 1.8,
                                               lineCap: .round))
                    .frame(width: s * 0.36, height: s * 0.09)
                    .position(x: s * 0.5, y: s * 0.71)

                RippleShape()
                    .stroke(Palette.ripple2,
                            style: StrokeStyle(lineWidth: landed ? 3.0 : 1.8,
                                               lineCap: .round))
                    .frame(width: s * 0.55, height: s * 0.13)
                    .position(x: s * 0.5, y: s * 0.80)
            }
            .animation(.easeOut(duration: 0.12), value: landed)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func blob(side: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: side * 0.24).fill(Doki.coral)
            VStack(spacing: side * 0.08) {
                HStack(spacing: side * 0.26) {
                    Circle().fill(.black.opacity(0.55))
                        .frame(width: side * 0.13, height: side * 0.13)
                    Circle().fill(.black.opacity(0.55))
                        .frame(width: side * 0.13, height: side * 0.13)
                }
                SmileShape()
                    .stroke(.black.opacity(0.55),
                            style: StrokeStyle(lineWidth: side * 0.07, lineCap: .round))
                    .frame(width: side * 0.30, height: side * 0.14)
            }
            .offset(y: -side * 0.02)
        }
        .frame(width: side, height: side * 0.93)
    }
}

private struct SmileShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY),
                       control: CGPoint(x: r.midX, y: r.maxY))
        return p
    }
}

private struct RippleShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY),
                       control: CGPoint(x: r.midX, y: r.maxY))
        return p
    }
}
