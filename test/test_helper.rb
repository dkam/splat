ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

# logs_fts (FTS5 virtual table + triggers) can't be represented in schema.rb, so
# rails/test_help's schema maintenance drops what the boot initializer created.
# Recreate it after the harness loads (covers single-process runs); parallel
# workers are covered by parallelize_setup below.
begin
  Logs::Fts.ensure!
rescue => e
  warn "[test_helper] logs_fts ensure skipped: #{e.class}: #{e.message}"
end

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Each parallel worker gets its own DB loaded from schema.rb, which can't
    # represent the logs_fts FTS5 virtual table/triggers — recreate them per
    # worker so full-text log search works in tests. (The boot initializer only
    # covers the single-process path.)
    parallelize_setup do |_worker|
      Logs::Fts.ensure!
    end

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...
  end
end
