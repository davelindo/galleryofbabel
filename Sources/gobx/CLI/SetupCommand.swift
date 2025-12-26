import Foundation

enum SetupCommand {
    static func run(args: [String]) throws {
        let usage = "Usage: gobx --setup"
        var parser = ArgumentParser(args: args, usage: usage)

        while let a = parser.pop() {
            switch a {
            case "--setup":
                continue
            case "-h", "--help":
                print(usage)
                return
            default:
                throw parser.unknown(a)
            }
        }

        guard Terminal.isInteractiveStdout(), Terminal.isInteractiveStdin() else {
            print("--setup requires an interactive terminal.")
            return
        }

        let backend: Backend = MPSScorer.isMetalAvailable() ? .mps : .cpu
        _ = FirstRunSetup.run(
            trigger: .explicit,
            backend: backend,
            gpuBackend: .metal,
            doSubmit: true,
            mpsMarginSpecified: false,
            emit: { _, message in print(message) }
        )
    }
}
