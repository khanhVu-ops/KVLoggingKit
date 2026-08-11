import Foundation

enum SampleError: LocalizedError {
    case requestTimedOut

    var errorDescription: String? {
        "The sample request timed out."
    }
}
