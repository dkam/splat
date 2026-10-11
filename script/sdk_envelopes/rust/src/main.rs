// See ../../README.md.
use sentry::protocol::Attachment;

const RECEIPT: [u8; 16] = [
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0xFF, 0x0A, 0x72, 0x65, 0x63, 0x0A, 0x0A,
];

#[derive(Debug, thiserror::Error)]
#[error("card {0} not found")]
struct CardNotFound(String);

#[derive(Debug, thiserror::Error)]
#[error("checkout failed")]
struct CheckoutError {
    #[source]
    source: CardNotFound,
}

fn load_card(card_id: &str) -> Result<(), CardNotFound> {
    Err(CardNotFound(card_id.to_string()))
}

fn charge(card_id: &str) -> Result<(), CheckoutError> {
    load_card(card_id).map_err(|source| CheckoutError { source })
}

fn parse_order(body: &str) -> Result<serde_json::Value, serde_json::Error> {
    serde_json::from_str(body)
}

fn parse_refund(body: &str) -> Result<serde_json::Value, serde_json::Error> {
    serde_json::from_str(body)
}

fn main() {
    let scenario = std::env::var("SCENARIO").expect("SCENARIO");
    let project = match scenario.as_str() {
        "chained" => 1,
        "library_error" => 2,
        "message" => 3,
        "transaction" => 4,
        other => panic!("unknown scenario {other}"),
    };
    let base = std::env::var("SPLAT_DSN_BASE").expect("SPLAT_DSN_BASE");

    let mut options = sentry::ClientOptions::default();
    options.release = Some("fixture@1.0.0".into());
    options.environment = Some("fixture".into());
    options.server_name = Some("fixture-host".into());
    if scenario == "transaction" {
        options = options.traces_sample_rate(1.0);
    }
    // Dropping the guard flushes.
    let _guard = sentry::init((format!("{base}/{project}"), options));

    match scenario.as_str() {
        "chained" => sentry::with_scope(
            |scope| {
                scope.add_attachment(Attachment {
                    buffer: RECEIPT.to_vec(),
                    filename: "receipt.bin".into(),
                    content_type: Some("application/octet-stream".into()),
                    ..Default::default()
                })
            },
            || {
                sentry::add_breadcrumb(sentry::Breadcrumb {
                    category: Some("checkout".into()),
                    message: Some("charging card 4412".into()),
                    ..Default::default()
                });
                if let Err(e) = charge("4412") {
                    sentry::capture_error(&e);
                }
            },
        ),
        "library_error" => {
            for parse in [parse_order, parse_refund] {
                if let Err(e) = parse("{") {
                    sentry::capture_error(&e);
                }
            }
        }
        "message" => {
            sentry::capture_message("Card 4412 declined", sentry::Level::Error);
            sentry::capture_message("Card 9001 declined", sentry::Level::Error);
        }
        _ => {
            let transaction = sentry::start_transaction(sentry::TransactionContext::new("POST /checkout", "http.server"));
            for card in ["4412", "9001"] {
                let span = transaction.start_child("db.sql.query", &format!("SELECT * FROM cards WHERE id = {card}"));
                std::thread::sleep(std::time::Duration::from_millis(10));
                span.finish();
            }
            transaction.finish();
        }
    }
}
