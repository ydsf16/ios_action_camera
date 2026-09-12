import SwiftUI

enum AppTheme {
    static let background = Color(red: 0.045, green: 0.065, blue: 0.10)
    static let surface = Color(red: 0.085, green: 0.115, blue: 0.16)
    static let accent = Color(red: 0.31, green: 0.88, blue: 0.79)
    static let blue = Color(red: 0.43, green: 0.70, blue: 1.0)
    static let violet = Color(red: 0.73, green: 0.63, blue: 1.0)
    static let amber = Color(red: 1.0, green: 0.76, blue: 0.37)
    static let success = Color(red: 0.49, green: 0.88, blue: 0.59)
}

struct SettingsLabel: View {
    let title: String
    let symbol: String
    var color: Color = AppTheme.accent

    init(_ title: String, symbol: String, color: Color = AppTheme.accent) {
        self.title = title
        self.symbol = symbol
        self.color = color
    }

    var body: some View {
        Label {
            Text(title).foregroundStyle(.primary)
        } icon: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 30, height: 30)
                .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
                .accessibilityHidden(true)
        }
    }
}

struct PrimaryActionStyle: ButtonStyle {
    var color: Color = AppTheme.accent
    var completed = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isEnabled || completed ? AppTheme.background : Color.white.opacity(0.65))
            .padding(.horizontal, 16)
            .frame(minHeight: 50)
            .background(isEnabled || completed ? color : color.opacity(0.17), in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(color.opacity(isEnabled ? 0 : 0.2), lineWidth: 1)
            }
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

extension View {
    func settingsAppearance() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(AppTheme.background)
            .foregroundStyle(.primary)
            .tint(AppTheme.accent)
    }
}
