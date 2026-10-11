// See ../README.md.
using System.Text.Json;
using Microsoft.Extensions.Logging;
using Sentry;

namespace Example;

public class CardNotFound(string message) : Exception(message);

public class CheckoutError(string message, Exception inner) : Exception(message, inner);

public static class Checkout
{
    static readonly Dictionary<string, int> Projects = new() { ["chained"] = 1, ["library_error"] = 2, ["message"] = 3, ["transaction"] = 4 };
    static readonly byte[] Receipt = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0xFF, 0x0A, 0x72, 0x65, 0x63, 0x0A, 0x0A];

    static void LoadCard(string cardId) => throw new CardNotFound($"card {cardId} not found");

    static void Charge(string cardId)
    {
        try
        {
            LoadCard(cardId);
        }
        catch (CardNotFound e)
        {
            throw new CheckoutError("checkout failed", e);
        }
    }

    static JsonElement ParseOrder(string body) => JsonSerializer.Deserialize<JsonElement>(body);

    static JsonElement ParseRefund(string body) => JsonSerializer.Deserialize<JsonElement>(body);

    static void Configure(SentryOptions options, string scenario)
    {
        options.Dsn = $"{Environment.GetEnvironmentVariable("SPLAT_DSN_BASE")}/{Projects[scenario]}";
        options.Release = "fixture@1.0.0";
        options.Environment = "fixture";
        options.ServerName = "fixture-host";
        if (scenario == "transaction")
        {
            options.TracesSampleRate = 1.0;
        }
    }

    public static void Main()
    {
        var scenario = Environment.GetEnvironmentVariable("SCENARIO")!;

        if (scenario == "message")
        {
            // Sentry.Extensions.Logging sends Error records as events, template and
            // parameters; it initialises the SDK itself and flushes on dispose.
            using var factory = LoggerFactory.Create(builder => builder.AddSentry(options => Configure(options, scenario)));
            var log = factory.CreateLogger("Billing");
            log.LogError("Card {Card} declined", "4412");
            log.LogError("Card {Card} declined", "9001");
            return;
        }

        using var sdk = SentrySdk.Init(options => Configure(options, scenario));
        switch (scenario)
        {
            case "chained":
                SentrySdk.AddBreadcrumb("charging card 4412", "checkout");
                try
                {
                    Charge("4412");
                }
                catch (CheckoutError e)
                {
                    SentrySdk.CaptureException(e, scope =>
                        scope.AddAttachment(Receipt, "receipt.bin", AttachmentType.Default, "application/octet-stream"));
                }
                break;
            case "library_error":
                try
                {
                    ParseOrder("{");
                }
                catch (JsonException e)
                {
                    SentrySdk.CaptureException(e);
                }
                try
                {
                    ParseRefund("{");
                }
                catch (JsonException e)
                {
                    SentrySdk.CaptureException(e);
                }
                break;
            case "transaction":
                var transaction = SentrySdk.StartTransaction("POST /checkout", "http.server");
                foreach (var card in new[] { "4412", "9001" })
                {
                    var span = transaction.StartChild("db.sql.query", $"SELECT * FROM cards WHERE id = {card}");
                    Thread.Sleep(10);
                    span.Finish();
                }
                transaction.Finish();
                break;
            default:
                throw new ArgumentException(scenario);
        }
    }
}
