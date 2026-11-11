import Combine
import UIKit

/// A user-configurable on-screen button that sends a keyboard shortcut.
struct ControlButton: Codable, Identifiable, Equatable {
    var id = UUID()
    var label: String
    var shortcut: String
    /// Hold the keys down for as long as the button is pressed (e.g. ctrl for a colour picker,
    /// space to pan) instead of tapping them once.
    var hold: Bool

    static let defaults: [ControlButton] = [
        ControlButton(label: "Undo", shortcut: "ctrl+z", hold: false),
        ControlButton(label: "Redo", shortcut: "ctrl+shift+z", hold: false),
        ControlButton(label: "Eraser", shortcut: "e", hold: false),
        ControlButton(label: "Size −", shortcut: "[", hold: false),
        ControlButton(label: "Size +", shortcut: "]", hold: false),
        ControlButton(label: "Pick", shortcut: "ctrl", hold: true),
        ControlButton(label: "Pan", shortcut: "space", hold: true),
    ]
}

/// Vertical bar of shortcut buttons along one edge of the screen, like Astropad's sidebar.
final class ShortcutBarView: UIView {
    static let width: CGFloat = 76

    var onMenu: (() -> Void)?

    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let client = WeylusClient.shared
    private var cancellables = Set<AnyCancellable>()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.1, alpha: 1)
        isMultipleTouchEnabled = true

        stack.axis = .vertical
        stack.spacing = 8
        scroll.showsVerticalScrollIndicator = false
        scroll.delaysContentTouches = false // buttons react instantly (matters for hold keys)
        addSubview(scroll)
        scroll.addSubview(stack)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -8),
        ])

        Prefs.shared.$controls
            .sink { [weak self] controls in self?.rebuild(controls) }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    private func rebuild(_ controls: [ControlButton]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for c in controls {
            stack.addArrangedSubview(makeButton(c))
        }
        let menu = styledButton(title: "Menu", highlighted: true)
        menu.addAction(UIAction { [weak self] _ in self?.onMenu?() }, for: .touchUpInside)
        stack.addArrangedSubview(menu)
    }

    private func styledButton(title: String, highlighted: Bool = false) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.title = title
        config.baseBackgroundColor = highlighted ? .systemBlue : UIColor(white: 0.22, alpha: 1)
        config.baseForegroundColor = .white
        config.cornerStyle = .medium
        config.titleLineBreakMode = .byTruncatingTail
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 4, bottom: 10, trailing: 4)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var a = attrs
            a.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
            return a
        }
        let b = UIButton(configuration: config)
        b.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        return b
    }

    private func makeButton(_ c: ControlButton) -> UIButton {
        let b = styledButton(title: c.label)
        guard let sc = Shortcut.parse(c.shortcut) else {
            b.isEnabled = false
            return b
        }
        if c.hold {
            // Keys stay pressed while the finger is down, so the Pencil can draw meanwhile.
            b.addAction(UIAction { [weak self] _ in self?.client.keyDown(sc) }, for: .touchDown)
            b.addAction(
                UIAction { [weak self] _ in self?.client.keyUp(sc) },
                for: [.touchUpInside, .touchUpOutside, .touchCancel]
            )
            b.configuration?.subtitle = "hold"
        } else {
            b.addAction(UIAction { [weak self] _ in self?.client.press(sc) }, for: .touchUpInside)
        }
        return b
    }
}
