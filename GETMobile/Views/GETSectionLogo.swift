import SwiftUI

/// Compact section heading used by diagnostic and other standalone screens.
struct GETSectionLogo: View {
    private let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        HStack(spacing: 8) {
            Image("LogoBanner")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 28)

            Text(title.uppercased())
                .font(.system(size: 16, weight: .heavy))
                .foregroundColor(GETTheme.gold)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}
