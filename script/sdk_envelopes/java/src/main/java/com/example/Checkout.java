package com.example;

// See ../../../../../README.md.
import io.sentry.Attachment;
import io.sentry.ISpan;
import io.sentry.ITransaction;
import io.sentry.Sentry;
import io.sentry.SentryOptions;
import io.sentry.jul.SentryHandler;
import java.util.Map;
import java.util.logging.Level;
import java.util.logging.Logger;

public class Checkout {
  static final Map<String, Integer> PROJECTS = Map.of("chained", 1, "library_error", 2, "message", 3, "transaction", 4);
  static final byte[] RECEIPT = {
    (byte) 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, (byte) 0xFF, 0x0A, 0x72, 0x65, 0x63, 0x0A, 0x0A
  };

  static void loadCard(String cardId) {
    throw new CardNotFound("card " + cardId + " not found");
  }

  static void charge(String cardId) {
    try {
      loadCard(cardId);
    } catch (CardNotFound e) {
      throw new CheckoutError("checkout failed", e);
    }
  }

  // The JDK has no JSON parser; Integer.parseInt is the nearest standard one.
  static int parseOrder(String body) {
    return Integer.parseInt(body);
  }

  static int parseRefund(String body) {
    return Integer.parseInt(body);
  }

  static void configure(SentryOptions options, String scenario) {
    options.setDsn(System.getenv("SPLAT_DSN_BASE") + "/" + PROJECTS.get(scenario));
    options.setRelease("fixture@1.0.0");
    options.setEnvironment("fixture");
    options.setServerName("fixture-host");
    if (scenario.equals("transaction")) {
      options.setTracesSampleRate(1.0);
    }
  }

  public static void main(String[] args) throws InterruptedException {
    String scenario = System.getenv("SCENARIO");
    // sentry-jul initialises the SDK itself, from the options it's given.
    if (!scenario.equals("message")) {
      Sentry.init(options -> configure(options, scenario));
    }

    switch (scenario) {
      case "chained" -> {
        Sentry.addBreadcrumb("charging card 4412", "checkout");
        try {
          charge("4412");
        } catch (CheckoutError e) {
          Sentry.captureException(e, scope ->
            scope.addAttachment(new Attachment(RECEIPT, "receipt.bin", "application/octet-stream")));
        }
      }
      case "library_error" -> {
        try {
          parseOrder("{");
        } catch (NumberFormatException e) {
          Sentry.captureException(e);
        }
        try {
          parseRefund("{");
        } catch (NumberFormatException e) {
          Sentry.captureException(e);
        }
      }
      case "message" -> {
        // sentry-jul sends SEVERE records as events, template and parameters.
        SentryOptions options = new SentryOptions();
        configure(options, scenario);
        Logger log = Logger.getLogger("billing");
        log.addHandler(new SentryHandler(options));
        log.log(Level.SEVERE, "Card {0} declined", "4412");
        log.log(Level.SEVERE, "Card {0} declined", "9001");
      }
      case "transaction" -> {
        ITransaction transaction = Sentry.startTransaction("POST /checkout", "http.server");
        for (String card : new String[] {"4412", "9001"}) {
          ISpan span = transaction.startChild("db.sql.query", "SELECT * FROM cards WHERE id = " + card);
          Thread.sleep(10);
          span.finish();
        }
        transaction.finish();
      }
      default -> throw new IllegalArgumentException(scenario);
    }

    Sentry.flush(5000);
    Sentry.close();
  }
}
