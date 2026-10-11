// See ../README.md.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"time"

	"github.com/getsentry/sentry-go"
)

var projects = map[string]int{"chained": 1, "library_error": 2, "message": 3, "transaction": 4}

var receipt = []byte{0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0xFF, 0x0A, 0x72, 0x65, 0x63, 0x0A, 0x0A}

type CardNotFound struct{ CardID string }

func (e *CardNotFound) Error() string { return fmt.Sprintf("card %s not found", e.CardID) }

type CheckoutError struct{ Err error }

func (e *CheckoutError) Error() string { return "checkout failed" }
func (e *CheckoutError) Unwrap() error { return e.Err }

func loadCard(cardID string) error {
	return &CardNotFound{CardID: cardID}
}

func charge(cardID string) error {
	if err := loadCard(cardID); err != nil {
		return &CheckoutError{Err: err}
	}
	return nil
}

// A Go error carries no stack trace, so the SDK records the stack where it's
// captured: here, in the function that got it.
func parseOrder(body string) {
	var order map[string]any
	if err := json.Unmarshal([]byte(body), &order); err != nil {
		sentry.CaptureException(err)
	}
}

func parseRefund(body string) {
	var refund map[string]any
	if err := json.Unmarshal([]byte(body), &refund); err != nil {
		sentry.CaptureException(err)
	}
}

func main() {
	scenario := os.Getenv("SCENARIO")
	err := sentry.Init(sentry.ClientOptions{
		Dsn:         fmt.Sprintf("%s/%d", os.Getenv("SPLAT_DSN_BASE"), projects[scenario]),
		Release:     "fixture@1.0.0",
		Environment: "fixture",
		ServerName:  "fixture-host",
		// Tracing only for the scenario that needs it.
		EnableTracing:    scenario == "transaction",
		TracesSampleRate: 1.0,
	})
	if err != nil {
		panic(err)
	}
	defer sentry.Flush(5 * time.Second)

	switch scenario {
	case "chained":
		sentry.WithScope(func(scope *sentry.Scope) {
			scope.AddAttachment(&sentry.Attachment{Filename: "receipt.bin", ContentType: "application/octet-stream", Payload: receipt})
			sentry.AddBreadcrumb(&sentry.Breadcrumb{Category: "checkout", Message: "charging card 4412"})
			if err := charge("4412"); err != nil {
				sentry.CaptureException(err)
			}
		})
	case "library_error":
		parseOrder("{")
		parseRefund("{")
	case "message":
		sentry.CaptureMessage("Card 4412 declined")
		sentry.CaptureMessage("Card 9001 declined")
	case "transaction":
		transaction := sentry.StartTransaction(context.Background(), "POST /checkout", sentry.WithOpName("http.server"))
		for _, card := range []string{"4412", "9001"} {
			span := transaction.StartChild("db.sql.query", sentry.WithDescription("SELECT * FROM cards WHERE id = "+card))
			time.Sleep(10 * time.Millisecond)
			span.Finish()
		}
		transaction.Finish()
	}
}
