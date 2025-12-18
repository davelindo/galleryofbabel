import Foundation

enum ExploreCommand {
    static func run(args: [String]) async throws {
        let options = try ExploreOptions.parse(args: args)
        try await ExploreRunner.run(options: options)
    }
}
