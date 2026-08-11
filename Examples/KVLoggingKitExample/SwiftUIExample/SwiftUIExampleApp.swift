import ExampleSupport
import KVLoggingSwiftUI
import SwiftUI

@main
struct SwiftUIExampleApp: App {
    private let service = ExampleLoggingService.live()

    var body: some Scene {
        WindowGroup {
            LoggingExampleView(service: service)
                .kvLogging(service.logger)
        }
    }
}
