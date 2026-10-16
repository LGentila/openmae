#if canImport(AppKit)
import AppKit
#endif
import SwiftUI

// Nothing moves in a window that cannot be seen. SwiftUI keeps animating a window that is closed (it keeps its
// views to show it again), in the Dock, hidden or entirely covered; since OpenMaé stays in the menu bar once its
// window is closed, that would cost processor time for nothing. On the iPhone: nothing moves while the app is in
// the background or the screen is locked (a conversation may go on meanwhile).

extension EnvironmentValues {
    /// False while the window cannot be seen at all: closed, in the Dock, hidden or entirely covered.
    @Entry var windowIsVisible = true
}

extension View {
    /// Tells the views inside whether their window can be seen (`windowIsVisible`).
    func followsWindowVisibility() -> some View {
        modifier(WindowVisibility())
    }

    /// Moves `isOn` from false to true and back, forever, with `animation`, while the window can be seen; stops
    /// otherwise, and when `enabled` is false (Reduce Motion, still pictures).
    func repeatsWhileVisible(_ isOn: Binding<Bool>, _ animation: Animation, enabled: Bool = true) -> some View {
        modifier(RepeatsWhileVisible(isOn: isOn, animation: animation, enabled: enabled))
    }
}

#if canImport(AppKit)
private struct WindowVisibility: ViewModifier {
    @State private var isVisible = true

    func body(content: Content) -> some View {
        content
            .environment(\.windowIsVisible, isVisible)
            .background(VisibilityReader { isVisible = $0 })
    }
}
#else
private struct WindowVisibility: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content.environment(\.windowIsVisible, scenePhase == .active)
    }
}
#endif

private struct RepeatsWhileVisible: ViewModifier {
    @Binding var isOn: Bool
    let animation: Animation
    let enabled: Bool
    @Environment(\.windowIsVisible) private var windowIsVisible

    func body(content: Content) -> some View {
        // A repetition only ends with its view: the view is made anew when it has to stop or start.
        content
            .id(enabled && windowIsVisible)
            .onAppear { update() }
            .onChange(of: windowIsVisible) { update() }
    }

    private func update() {
        if enabled, windowIsVisible {
            withAnimation(animation.repeatForever(autoreverses: true)) { isOn = true }
        } else {
            withTransaction(Transaction(animation: nil)) { isOn = false }
        }
    }
}

#if canImport(AppKit)
/// Reports whether its window is visible, each time macOS says it changed.
private struct VisibilityReader: NSViewRepresentable {
    let changed: (Bool) -> Void

    func makeNSView(context: Context) -> NSView { ReaderView(changed: changed) }

    func updateNSView(_ view: NSView, context: Context) {}

    private final class ReaderView: NSView {
        let changed: (Bool) -> Void
        private var reported: Bool?

        init(changed: @escaping (Bool) -> Void) {
            self.changed = changed
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let center = NotificationCenter.default
            center.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
            if let window {
                center.addObserver(self, selector: #selector(occlusionChanged),
                                   name: NSWindow.didChangeOcclusionStateNotification, object: window)
            }
            occlusionChanged()
        }

        @objc private func occlusionChanged() {
            let visible = window?.occlusionState.contains(.visible) ?? false
            guard visible != reported else { return }
            reported = visible
            // Not while SwiftUI is updating the views.
            DispatchQueue.main.async { [changed] in changed(visible) }
        }
    }
}
#endif
