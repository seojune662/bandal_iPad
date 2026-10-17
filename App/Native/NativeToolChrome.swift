import SwiftUI

/// Desktop CSS control dimensions shared by the native tool surfaces.
struct NativeToolButtonStyle: ButtonStyle {
  var primary = false
  var compact = false
  @Environment(\.isEnabled) private var enabled
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 13, weight: primary ? .medium : .regular))
      .padding(.horizontal, compact ? 8 : 12)
      .frame(minHeight: compact ? 32 : 36)
      .foregroundStyle(primary ? NativeDesktopTheme.onAccent : NativeDesktopTheme.text)
      .background(
        primary
          ? NativeDesktopTheme.accent
          : configuration.isPressed ? NativeDesktopTheme.accentMuted : NativeDesktopTheme.raised
      )
      .clipShape(RoundedRectangle(cornerRadius: 6))
      .overlay(
        RoundedRectangle(cornerRadius: 6).strokeBorder(
          primary ? Color.clear : NativeDesktopTheme.border)
      )
      .opacity(enabled ? 1 : 0.4)
  }
}

struct NativeToolIconStyle: ButtonStyle {
  @Environment(\.isEnabled) private var enabled
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.font(.system(size: 16)).labelStyle(.iconOnly)
      .frame(width: 32, height: 32).contentShape(Rectangle())
      .foregroundStyle(NativeDesktopTheme.secondary)
      .background(
        configuration.isPressed ? NativeDesktopTheme.raised : .clear,
        in: RoundedRectangle(cornerRadius: 8)
      )
      .opacity(enabled ? 1 : 0.4)
  }
}

struct NativeToolCard<Content: View>: View {
  var padding: CGFloat = 16
  @ViewBuilder let content: Content
  var body: some View {
    content.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
      .background(NativeDesktopTheme.surface, in: RoundedRectangle(cornerRadius: 12))
      .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(NativeDesktopTheme.border))
  }
}

struct NativeToolEmptyState: View {
  let title: String
  let message: String
  var symbol: String = "doc"
  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: symbol).font(.system(size: 32, weight: .light)).foregroundStyle(
        NativeDesktopTheme.muted)
      Text(title).font(.system(size: 18, weight: .medium)).foregroundStyle(NativeDesktopTheme.text)
      Text(message).font(.system(size: 13)).foregroundStyle(NativeDesktopTheme.secondary)
        .multilineTextAlignment(.center)
    }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

extension View {
  func nativeToolField() -> some View {
    self.font(.system(size: 13)).padding(.horizontal, 12).padding(.vertical, 8)
      .background(NativeDesktopTheme.bgApp, in: RoundedRectangle(cornerRadius: 6))
      .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(NativeDesktopTheme.border))
  }
}

/// The same two vector silhouettes and pivot coordinates as the desktop mark.
struct NativeBandalMark: View {
  let size: CGFloat
  @Environment(\.accessibilityReduceMotion) private var reducedMotion
  @Environment(\.scenePhase) private var scenePhase
  @State private var progress = 0.0
  var body: some View {
    ZStack {
      ForEach(Array(NativeBandalGeometry.shared.shapes.enumerated()), id: \.offset) {
        index, shape in
        NativeBandalSilhouette(shape: shape, index: index, progress: progress).fill(.foreground)
      }
    }.frame(width: size, height: size).accessibilityHidden(true)
      .task(id: scenePhase == .active && !reducedMotion) {
        progress = 0
        guard scenePhase == .active && !reducedMotion else { return }
        do {
          while !Task.isCancelled {
            withAnimation(.linear(duration: 2)) { progress = 1 }
            try await Task.sleep(for: .seconds(2))
            progress = 0
            try await Task.sleep(for: .seconds(6))
          }
        } catch { progress = 0 }
      }
  }
}

struct NativeBandalGeometry: Decodable {
  struct Silhouette: Decodable {
    let pivot: [Double]
    let points: [[Double]]
  }
  struct Motion: Decodable {
    let scale: Double
    let poses: [[Double]]
  }
  let sourceSize: [Double]
  let shapes: [Silhouette]
  let motion: Motion
  static let shared: NativeBandalGeometry = {
    let url =
      Bundle.main.url(forResource: "moonGeometry", withExtension: "json", subdirectory: "Brand")
      ?? Bundle.main.url(forResource: "moonGeometry", withExtension: "json")
    guard let url, let data = try? Data(contentsOf: url),
      let geometry = try? JSONDecoder().decode(Self.self, from: data)
    else {
      return Self(sourceSize: [452, 448], shapes: [], motion: Motion(scale: 1, poses: [[0, 0]]))
    }
    return geometry
  }()
}

private struct NativeBandalSilhouette: Shape {
  let shape: NativeBandalGeometry.Silhouette
  let index: Int
  var progress: Double
  var animatableData: Double {
    get { progress }
    set { progress = newValue }
  }
  func path(in rect: CGRect) -> Path {
    let geometry = NativeBandalGeometry.shared
    guard shape.pivot.count >= 2, geometry.sourceSize.count >= 2, !geometry.motion.poses.isEmpty
    else { return Path() }
    let t = min(1, max(0, progress))
    let eased = t * t * t * (t * (t * 6 - 15) + 10)
    let position = eased * Double(geometry.motion.poses.count - 1)
    let lower = Int(position)
    let upper = min(lower + 1, geometry.motion.poses.count - 1)
    let a = geometry.motion.poses[lower]
    let b = geometry.motion.poses[upper]
    let angle = (a[index] + (b[index] - a[index]) * (position - Double(lower))) * .pi / 180
    let scale = min(rect.width / geometry.sourceSize[0], rect.height / geometry.sourceSize[1])
    let origin = CGPoint(
      x: rect.midX - geometry.sourceSize[0] * scale / 2,
      y: rect.midY - geometry.sourceSize[1] * scale / 2)
    var path = Path()
    for (offset, point) in shape.points.enumerated() where point.count >= 2 {
      let x = (point[0] - shape.pivot[0]) * geometry.motion.scale
      let y = (point[1] - shape.pivot[1]) * geometry.motion.scale
      let rotated = CGPoint(
        x: origin.x + (shape.pivot[0] + x * cos(angle) - y * sin(angle)) * scale,
        y: origin.y + (shape.pivot[1] + x * sin(angle) + y * cos(angle)) * scale)
      if offset == 0 { path.move(to: rotated) } else { path.addLine(to: rotated) }
    }
    path.closeSubpath()
    return path
  }
}
