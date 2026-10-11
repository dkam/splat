# frozen_string_literal: true

# See ../../README.md. Under lib/ so sentry-ruby counts it as your code.
require "json"
require "sentry-ruby"

PROJECTS = {"chained" => 1, "library_error" => 2, "message" => 3}.freeze
RECEIPT = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0xFF, 0x0A, 0x72, 0x65, 0x63, 0x0A, 0x0A].pack("C*")

class CardNotFound < StandardError; end

class CheckoutError < StandardError; end

def load_card(card_id)
  raise CardNotFound, "card #{card_id} not found"
end

def charge(card_id)
  load_card(card_id)
rescue CardNotFound
  raise CheckoutError, "checkout failed"
end

def parse_order(body) = JSON.parse(body)

def parse_refund(body) = JSON.parse(body)

scenario = ENV.fetch("SCENARIO")
Sentry.init do |config|
  config.dsn = "#{ENV.fetch("SPLAT_DSN_BASE")}/#{PROJECTS.fetch(scenario)}"
  config.release = "fixture@1.0.0"
  config.environment = "fixture"
  config.server_name = "fixture-host"
  config.background_worker_threads = 0 # send before returning
end

case scenario
when "chained"
  Sentry.with_scope do |scope|
    scope.add_attachment(filename: "receipt.bin", bytes: RECEIPT, content_type: "application/octet-stream")
    Sentry.add_breadcrumb(Sentry::Breadcrumb.new(category: "checkout", message: "charging card 4412"))
    begin
      charge("4412")
    rescue => e
      Sentry.capture_exception(e)
    end
  end
when "library_error"
  [:parse_order, :parse_refund].each do |name|
    send(name, "{")
  rescue => e
    Sentry.capture_exception(e)
  end
when "message"
  Sentry.capture_message("Card 4412 declined")
  Sentry.capture_message("Card 9001 declined")
end
