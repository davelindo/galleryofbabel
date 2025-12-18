import Darwin

enum CrashReporter {
    static func install() {
        _ = installOnce
    }

    private static let installOnce: Void = {
        guard getenv("GOBX_NO_CRASH_REPORTER") == nil else { return }
        let signals: [Int32] = [SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT]
        for sig in signals { _ = Darwin.signal(sig, handler) }
    }()

    private static let handler: @convention(c) (Int32) -> Void = { sig in
        if let name = strsignal(sig) {
            let header = "gobx: fatal signal \(sig) (\(String(cString: name)))\n"
            header.withCString { cstr in
                _ = write(STDERR_FILENO, cstr, strlen(cstr))
            }
        } else {
            let header = "gobx: fatal signal \(sig)\n"
            header.withCString { cstr in
                _ = write(STDERR_FILENO, cstr, strlen(cstr))
            }
        }

        var stack = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
        let n = stack.withUnsafeMutableBufferPointer { buf in
            backtrace(buf.baseAddress, Int32(buf.count))
        }
        stack.withUnsafeBufferPointer { buf in
            backtrace_symbols_fd(buf.baseAddress, n, STDERR_FILENO)
        }

        _exit(128 + sig)
    }
}
