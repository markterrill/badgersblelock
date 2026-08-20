import Cocoa

/// The block at the top of the menu: the paw at a size you can actually read,
/// and the app's name. The status bar glyph is 18 points and colour-coded, which
/// is fine for a glance but poor for "wait, is that red or amber?" — this is
/// where you settle that question.
final class MenuHeaderView: NSView {
    private let paw = NSImageView()
    private let title = NSTextField(labelWithString: "Badgers BLE Lock")

    private static let pawSize: CGFloat = 42
    private static let margin: CGFloat = 14
    private static let gap: CGFloat = 12

    init() {
        super.init(frame: .zero)

        paw.imageScaling = .scaleProportionallyUpOrDown
        title.font = .systemFont(ofSize: 19, weight: .semibold)
        // labelColor rather than a fixed black, so the header follows the menu's
        // own appearance in dark mode.
        title.textColor = .labelColor
        addSubview(paw)
        addSubview(title)

        let titleWidth = title.intrinsicContentSize.width
        let height = Self.pawSize + Self.margin * 2
        frame = NSRect(x: 0, y: 0,
                       width: Self.margin * 2 + Self.pawSize + Self.gap + titleWidth,
                       height: height)
        paw.frame = NSRect(x: Self.margin, y: Self.margin,
                           width: Self.pawSize, height: Self.pawSize)
        title.frame = NSRect(x: Self.margin + Self.pawSize + Self.gap,
                             y: (height - title.intrinsicContentSize.height) / 2,
                             width: titleWidth,
                             height: title.intrinsicContentSize.height)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(_ state: PawIcon.State) {
        paw.image = PawIcon.image(for: state, size: Self.pawSize)
    }
}
