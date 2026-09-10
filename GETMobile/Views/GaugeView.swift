import SwiftUI

/// Direct visual port of GaugeControl.xaml/.xaml.cs: a 240-degree arc dial
/// (-120..+120 degrees, 0 = straight up, clockwise-increasing - identical
/// convention to the WPF control's PointOnCircle/RotateTransform) with a
/// needle, plus a "digital" mode that hides the dial and just shows a big
/// numeric readout. Same white value color / red warning color as the
/// Windows app (GaugeControl.xaml.cs's inWarnZone branch).
struct GaugeView: View {
    let value: Double
    let minimum: Double
    let maximum: Double
    let label: String
    let unit: String
    let warnMin: Double?
    let warnMax: Double?
    let isDigitalStyle: Bool

    private let angleMin = -120.0
    private let angleMax = 120.0

    private var clampedFraction: Double {
        let max = self.maximum > self.minimum ? self.maximum : self.minimum + 1
        let v = value.isNaN ? minimum : Swift.min(max, Swift.max(minimum, value))
        return (v - minimum) / (max - minimum)
    }

    private var needleAngle: Double { angleMin + clampedFraction * (angleMax - angleMin) }

    private var inWarnZone: Bool {
        if let warnMin, !value.isNaN, value <= warnMin { return true }
        if let warnMax, !value.isNaN, value >= warnMax { return true }
        return false
    }

    private var valueColor: Color { inWarnZone ? GETTheme.warningRed : GETTheme.valueWhite }

    private func point(on radius: CGFloat, at angleDegrees: Double, center: CGPoint) -> CGPoint {
        let rad = angleDegrees * .pi / 180
        return CGPoint(x: center.x + radius * CGFloat(sin(rad)), y: center.y - radius * CGFloat(cos(rad)))
    }

    private func arcPath(from startAngle: Double, to endAngle: Double, radius: CGFloat, center: CGPoint) -> Path {
        var path = Path()
        guard abs(endAngle - startAngle) > 0.01 else { return path }
        let steps = max(2, Int(abs(endAngle - startAngle) / 2))
        path.move(to: point(on: radius, at: startAngle, center: center))
        for i in 1...steps {
            let a = startAngle + (endAngle - startAngle) * Double(i) / Double(steps)
            path.addLine(to: point(on: radius, at: a, center: center))
        }
        return path
    }

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: size / 2)
            let radius = size * 0.42

            ZStack {
                if isDigitalStyle {
                    // Digital mode intentionally has no inner gray display box.
                    // The gauge card provides the visual boundary; the value is
                    // rendered directly on the dark background for a cleaner look.
                    EmptyView()
                } else {
                    Circle()
                        .fill(GETTheme.panelBackground)
                        .frame(width: radius * 2.15, height: radius * 2.15)
                        .position(center)

                    arcPath(from: angleMin, to: angleMax, radius: radius, center: center)
                        .stroke(Color(white: 0.25), style: StrokeStyle(lineWidth: 10, lineCap: .round))

                    arcPath(from: angleMin, to: needleAngle, radius: radius, center: center)
                        .stroke(valueColor, style: StrokeStyle(lineWidth: 10, lineCap: .round))

                    Path { p in
                        p.move(to: center)
                        p.addLine(to: point(on: radius - 6, at: needleAngle, center: center))
                    }
                    .stroke(valueColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))

                    Circle()
                        .fill(Color(white: 0.1))
                        .overlay(Circle().stroke(Color(white: 0.4), lineWidth: 1))
                        .frame(width: 14, height: 14)
                        .position(center)
                }

                VStack(spacing: 2) {
                    Text(value.isNaN ? "--" : formattedValue)
                        .font(GETTheme.monoFont(isDigitalStyle ? size * 0.22 : size * 0.16))
                        .foregroundColor(valueColor)
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                    if !unit.isEmpty {
                        Text(unit)
                            .font(GETTheme.monoFont(size * 0.08, weight: .regular))
                            .foregroundColor(.gray)
                    }
                }
                .position(x: center.x, y: isDigitalStyle ? center.y * 0.75 : center.y + radius * 0.55)

                Text(label)
                    .font(GETTheme.monoFont(size * 0.09, weight: .semibold))
                    .foregroundColor(GETTheme.gold)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .position(x: center.x, y: size * 0.08)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipped()
    }

    private var formattedValue: String {
        if value == value.rounded() && abs(value) < 1e6 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.2f", value)
    }
}

#Preview {
    GaugeView(value: 142.3, minimum: 0, maximum: 300, label: "PUT", unit: "kpa",
               warnMin: -1000, warnMax: 300, isDigitalStyle: false)
        .frame(width: 160, height: 160)
        .background(Color.black)
}
