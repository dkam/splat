// See ../README.md.
const Sentry = require("@sentry/node");

const PROJECTS = { chained: 1, library_error: 2, message: 3 };
const RECEIPT = Uint8Array.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0xff, 0x0a, 0x72, 0x65, 0x63, 0x0a, 0x0a]);

class CardNotFound extends Error {
  constructor(message, options) {
    super(message, options);
    this.name = "CardNotFound";
  }
}

class CheckoutError extends Error {
  constructor(message, options) {
    super(message, options);
    this.name = "CheckoutError";
  }
}

function loadCard(cardId) {
  throw new CardNotFound(`card ${cardId} not found`);
}

function charge(cardId) {
  try {
    loadCard(cardId);
  } catch (e) {
    throw new CheckoutError("checkout failed", { cause: e });
  }
}

function parseOrder(body) {
  return JSON.parse(body);
}

function parseRefund(body) {
  return JSON.parse(body);
}

async function main() {
  const scenario = process.env.SCENARIO;
  Sentry.init({
    dsn: `${process.env.SPLAT_DSN_BASE}/${PROJECTS[scenario]}`,
    release: "fixture@1.0.0",
    environment: "fixture",
    serverName: "fixture-host",
  });

  if (scenario === "chained") {
    Sentry.withScope((scope) => {
      scope.addAttachment({ filename: "receipt.bin", data: RECEIPT, contentType: "application/octet-stream" });
      Sentry.addBreadcrumb({ category: "checkout", message: "charging card 4412" });
      try {
        charge("4412");
      } catch (e) {
        Sentry.captureException(e);
      }
    });
  } else if (scenario === "library_error") {
    for (const parse of [parseOrder, parseRefund]) {
      try {
        parse("{");
      } catch (e) {
        Sentry.captureException(e);
      }
    }
  } else if (scenario === "message") {
    // parameterize sends the template and its values as the event's logentry.
    for (const card of ["4412", "9001"]) {
      Sentry.captureMessage(Sentry.parameterize`Card ${card} declined`);
    }
  }

  await Sentry.close(5000);
}

main();
