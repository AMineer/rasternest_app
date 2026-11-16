using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace RasterNest.Core;

/// <summary>A tool result block.</summary>
public abstract record McpContent
{
    public sealed record TextContent(string Text) : McpContent;
    public sealed record ImageContent(string Base64, string MimeType) : McpContent;

    public static McpContent FromText(string text) => new TextContent(text);
    public static McpContent FromImage(byte[] data, string mimeType = "image/png") => new ImageContent(Convert.ToBase64String(data), mimeType);

    internal JsonObject ToJson() => this switch
    {
        TextContent t => new JsonObject { ["type"] = "text", ["text"] = t.Text },
        ImageContent i => new JsonObject { ["type"] = "image", ["data"] = i.Base64, ["mimeType"] = i.MimeType },
        _ => throw new InvalidOperationException(),
    };
}

public sealed record McpTool(string Name, string Description, JsonNode InputSchema, Func<JsonObject, Task<IReadOnlyList<McpContent>>> Handler);

/// <summary>
/// A minimal Model Context Protocol server (JSON-RPC 2.0, one message per line on stdio) that exposes tools.
/// Transport is left to the caller so the protocol logic is testable.
/// </summary>
public sealed class McpServer(string name, string version, IReadOnlyList<McpTool> tools, string? instructions = null)
{
    public static readonly IReadOnlyList<string> SupportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"];

    private static readonly JsonSerializerOptions Out = new() { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    public IReadOnlyList<McpTool> Tools => tools;

    /// <summary>Handles one incoming line. Returns the response line, or null for notifications.</summary>
    public async Task<string?> HandleAsync(string line)
    {
        if (string.IsNullOrWhiteSpace(line)) return null;
        JsonObject? message;
        try { message = JsonNode.Parse(line) as JsonObject; }
        catch (JsonException) { message = null; }
        if (message == null) return Encode(Error(null, -32700, "Parse error"));

        var hasId = message.TryGetPropertyValue("id", out var id);
        if (message["method"] is not JsonValue mv || !mv.TryGetValue<string>(out var method))
            return hasId ? Encode(Error(id, -32600, "Invalid request")) : null;
        if (!hasId) return null; // notification, e.g. notifications/initialized

        try
        {
            var result = await DispatchAsync(method, message["params"] as JsonObject ?? []);
            return Encode(new JsonObject { ["jsonrpc"] = "2.0", ["id"] = id?.DeepClone(), ["result"] = result });
        }
        catch (RpcException e) { return Encode(Error(id, e.Code, e.Message)); }
        catch (Exception e) { return Encode(Error(id, -32603, e.Message)); }
    }

    private sealed class RpcException(int code, string message) : Exception(message) { public int Code { get; } = code; }

    private static JsonObject Error(JsonNode? id, int code, string message) => new()
    {
        ["jsonrpc"] = "2.0", ["id"] = id?.DeepClone(), ["error"] = new JsonObject { ["code"] = code, ["message"] = message },
    };

    private async Task<JsonNode> DispatchAsync(string method, JsonObject p)
    {
        switch (method)
        {
            case "initialize":
            {
                var requested = p["protocolVersion"]?.GetValue<string>() ?? SupportedVersions[0];
                var v = SupportedVersions.Contains(requested) ? requested : SupportedVersions[0];
                var result = new JsonObject
                {
                    ["protocolVersion"] = v,
                    ["capabilities"] = new JsonObject { ["tools"] = new JsonObject { ["listChanged"] = false } },
                    ["serverInfo"] = new JsonObject { ["name"] = name, ["version"] = version },
                };
                if (instructions != null) result["instructions"] = instructions;
                return result;
            }
            case "ping":
                return new JsonObject();
            case "tools/list":
                return new JsonObject
                {
                    ["tools"] = new JsonArray(tools.Select(t => (JsonNode)new JsonObject
                    {
                        ["name"] = t.Name, ["description"] = t.Description, ["inputSchema"] = t.InputSchema.DeepClone(),
                    }).ToArray()),
                };
            case "tools/call":
            {
                var toolName = p["name"]?.GetValue<string>();
                var tool = tools.FirstOrDefault(t => t.Name == toolName) ?? throw new RpcException(-32602, $"Unknown tool: {toolName ?? ""}");
                try
                {
                    var content = await tool.Handler(p["arguments"] as JsonObject ?? []);
                    return new JsonObject { ["content"] = new JsonArray(content.Select(c => (JsonNode)c.ToJson()).ToArray()), ["isError"] = false };
                }
                catch (Exception e)
                {
                    // Tool failures are results the model can read and react to, not protocol errors.
                    return new JsonObject
                    {
                        ["content"] = new JsonArray(new JsonObject { ["type"] = "text", ["text"] = e.Message }),
                        ["isError"] = true,
                    };
                }
            }
            default:
                throw new RpcException(-32601, $"Method not found: {method}");
        }
    }

    private static string Encode(JsonNode node) => node.ToJsonString(Out);
}

/// <summary>Helpers for reading tool arguments.</summary>
public static class JsonArgs
{
    public static string? Str(this JsonObject o, string key) =>
        o[key] is JsonValue v && v.TryGetValue<string>(out var s) ? s : null;

    public static double? Num(this JsonObject o, string key) => o[key] switch
    {
        JsonValue v when v.TryGetValue<double>(out var d) => d,
        JsonValue v when v.TryGetValue<string>(out var s) && double.TryParse(s, System.Globalization.CultureInfo.InvariantCulture, out var d) => d,
        _ => null,
    };

    public static int? Int(this JsonObject o, string key) => o.Num(key) is { } d ? (int)d : null;

    public static bool? Bool(this JsonObject o, string key) =>
        o[key] is JsonValue v && v.TryGetValue<bool>(out var b) ? b : null;
}
