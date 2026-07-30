import AppKit
import QuartzCore

/// Фоновая аура состояния для поповера.
///
/// Компонент не перехватывает мышь и сохраняет совместимость со старым API:
///
///     auraView.applyBase(dark: true)
///     auraView.setColor(.systemTeal, animated: true)
///
/// Предпочтительный API:
///
///     auraView.setState(.calm, animated: false)
///     auraView.requestState(.loaded)
///
final class AuraView: NSView {

    // MARK: - State

    enum State: Equatable {
        case calm
        case loaded
        case hot
        case critical
        case inactive
    }

    private struct Palette {
        let color: NSColor
        let intensity: CGFloat
        let transitionDuration: CFTimeInterval
    }

    // MARK: - Layers

    /// Широкое рассеянное свечение.
    private let ambientLayer = CAGradientLayer()

    /// Более яркое ядро у верхней кромки.
    private let bloomLayer = CAGradientLayer()

    /// Вторичный отблеск: даёт ауре глубину, не превращая фон в ровную цветную заливку.
    private let shoulderLayer = CAGradientLayer()

    /// Узкий отражённый свет под стрелкой поповера.
    private let edgeLayer = CAGradientLayer()

    // MARK: - State storage

    private(set) var currentState: State?

    private var pendingState: State?
    private var pendingStateWorkItem: DispatchWorkItem?

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    deinit {
        pendingStateWorkItem?.cancel()
    }

    // MARK: - NSView

    override var isOpaque: Bool { false }

    /// Декоративный фон не должен перекрывать кнопки и скролл.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateContentsScale()
        needsLayout = true
    }

    override func layout() {
        super.layout()

        guard bounds.width > 1, bounds.height > 1 else {
            return
        }

        let ambientHeight = min(bounds.height, max(220, bounds.width * 0.78))

        let bloomHeight = min(bounds.height, max(142, bounds.width * 0.48))
        let shoulderHeight = min(bounds.height, max(126, bounds.width * 0.42))

        let edgeHeight = min(58, bounds.height)

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        ambientLayer.frame = CGRect(
            x: -bounds.width * 0.22,
            y: bounds.maxY - ambientHeight,
            width: bounds.width * 1.30,
            height: ambientHeight
        )

        bloomLayer.frame = CGRect(
            x: bounds.width * 0.22,
            y: bounds.maxY - bloomHeight,
            width: bounds.width * 0.74,
            height: bloomHeight
        )

        shoulderLayer.frame = CGRect(
            x: -bounds.width * 0.12,
            y: bounds.maxY - shoulderHeight,
            width: bounds.width * 0.58,
            height: shoulderHeight
        )

        edgeLayer.frame = CGRect(
            x: bounds.width * 0.20,
            y: bounds.maxY - edgeHeight,
            width: bounds.width * 0.60,
            height: edgeHeight
        )

        CATransaction.commit()
    }

    // MARK: - Setup

    private func setup() {
        wantsLayer = true

        guard let layer else {
            return
        }

        /*
         Аура сама занимает весь контейнер. Обрезаем только её собственные
         градиенты, чтобы отрицательные координаты не давали неожиданных
         артефактов в соседних представлениях.
         */
        layer.masksToBounds = true

        configureAmbientLayer()
        configureBloomLayer()
        configureShoulderLayer()
        configureEdgeLayer()

        layer.addSublayer(ambientLayer)
        layer.addSublayer(shoulderLayer)
        layer.addSublayer(bloomLayer)
        layer.addSublayer(edgeLayer)

        updateContentsScale()
        applyState(.calm, animated: false, force: true)
    }

    private func configureAmbientLayer() {
        ambientLayer.type = .radial
        ambientLayer.startPoint = CGPoint(x: 0.48, y: 1.00)
        ambientLayer.endPoint = CGPoint(x: 1.00, y: 0.02)
        ambientLayer.locations = [0.00, 0.30, 0.68, 1.00]
        disableImplicitAnimations(on: ambientLayer)
    }

    private func configureBloomLayer() {
        bloomLayer.type = .radial
        bloomLayer.startPoint = CGPoint(x: 0.48, y: 1.00)
        bloomLayer.endPoint = CGPoint(x: 0.94, y: 0.08)
        bloomLayer.locations = [0.00, 0.20, 0.58, 1.00]
        disableImplicitAnimations(on: bloomLayer)
    }

    private func configureShoulderLayer() {
        shoulderLayer.type = .radial
        shoulderLayer.startPoint = CGPoint(x: 0.44, y: 1.00)
        shoulderLayer.endPoint = CGPoint(x: 0.98, y: 0.04)
        shoulderLayer.locations = [0.00, 0.28, 0.72, 1.00]
        disableImplicitAnimations(on: shoulderLayer)
    }

    private func configureEdgeLayer() {
        edgeLayer.type = .radial
        edgeLayer.startPoint = CGPoint(x: 0.50, y: 1.00)
        edgeLayer.endPoint = CGPoint(x: 0.98, y: 0.02)
        edgeLayer.locations = [0.00, 0.18, 0.62, 1.00]
        disableImplicitAnimations(on: edgeLayer)
    }

    private func disableImplicitAnimations(on gradient: CAGradientLayer) {
        gradient.actions = [
            "colors": NSNull(),
            "bounds": NSNull(),
            "position": NSNull(),
            "opacity": NSNull()
        ]
    }

    private func updateContentsScale() {
        let scale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2.0

        ambientLayer.contentsScale = scale
        bloomLayer.contentsScale = scale
        shoulderLayer.contentsScale = scale
        edgeLayer.contentsScale = scale
    }

    // MARK: - Background

    /// Плотная подложка прибора, на которой цвет остаётся чистым.
    func applyBase(
        dark: Bool,
        opacity: CGFloat = 0.94,
        animated: Bool = false
    ) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.applyBase(
                    dark: dark,
                    opacity: opacity,
                    animated: animated
                )
            }
            return
        }

        var resolvedOpacity = opacity.clamped(to: 0.18 ... 0.98)

        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            resolvedOpacity = max(resolvedOpacity, 0.97)
        }

        let color: NSColor

        if dark {
            color = NSColor(
                srgbRed: 0.050,
                green: 0.066,
                blue: 0.086,
                alpha: resolvedOpacity
            )
        } else {
            color = NSColor(
                srgbRed: 0.920,
                green: 0.930,
                blue: 0.950,
                alpha: min(0.97, resolvedOpacity * 0.97)
            )
        }

        transitionBackground(
            to: color.cgColor,
            animated: animated
        )
    }

    // MARK: - State API

    /// Применяет состояние немедленно.
    func setState(
        _ state: State,
        animated: Bool = true
    ) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.setState(state, animated: animated)
            }
            return
        }

        cancelPendingStateOnMain()
        applyState(state, animated: animated)
    }

    /// Применяет состояние после короткой стабилизации.
    /// Повторные одинаковые заявки не перезапускают таймер.
    func requestState(
        _ state: State,
        stabilizationDelay: TimeInterval = 0.30,
        animated: Bool = true
    ) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.requestState(
                    state,
                    stabilizationDelay: stabilizationDelay,
                    animated: animated
                )
            }
            return
        }

        if state == currentState {
            cancelPendingStateOnMain()
            return
        }

        if state == pendingState {
            return
        }

        cancelPendingStateOnMain()

        let delay = max(0, stabilizationDelay)

        guard delay > 0 else {
            applyState(state, animated: animated)
            return
        }

        pendingState = state

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }

            self.pendingState = nil
            self.pendingStateWorkItem = nil
            self.applyState(state, animated: animated)
        }

        pendingStateWorkItem = workItem

        DispatchQueue.main.asyncAfter(
            deadline: .now() + delay,
            execute: workItem
        )
    }

    func cancelPendingState() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.cancelPendingState()
            }
            return
        }

        cancelPendingStateOnMain()
    }

    private func cancelPendingStateOnMain() {
        pendingStateWorkItem?.cancel()
        pendingStateWorkItem = nil
        pendingState = nil
    }

    // MARK: - Backward-compatible color API

    /// Старый API сохранён. Интенсивность 1.0 теперь действительно заметна.
    func setColor(
        _ color: NSColor,
        animated: Bool,
        intensity: CGFloat = 1.0,
        duration: CFTimeInterval = 1.35
    ) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.setColor(
                    color,
                    animated: animated,
                    intensity: intensity,
                    duration: duration
                )
            }
            return
        }

        cancelPendingStateOnMain()
        currentState = nil

        applyColor(
            color,
            intensity: intensity,
            animated: animated,
            duration: max(0, duration)
        )
    }

    // MARK: - Applying state

    private func applyState(
        _ state: State,
        animated: Bool,
        force: Bool = false
    ) {
        guard force || state != currentState else {
            return
        }

        currentState = state

        let palette = palette(for: state)

        applyColor(
            palette.color,
            intensity: palette.intensity,
            animated: animated,
            duration: palette.transitionDuration
        )
    }

    private func palette(for state: State) -> Palette {
        switch state {
        case .calm:
            return Palette(
                color: NSColor(
                    srgbRed: 0.12,
                    green: 0.84,
                    blue: 0.80,
                    alpha: 1
                ),
                intensity: 0.62,
                transitionDuration: 1.60
            )

        case .loaded:
            return Palette(
                color: NSColor(
                    srgbRed: 1.00,
                    green: 0.64,
                    blue: 0.14,
                    alpha: 1
                ),
                intensity: 0.82,
                transitionDuration: 1.35
            )

        case .hot:
            return Palette(
                color: NSColor(
                    srgbRed: 1.00,
                    green: 0.29,
                    blue: 0.10,
                    alpha: 1
                ),
                intensity: 1.00,
                transitionDuration: 1.15
            )

        case .critical:
            return Palette(
                color: NSColor(
                    srgbRed: 1.00,
                    green: 0.08,
                    blue: 0.16,
                    alpha: 1
                ),
                intensity: 1.15,
                transitionDuration: 0.90
            )

        case .inactive:
            return Palette(
                color: NSColor(
                    srgbRed: 0.43,
                    green: 0.49,
                    blue: 0.56,
                    alpha: 1
                ),
                intensity: 0.28,
                transitionDuration: 1.20
            )
        }
    }

    // MARK: - Color construction

    private func applyColor(
        _ color: NSColor,
        intensity: CGFloat,
        animated: Bool,
        duration: CFTimeInterval
    ) {
        let resolvedColor = color.usingColorSpace(.sRGB) ?? color
        let resolvedIntensity = intensity.clamped(to: 0 ... 1.20)

        transitionGradient(
            ambientLayer,
            to: ambientColors(
                color: resolvedColor,
                intensity: resolvedIntensity
            ),
            animated: animated,
            duration: duration
        )

        transitionGradient(
            bloomLayer,
            to: bloomColors(
                color: resolvedColor,
                intensity: resolvedIntensity
            ),
            animated: animated,
            duration: duration * 0.88
        )

        transitionGradient(
            shoulderLayer,
            to: shoulderColors(
                color: resolvedColor,
                intensity: resolvedIntensity
            ),
            animated: animated,
            duration: duration * 1.12
        )

        transitionGradient(
            edgeLayer,
            to: edgeColors(
                color: resolvedColor,
                intensity: resolvedIntensity
            ),
            animated: animated,
            duration: duration * 1.06
        )
    }

    private func ambientColors(
        color: NSColor,
        intensity: CGFloat
    ) -> [CGColor] {
        [
            color.withAlphaComponent(alpha(0.20, intensity)).cgColor,
            color.withAlphaComponent(alpha(0.085, intensity)).cgColor,
            color.withAlphaComponent(alpha(0.018, intensity)).cgColor,
            color.withAlphaComponent(0).cgColor
        ]
    }

    private func bloomColors(
        color: NSColor,
        intensity: CGFloat
    ) -> [CGColor] {
        [
            color.withAlphaComponent(alpha(0.34, intensity)).cgColor,
            color.withAlphaComponent(alpha(0.15, intensity)).cgColor,
            color.withAlphaComponent(alpha(0.028, intensity)).cgColor,
            color.withAlphaComponent(0).cgColor
        ]
    }

    private func shoulderColors(
        color: NSColor,
        intensity: CGFloat
    ) -> [CGColor] {
        [
            color.withAlphaComponent(alpha(0.12, intensity)).cgColor,
            color.withAlphaComponent(alpha(0.052, intensity)).cgColor,
            color.withAlphaComponent(alpha(0.012, intensity)).cgColor,
            color.withAlphaComponent(0).cgColor
        ]
    }

    private func edgeColors(
        color: NSColor,
        intensity: CGFloat
    ) -> [CGColor] {
        [
            color.withAlphaComponent(alpha(0.25, intensity)).cgColor,
            color.withAlphaComponent(alpha(0.10, intensity)).cgColor,
            color.withAlphaComponent(alpha(0.018, intensity)).cgColor,
            color.withAlphaComponent(0).cgColor
        ]
    }

    private func alpha(
        _ base: CGFloat,
        _ intensity: CGFloat
    ) -> CGFloat {
        (base * intensity).clamped(to: 0 ... 1)
    }

    // MARK: - Animations

    private func transitionGradient(
        _ gradient: CAGradientLayer,
        to colors: [CGColor],
        animated: Bool,
        duration: CFTimeInterval
    ) {
        let reduceMotion = NSWorkspace.shared
            .accessibilityDisplayShouldReduceMotion

        let visibleColors = gradient.presentation()?.colors ?? gradient.colors

        gradient.removeAnimation(forKey: "AuraView.colors")

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.colors = colors
        CATransaction.commit()

        guard animated,
              !reduceMotion,
              duration > 0,
              let visibleColors
        else {
            return
        }

        let animation = CABasicAnimation(keyPath: "colors")
        animation.fromValue = visibleColors
        animation.toValue = colors
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(
            name: .easeInEaseOut
        )

        gradient.add(animation, forKey: "AuraView.colors")
    }

    private func transitionBackground(
        to color: CGColor,
        animated: Bool
    ) {
        guard let layer else { return }

        let reduceMotion = NSWorkspace.shared
            .accessibilityDisplayShouldReduceMotion

        let visibleColor =
            layer.presentation()?.backgroundColor
            ?? layer.backgroundColor

        layer.removeAnimation(forKey: "AuraView.background")

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.backgroundColor = color
        CATransaction.commit()

        guard animated,
              !reduceMotion,
              let visibleColor
        else {
            return
        }

        let animation = CABasicAnimation(keyPath: "backgroundColor")
        animation.fromValue = visibleColor
        animation.toValue = color
        animation.duration = 0.25
        animation.timingFunction = CAMediaTimingFunction(
            name: .easeInEaseOut
        )

        layer.add(animation, forKey: "AuraView.background")
    }
}

// MARK: - Helpers

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
