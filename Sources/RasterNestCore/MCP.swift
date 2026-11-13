import Foundation

/// Any JSON value. Used for MCP messages and tool arguments.
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            if n.rounded() == n, abs(n) < 1e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var double: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s)
        default: return nil
        }
    }
    public var int: Int? { double.map { Int($0) } }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var array: [JSONValue]? { if case .array(let a) = self { return a }; return nil }

    /// Re-decodes this value as a Codable type (e.g. an `AnnotationSpec.Item`).
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(self))
    }

    public static func from<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
                     ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(stringLiteral v: String) { self = .string(v) }
    public init(booleanLiteral v: Bool) { self = .bool(v) }
    public init(integerLiteral v: Int) { self = .number(Double(v)) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { $1 }))
    }
}

/// A tool result block.
public enum MCPContent: Sendable, Equatable {
    case text(String)
    case image(base64: String, mimeType: String)

    var json: JSONValue {
        switch self {
        case .text(let t): return ["type": "text", "text": .string(t)]
        case .image(let b, let m): return ["type": "image", "data": .string(b), "mimeType": .string(m)]
        }
    }
}

public struct MCPTool: Sendable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue
    public var handler: @Sendable (JSONValue) async throws -> [MCPContent]

    public init(name: String, description: String, inputSchema: JSONValue,
                handler: @escaping @Sendable (JSONValue) async throws -> [MCPContent]) {
        self.name = name; self.description = description; self.inputSchema = inputSchema; self.handler = handler
    }
}

/// A minimal Model Context Protocol server (JSON-RPC 2.0, one message per line on stdio)
/// that exposes tools. Transport is left to the caller so the protocol logic is testable.
public struct MCPServer: Sendable {
    public static let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    public var name: String
    public var version: String
    public var instructions: String?
    public var tools: [MCPTool]

    public init(name: String, version: String, instructions: String? = nil, tools: [MCPTool]) {
        self.name = name; self.version = version; self.instructions = instructions; self.tools = tools
    }

    /// Handles one incoming line. Returns the response line, or nil for notifications.
    public func handle(line: String) async -> String? {
        guard let data = line.data(using: .utf8), !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: data), case .object = message else {
            return Self.encode(["jsonrpc": "2.0", "id": .null, "error": ["code": -32700, "message": "Parse error"]])
        }
        let id = message["id"]
        guard let method = message["method"]?.string else {
            // A response to something we never send, or junk: ignore unless it has an id.
            return id.map { Self.encode(["jsonrpc": "2.0", "id": $0, "error": ["code": -32600, "message": "Invalid request"]]) }
        }
        guard let id else { return nil } // notification (e.g. notifications/initialized)
        do {
            let result = try await dispatch(method, params: message["params"] ?? .object([:]))
            return Self.encode(["jsonrpc": "2.0", "id": id, "result": result])
        } catch let e as RPCError {
            return Self.encode(["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(e.code)), "message": .string(e.message)]])
        } catch {
            return Self.encode(["jsonrpc": "2.0", "id": id, "error": ["code": -32603, "message": .string(error.localizedDescription)]])
        }
    }

    struct RPCError: Error { var code: Int; var message: String }

    func dispatch(_ method: String, params: JSONValue) async throws -> JSONValue {
        switch method {
        case "initialize":
            let requested = params["protocolVersion"]?.string ?? Self.supportedVersions[0]
            let version = Self.supportedVersions.contains(requested) ? requested : Self.supportedVersions[0]
            var result: [String: JSONValue] = [
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": .string(name), "version": .string(self.version)],
            ]
            if let instructions { result["instructions"] = .string(instructions) }
            return .object(result)
        case "ping":
            return .object([:])
        case "tools/list":
            return ["tools": .array(tools.map {
                ["name": .string($0.name), "description": .string($0.description), "inputSchema": $0.inputSchema]
            })]
        case "tools/call":
            guard let name = params["name"]?.string, let tool = tools.first(where: { $0.name == name }) else {
                throw RPCError(code: -32602, message: "Unknown tool: \(params["name"]?.string ?? "")")
            }
            do {
                let content = try await tool.handler(params["arguments"] ?? .object([:]))
                return ["content": .array(content.map(\.json)), "isError": false]
            } catch {
                // Tool failures are results the model can read and react to, not protocol errors.
                let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                return ["content": [["type": "text", "text": .string(message)]], "isError": true]
            }
        default:
            throw RPCError(code: -32601, message: "Method not found: \(method)")
        }
    }

    static func encode(_ value: JSONValue) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? String(decoding: enc.encode(value), as: UTF8.self)) ?? "{}"
    }
}
