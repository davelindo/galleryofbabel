import Foundation

struct ArgumentParser {
    private let args: [String]
    private var index: Int = 0
    private let usage: String

    init(args: [String], usage: String) {
        self.args = args
        self.usage = usage
    }

    var isAtEnd: Bool { index >= args.count }

    mutating func peek() -> String? {
        guard index < args.count else { return nil }
        return args[index]
    }

    mutating func pop() -> String? {
        guard index < args.count else { return nil }
        let v = args[index]
        index += 1
        return v
    }

    mutating func requirePositional(_ name: String) throws -> String {
        guard let v = pop() else {
            throw GobxError.usage("Missing \(name)\n\n\(usage)")
        }
        return v
    }

    mutating func requireValue(for option: String) throws -> String {
        guard let v = pop() else {
            throw GobxError.usage("Missing value for \(option)\n\n\(usage)")
        }
        return v
    }

    mutating func requireInt(for option: String) throws -> Int {
        let s = try requireValue(for: option)
        guard let v = Int(s) else {
            throw GobxError.usage("Invalid integer for \(option): \(s)\n\n\(usage)")
        }
        return v
    }

    mutating func requireDouble(for option: String) throws -> Double {
        let s = try requireValue(for: option)
        guard let v = Double(s) else {
            throw GobxError.usage("Invalid number for \(option): \(s)\n\n\(usage)")
        }
        return v
    }

    mutating func requireEnum<E: RawRepresentable>(for option: String, _ type: E.Type) throws -> E where E.RawValue == String {
        let s = try requireValue(for: option)
        guard let v = E(rawValue: s) else {
            throw GobxError.usage("Invalid value for \(option): \(s)\n\n\(usage)")
        }
        return v
    }

    func unknown(_ arg: String) -> GobxError {
        GobxError.usage("Unknown option: \(arg)\n\n\(usage)")
    }
}

