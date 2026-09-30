import SwiftUI

extension View {
    @ViewBuilder
    func stylePortGlassCard(padding: CGFloat = 20) -> some View {
        if #available(iOS 26.0, *) {
            self
                .padding(padding)
                .glassEffect(.regular, in: .rect(cornerRadius: 28))
        } else {
            self
                .padding(padding)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(.white.opacity(0.15))
                }
        }
    }

    @ViewBuilder
    func stylePortPrimaryButton() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }
}

