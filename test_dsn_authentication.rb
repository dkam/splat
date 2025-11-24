#!/usr/bin/env ruby

# Manual test script for DSN authentication
# Run with: ruby test_dsn_authentication.rb

require 'net/http'
require 'json'
require 'uri'

# Configuration
SPLAT_HOST = 'localhost:3000'
PROJECT_ID = 'test-project'  # Change this to your test project slug
PUBLIC_KEY = 'test-public-key-123'  # Change this to your project's public key

def create_sample_envelope
  event_id = SecureRandom.uuid
  timestamp = Time.now.iso8601

  envelope_headers = {
    "event_id" => event_id,
    "sent_at" => timestamp
  }.to_json

  item_headers = {
    "type" => "event",
    "length" => 100
  }.to_json

  item_payload = {
    "timestamp" => timestamp,
    "message" => "Test DSN authentication",
    "level" => "info",
    "platform" => "ruby"
  }.to_json

  [envelope_headers, item_headers, item_payload].join("\n")
end

def test_authentication(method, headers = {}, params = {})
  uri = URI("http://#{SPLAT_HOST}/api/#{PROJECT_ID}/envelope")
  uri.query = URI.encode_www_form(params) unless params.empty?

  http = Net::HTTP.new(uri.host, uri.port)
  request = Net::HTTP::Post.new(uri)

  headers.each { |key, value| request[key] = value }
  request['Content-Type'] = 'application/octet-stream'
  request.body = create_sample_envelope

  puts "\n=== Testing #{method} ==="
  puts "URL: #{uri}"
  puts "Headers: #{headers}"
  puts "Params: #{params}" unless params.empty?

  begin
    response = http.request(request)
    puts "Status: #{response.code} #{response.message}"
    puts response.body if response.body && !response.body.empty?
  rescue => e
    puts "Error: #{e.message}"
  end
end

puts "DSN Authentication Test Script"
puts "==============================="
puts "Splat Host: #{SPLAT_HOST}"
puts "Project ID: #{PROJECT_ID}"
puts "Public Key: #{PUBLIC_KEY}"

# Test 1: Query parameter authentication
test_authentication(
  "Query Parameter (sentry_key)",
  {},
  { "sentry_key" => PUBLIC_KEY }
)

# Test 2: Query parameter authentication (glitchtip_key)
test_authentication(
  "Query Parameter (glitchtip_key)",
  {},
  { "glitchtip_key" => PUBLIC_KEY }
)

# Test 3: X-Sentry-Auth header
test_authentication(
  "X-Sentry-Auth Header",
  {
    "X-Sentry-Auth" => "Sentry sentry_key=#{PUBLIC_KEY}, sentry_version=7, sentry_client=ruby-sdk/1.0.0"
  }
)

# Test 4: Bearer token
test_authentication(
  "Bearer Token",
  {
    "Authorization" => "Bearer #{PUBLIC_KEY}"
  }
)

# Test 5: Invalid key (should fail)
test_authentication(
  "Invalid Key (should fail)",
  {},
  { "sentry_key" => "invalid-key-123" }
)

# Test 6: No authentication (should fail)
test_authentication(
  "No Authentication (should fail)"
)

puts "\n=== Test Complete ==="