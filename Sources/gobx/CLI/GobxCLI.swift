import Darwin
import Foundation

enum GobxCLI {
    static func main() async {
        CrashReporter.install()
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            if args.isEmpty || args.contains("-h") || args.contains("--help") || args.first == "help" {
                print(gobxHelpText)
                return
            }

            if (args.first?.hasPrefix("-") ?? false), args.contains("--setup") {
                try SetupCommand.run(args: args)
                return
            }

            let cmd = args[0]
            let rest = Array(args.dropFirst())

            switch cmd {
            case "score":
                try ScoreCommand.run(args: rest)
            case "selftest":
                try SelftestCommand.run(args: rest)
            case "bench-mps":
                try BenchMPS.run(args: rest)
            case "bench-mps-worker":
                try BenchMPS.runWorker(args: rest)
            case "bench-metal":
                try BenchMetal.run(args: rest)
            case "calibrate-mps":
                try CalibrateMPS.run(args: rest)
            case "calibrate-metal":
                try CalibrateMetal.run(args: rest)
            case "proxy-eval":
                try ProxyEvalCommand.run(args: rest)
            case "train-proxy":
                try TrainProxyCommand.run(args: rest)
            case "explore":
                try await ExploreCommand.run(args: rest)
            default:
                throw GobxError.usage("Unknown command: \(cmd)\n\n\(gobxHelpText)")
            }
        } catch {
            FileHandle.standardError.write((String(describing: error) + "\n").data(using: .utf8)!)
            exit(1)
        }
    }
}
