import Foundation

/// Every screen reachable from the home hub after connecting, in one flat
/// stack. Logging is two levels deep (Home -> Logging -> HSL/Standard) but
/// lives in the same path array as everything else, so the back arrow pops
/// one level at a time the same way regardless of how deep you are.
enum HomeRoute: Hashable {
    case gauges
    case logging
    case flash
    case diagnostics
    case hslDatalog
    case standardDatalog
}
