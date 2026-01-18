using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

var builder = WebApplication.CreateBuilder(args);

// Default data dir (Windows): C:\ProgramData\Thai-Dev\PMIC-Bridge
static string DefaultDataDir()
{
    var programData = Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData);
    if (string.IsNullOrWhiteSpace(programData)) programData = "C:\\ProgramData";
    return Path.Combine(programData, "Thai-Dev", "PMIC-Bridge");
}

var dataDir = Environment.GetEnvironmentVariable("PMIC_BRIDGE_DATA_DIR");
if (string.IsNullOrWhiteSpace(dataDir)) dataDir = DefaultDataDir();
Directory.CreateDirectory(dataDir);

var secretsPath = Path.Combine(dataDir, "secrets.json");
var certPfxPath = Path.Combine(dataDir, "certs", "bridge.pfx");

// Allowed origins
var allowedOriginsEnv = Environment.GetEnvironmentVariable("PMIC_BRIDGE_ALLOWED_ORIGINS");
string[] allowedOrigins;
if (!string.IsNullOrWhiteSpace(allowedOriginsEnv))
{
    allowedOrigins = allowedOriginsEnv.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
}
else
{
    // Safe default: ONLY your production web origin.
    allowedOrigins = ["https://pmic.thai-dev.online"]; 
}

builder.Services.AddCors(options =>
{
    options.AddPolicy("PmicCors", policy =>
    {
        policy.WithOrigins(allowedOrigins)
              .AllowAnyHeader()
              .AllowAnyMethod()
              .AllowCredentials();
    });
});

builder.Services.AddRouting();

var app = builder.Build();

app.UseCors("PmicCors");

// ---- Auth (simple token) ----
// For safety, all /v1/* endpoints require X-Bridge-Token matching secrets.json (except /health).
string EnsureOrLoadToken(string path)
{
    if (File.Exists(path))
    {
        try
        {
            var json = File.ReadAllText(path, Encoding.UTF8);
            var doc = JsonDocument.Parse(json);
            if (doc.RootElement.TryGetProperty("bridgeToken", out var tok))
            {
                var t = tok.GetString();
                if (!string.IsNullOrWhiteSpace(t)) return t;
            }
        }
        catch { /* ignore -> regenerate */ }
    }

    // Generate a strong token and persist.
    var tokenBytes = RandomNumberGenerator.GetBytes(32);
    var token = Convert.ToBase64String(tokenBytes).TrimEnd('=');

    var obj = new
    {
        bridgeToken = token,
        createdAtUtc = DateTime.UtcNow.ToString("O"),
        allowedOrigins = allowedOrigins,
        note = "Keep this token private. Your web UI must send it as X-Bridge-Token."
    };

    var outJson = JsonSerializer.Serialize(obj, new JsonSerializerOptions { WriteIndented = true });
    File.WriteAllText(path, outJson, Encoding.UTF8);

    return token;
}

var bridgeToken = Environment.GetEnvironmentVariable("PMIC_BRIDGE_TOKEN");
if (string.IsNullOrWhiteSpace(bridgeToken))
{
    bridgeToken = EnsureOrLoadToken(secretsPath);
}

bool RequiresAuth(HttpContext ctx)
{
    var p = ctx.Request.Path.Value ?? "";
    if (p.Equals("/health", StringComparison.OrdinalIgnoreCase)) return false;
    if (p.StartsWith("/v1/", StringComparison.OrdinalIgnoreCase)) return true;
    return false;
}

app.Use(async (ctx, next) =>
{
    if (RequiresAuth(ctx))
    {
        if (!ctx.Request.Headers.TryGetValue("X-Bridge-Token", out var tok) || tok.Count == 0)
        {
            ctx.Response.StatusCode = StatusCodes.Status401Unauthorized;
            await ctx.Response.WriteAsJsonAsync(new { error = "missing_token", hint = "Send X-Bridge-Token." });
            return;
        }

        if (!string.Equals(tok.ToString(), bridgeToken, StringComparison.Ordinal))
        {
            ctx.Response.StatusCode = StatusCodes.Status403Forbidden;
            await ctx.Response.WriteAsJsonAsync(new { error = "invalid_token" });
            return;
        }
    }

    await next();
});

// ---- Endpoints ----
app.MapGet("/health", () => Results.Json(new
{
    ok = true,
    service = "pmic-bridge",
    timeUtc = DateTime.UtcNow.ToString("O"),
    allowedOrigins,
    dataDir,
    certPfxPath
}));

app.MapGet("/v1/info", () => Results.Json(new
{
    ok = true,
    name = "Thai-Dev PMIC Bridge",
    version = typeof(Program).Assembly.GetName().Version?.ToString() ?? "0.0.0",
    tokenRequired = true,
    endpoints = new[] { "/v1/info", "/v1/devices", "/v1/connect", "/v1/read", "/v1/write" }
}));

// NOTE: This is a stub device enumeration. Replace with real enumeration (FTDI/RT809F DLL) later.
app.MapGet("/v1/devices", () => Results.Json(new
{
    ok = true,
    devices = new[]
    {
        new {
            name = "RT809F (expected)",
            vid = "0403",
            pid = "6010",
            status = "stub",
            note = "Replace with real USB enumeration in bridge-host."
        }
    }
}));

app.MapPost("/v1/connect", async (HttpContext ctx) =>
{
    // Stub: return a session id.
    var session = Convert.ToBase64String(RandomNumberGenerator.GetBytes(18)).TrimEnd('=');
    await ctx.Response.WriteAsJsonAsync(new { ok = true, sessionId = session, mode = "stub" });
});

app.MapPost("/v1/read", async (HttpContext ctx) =>
{
    // Stub: echo back request.
    var body = await new StreamReader(ctx.Request.Body, Encoding.UTF8).ReadToEndAsync();
    await ctx.Response.WriteAsJsonAsync(new { ok = true, mode = "stub", request = body, data = "AA==" });
});

app.MapPost("/v1/write", async (HttpContext ctx) =>
{
    // Stub: deny by default unless explicitly enabled.
    // Safety: Keep write disabled until HW layer is real.
    ctx.Response.StatusCode = StatusCodes.Status501NotImplemented;
    await ctx.Response.WriteAsJsonAsync(new { ok = false, error = "write_not_implemented", note = "Enable after RT809F DLL integration + safe-step policy." });
});

// ---- Run ----
// Bind to localhost only for safety.
// Set ASPNETCORE_URLS to: https://127.0.0.1:17520
app.Run();
