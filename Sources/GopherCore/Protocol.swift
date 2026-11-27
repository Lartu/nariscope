import Darwin
import Foundation
import Network

public enum GopherError: LocalizedError {
    case invalidAddress, invalidSelector, tooLarge, timedOut

    public var errorDescription: String? {
        switch self {
        case .invalidAddress: return "Enter a valid Gopher address."
        case .invalidSelector: return "The selector or search query contains an invalid character."
        case .tooLarge: return "This response exceeds the 16 MB download limit."
        case .timedOut: return "The Gopher server did not respond in time."
        }
    }
}

public struct Address: Hashable, Sendable {
    public let host: String
    public let port: UInt16
    public let type: UInt8
    public let selector: Data
    public let query: Data?

    public init(host: String, port: UInt16 = 70, type: UInt8 = 49, selector: Data = Data(), query: Data? = nil) {
        self.host = host
        self.port = port
        self.type = type
        self.selector = selector
        self.query = query
    }

    public init(_ input: String) throws {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.contains("://") { value = "gopher://" + value }
        guard let parts = URLComponents(string: value),
              parts.scheme?.lowercased() == "gopher", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil,
              let port = UInt16(exactly: parts.port ?? 70), port > 0 else {
            throw GopherError.invalidAddress
        }
        let path = Array(parts.percentEncodedPath.utf8.dropFirst())
        let itemType = path.first ?? 49
        guard itemType >= 33 && itemType <= 126, itemType != 37 else { throw GopherError.invalidAddress }
        var encoded = Data(path.dropFirst())
        // Some conventional Gopher links put a literal '?' in the selector.
        if let suffix = parts.percentEncodedQuery { encoded.append(contentsOf: ("?" + suffix).utf8) }
        let fields = try Self.unescape(encoded).split(separator: 9, omittingEmptySubsequences: false)
        guard fields.count <= 2, fields.count != 2 || itemType == 55 else { throw GopherError.invalidSelector }
        let bareHost = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        self.init(host: bareHost, port: port, type: itemType,
                  selector: fields.first.map { Data($0) } ?? Data(),
                  query: fields.count == 2 ? Data(fields[1]) : nil)
        _ = try request
    }

    public func searching(_ value: String) -> Address {
        Address(host: host, port: port, type: type, selector: selector, query: Data(value.utf8))
    }

    public var string: String {
        let authority = host.contains(":") ? "[\(host)]" : host
        let suffix = query.map { "%09" + Self.escape($0) } ?? ""
        return "gopher://\(authority)\(port == 70 ? "" : ":\(port)")/\(UnicodeScalar(type))\(Self.escape(selector))\(suffix)"
    }

    public var request: Data {
        get throws {
            let forbidden: Set<UInt8> = [0, 9, 10, 13]
            guard !selector.contains(where: forbidden.contains),
                  query?.contains(where: forbidden.contains) != true else { throw GopherError.invalidSelector }
            var bytes = selector
            if let query { bytes.append(9); bytes.append(query) }
            bytes.append(contentsOf: [13, 10])
            return bytes
        }
    }

    private static func escape(_ data: Data) -> String {
        data.map { b in
            let allowed = (48...57).contains(b) || (65...90).contains(b) || (97...122).contains(b)
            return allowed || "-._~/".utf8.contains(b) ? String(UnicodeScalar(b)) : String(format: "%%%02X", b)
        }.joined()
    }

    private static func unescape(_ data: Data) throws -> Data {
        var result = Data()
        var i = data.startIndex
        while i < data.endIndex {
            if data[i] == 37 {
                guard i + 2 < data.endIndex,
                      let byte = UInt8(String(decoding: data[(i + 1)...(i + 2)], as: UTF8.self), radix: 16)
                else { throw GopherError.invalidAddress }
                result.append(byte)
                i += 3
            } else {
                result.append(data[i])
                i += 1
            }
        }
        return result
    }
}

public struct MenuItem {
    public let type: UInt8
    public let label: String
    public let address: Address?
    public let webURL: URL?
}

public enum GopherProtocol {
    public static func decode(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252)
            ?? String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
    }

    public static func lines(_ data: Data) -> [Data] {
        var result: [Data] = []
        for line in data.split(separator: 10, omittingEmptySubsequences: false) {
            let row = Data(line.last == 13 ? line.dropLast() : line[...])
            if row == Data([46]) { break }
            result.append(row.starts(with: [46, 46]) ? Data(row.dropFirst()) : row)
        }
        return result
    }

    public static func text(_ data: Data) -> String {
        var output = Data()
        let rows = lines(data)
        for (index, row) in rows.enumerated() {
            if index > 0 { output.append(10) }
            output.append(row)
        }
        if data.suffix(3) == Data([46, 13, 10]), data.count > 3, data[data.count - 4] == 10 {
            output.append(10)
        }
        return decode(output).replacingOccurrences(of: "\r", with: "\n")
    }

    public static func menu(_ data: Data) -> [MenuItem] {
        lines(data).compactMap { row in
            guard let type = row.first else { return nil }
            let fields = row.dropFirst().split(separator: 9, omittingEmptySubsequences: false)
            let label = fields.first.map { decode(Data($0)) } ?? ""
            var address: Address?
            var webURL: URL?
            if type != 105 && type != 51, fields.count >= 4 {
                let host = decode(Data(fields[2]))
                let selector = Data(fields[1])
                let target = decode(selector)
                if type == 104, target.hasPrefix("URL:"),
                   let url = URL(string: String(target.dropFirst(4))),
                   ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                    webURL = url
                } else if !host.isEmpty, let port = UInt16(decode(Data(fields[3]))), port > 0 {
                    address = Address(host: host, port: port, type: type, selector: selector)
                }
            }
            return MenuItem(type: type, label: label, address: address, webURL: webURL)
        }
    }
}

public enum GopherClient {
    public static func fetch(_ address: Address) async throws -> Data {
        var bytes = Data()
        try await receive(address, idleTimeout: false) { chunk in
            guard bytes.count + chunk.count <= 16_777_216 else { throw GopherError.tooLarge }
            bytes.append(chunk)
        }
        return bytes
    }

    /// Save a binary Gopher response. The destination is replaced only after EOF.
    public static func download(_ address: Address, to destination: URL) async throws -> Int64 {
        guard destination.isFileURL else { throw CocoaError(.fileWriteUnsupportedScheme) }
        try Task.checkCancellation()

        // Stage on the same filesystem so publication is an atomic rename.
        let template = destination.deletingLastPathComponent()
            .appendingPathComponent(".gopher-download.XXXXXX")
        var path = Array(template.path.utf8CString)
        let descriptor = path.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
        guard descriptor >= 0 else { throw fileError(errno) }
        let staged = URL(fileURLWithPath: String(cString: path))
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? FileManager.default.removeItem(at: staged) }

        var count: Int64 = 0
        do {
            try await receive(address, idleTimeout: true) { chunk in
                try handle.write(contentsOf: chunk)
                count += Int64(chunk.count)
            }
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        try Task.checkCancellation()
        let error = staged.withUnsafeFileSystemRepresentation { source in
            destination.withUnsafeFileSystemRepresentation { target -> Int32 in
                guard let source, let target else { return EINVAL }
                return rename(source, target) == 0 ? 0 : errno
            }
        }
        if error != 0 { throw fileError(error) }
        return count
    }

    private static func fileError(_ code: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    private static func receive(_ address: Address, idleTimeout: Bool,
                                chunk: @escaping (Data) throws -> Void) async throws {
        let request = try address.request
        guard let port = NWEndpoint.Port(rawValue: address.port), port.rawValue > 0 else {
            throw GopherError.invalidAddress
        }
        let transfer = Transfer(address: address, port: port, request: request,
                                idleTimeout: idleTimeout, chunk: chunk)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { transfer.start($0) }
        } onCancel: {
            transfer.cancel()
        }
    }
}

private final class Transfer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "gopher.transfer")
    private let connection: NWConnection
    private let request: Data
    private let idleTimeout: Bool
    private let chunk: (Data) throws -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var cancelled = false
    private var timer: DispatchSourceTimer?

    init(address: Address, port: NWEndpoint.Port, request: Data,
         idleTimeout: Bool, chunk: @escaping (Data) throws -> Void) {
        connection = NWConnection(host: NWEndpoint.Host(address.host), port: port, using: .tcp)
        self.request = request
        self.idleTimeout = idleTimeout
        self.chunk = chunk
    }

    func start(_ continuation: CheckedContinuation<Void, Error>) {
        queue.async { [self] in
            self.continuation = continuation
            if self.cancelled { self.finish(.failure(CancellationError())); return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.setEventHandler { [weak self] in self?.finish(.failure(GopherError.timedOut)) }
            timer.schedule(deadline: .now() + 20)
            self.timer = timer
            timer.activate()
            self.connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    self.connection.send(content: self.request, completion: .contentProcessed { error in
                        if let error { self.finish(.failure(error)) } else { self.receive() }
                    })
                case .failed(let error): self.finish(.failure(error))
                default: break
                }
            }
            self.connection.start(queue: self.queue)
        }
    }

    func cancel() {
        queue.async { self.cancelled = true; self.finish(.failure(CancellationError())) }
    }

    private func receive() {
        guard continuation != nil else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
            guard self.continuation != nil else { return }
            do {
                if let error { throw error }
                if let data, !data.isEmpty {
                    try self.chunk(data)
                    if self.idleTimeout { self.timer?.schedule(deadline: .now() + 20) }
                }
                if complete { self.finish(.success(())) }
                else { self.receive() }
            } catch {
                self.finish(.failure(error))
            }
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timer?.cancel()
        timer = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation.resume(with: result)
    }
}
