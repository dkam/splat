# frozen_string_literal: true

require "test_helper"

# Guards the checked-in schema files for the secondary databases.
#
# A secondary database whose `migrations_paths` directory does not exist gets
# no migrations from `db:migrate`, so it ends up with no tables — and then the
# schema dump that follows writes an *empty* `version: 0` schema over the
# checked-in file. Nothing errors; the file just quietly loses its tables, and
# the next fresh deploy loads a schema that defines nothing. The cache database
# lost solid_cache_entries this way three separate times.
#
# The invariant these tests pin: every database with a `migrations_paths` has
# that directory on disk, and every secondary schema file actually declares the
# table its backend needs.
class SecondarySchemasTest < ActiveSupport::TestCase
  DATABASES = Rails.application.config.database_configuration.fetch("development")

  test "every configured migrations_paths directory exists" do
    DATABASES.each do |name, config|
      path = config["migrations_paths"]
      next if path.blank?

      assert Rails.root.join(path).directory?,
        "#{name} database points at migrations_paths #{path.inspect}, which does not exist — " \
        "db:migrate will leave that database empty and dump an empty schema over db/#{name}_schema.rb"
    end
  end

  {
    "cache" => "solid_cache_entries",
    "cable" => "solid_cable_messages"
  }.each do |database, table|
    test "db/#{database}_schema.rb declares #{table}" do
      schema = Rails.root.join("db/#{database}_schema.rb").read

      assert_match(/create_table "#{table}"/, schema,
        "db/#{database}_schema.rb has been clobbered — a fresh deploy would come up without #{table}")
      refute_match(/define\(version: 0\)/, schema,
        "db/#{database}_schema.rb is at version 0, the signature of an empty-database schema dump")
    end
  end
end
