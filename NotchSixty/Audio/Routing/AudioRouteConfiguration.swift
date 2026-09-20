import Foundation

struct AudioRouteConfiguration: Equatable, Sendable {
    var selectedOutputUID: String?

    init(selectedOutputUID: String? = nil) {
        self.selectedOutputUID = selectedOutputUID
    }
}

enum AudioRouteSelectionError: Error, Equatable, Sendable, LocalizedError {
    case outputDeviceUnavailable(uid: String)

    var errorDescription: String? {
        switch self {
        case .outputDeviceUnavailable(let uid):
            return "The selected output device is not currently available: \(uid)"
        }
    }
}
