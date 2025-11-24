#!/usr/bin/env ruby

# Quick test script to verify the span analyzer works
require_relative 'config/environment'

puts "🧪 Testing SpanAnalyzer with sample data..."

# Test with some sample spans
sample_spans = [
  {
    "op" => "db.sql.active_record",
    "start_timestamp" => 1760938590.477074,
    "timestamp" => 1760938590.478464,
    "description" => "SELECT \"users\".* FROM \"users\" WHERE \"users\".\"id\" = 1 LIMIT 1"
  },
  {
    "op" => "db.sql.active_record",
    "start_timestamp" => 1760938590.480000,
    "timestamp" => 1760938590.482000,
    "description" => "SELECT \"users\".* FROM \"users\" WHERE \"users\".\"id\" = 2 LIMIT 1"
  },
  {
    "op" => "view.process_action.action_controller",
    "start_timestamp" => 1760938590.490000,
    "timestamp" => 1760938591.500000,
    "description" => "UsersController#index"
  }
]

# Test span timing extraction
span_timing = Transaction::SpanAnalyzer.extract_timing_data(sample_spans)
puts "\n⏱️  Span Timing Analysis:"
puts "  DB Time: #{span_timing[:db_time]}ms"
puts "  View Time: #{span_timing[:view_time]}ms"

# Test with sample breadcrumbs (simulating N+1 queries)
sample_breadcrumbs = [
  {
    "category" => "sql.active_record",
    "data" => { "sql" => "SELECT \"users\".* FROM \"users\" WHERE \"users\".\"id\" = 1 LIMIT 1" }
  },
  {
    "category" => "sql.active_record",
    "data" => { "sql" => "SELECT \"users\".* FROM \"users\" WHERE \"users\".\"id\" = 2 LIMIT 1" }
  },
  {
    "category" => "sql.active_record",
    "data" => { "sql" => "SELECT \"users\".* FROM \"users\" WHERE \"users\".\"id\" = 3 LIMIT 1" }
  },
  {
    "category" => "sql.active_record",
    "data" => { "sql" => "SELECT \"users\".* FROM \"users\" WHERE \"users\".\"id\" = 4 LIMIT 1" }
  },
  {
    "category" => "sql.active_record",
    "data" => { "sql" => "SELECT \"posts\".* FROM \"posts\" WHERE \"posts\".\"user_id\" = 1 LIMIT 1" }
  }
]

# Test query analysis
query_analysis = Transaction::SpanAnalyzer.analyze_sql_queries(sample_breadcrumbs)
puts "\n📊 Query Analysis:"
puts "  Total Queries: #{query_analysis[:total_queries]}"
puts "  Unique Patterns: #{query_analysis[:unique_patterns]}"

if query_analysis[:potential_n_plus_one].any?
  puts "  ⚠️  Potential N+1 Queries:"
  query_analysis[:potential_n_plus_one].each do |pattern|
    puts "    - #{pattern}"
  end
else
  puts "  ✅ No N+1 queries detected"
end

puts "\n📋 Query Patterns:"
query_analysis[:query_patterns].each do |pattern, data|
  puts "  #{pattern} (#{data[:count]}x)"
  puts "    Example: #{data[:examples].first}"
end

puts "\n✅ SpanAnalyzer test completed successfully!"