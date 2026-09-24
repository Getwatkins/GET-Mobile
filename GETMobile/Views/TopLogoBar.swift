import SwiftUI

extension View {
    /// Puts the GET Mobile logo in the navigation bar's title position, so it
    /// stays visible at the top of every section (Gauges, Logging, Flash,
    /// the loggers themselves) instead of only appearing on the home screen.
    /// Small and in the nav bar rather than a big banner, since it now needs
    /// to sit above real content on every screen, not just a landing page.
    func withTopLogo() -> some View {
        toolbar {
            ToolbarItem(placement: .principal) {
                Image("LogoBanner")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 26)
            }
        }
    }
}
