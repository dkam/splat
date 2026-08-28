# frozen_string_literal: true

# Solid Cache ships schema-only: the installer wrote db/cache_schema.rb and no
# migration, but database.yml still points the cache database at a
# db/cache_migrate directory. With that directory missing, `db:migrate` found
# nothing to run against the cache database, left it with no tables, and then
# dumped *that* empty database over db/cache_schema.rb — silently deleting
# solid_cache_entries from the file. Three times (f9481e0, ae4c9a9, and again
# here) the table had to be typed back in by hand, and in between a fresh
# deploy would boot with no cache table and 500 on every cached read.
#
# Owning the table in a migration closes the loop: db:migrate now creates it
# and the dump that follows writes it back out, so the schema file round-trips
# instead of emptying. Guarded, because every existing cache database already
# has the table from the original solid_cache:install.
class EnsureSolidCacheEntriesSchema < ActiveRecord::Migration[8.1]
  def up
    return if table_exists?(:solid_cache_entries)

    create_table :solid_cache_entries do |t|
      t.binary :key, limit: 1024, null: false
      t.binary :value, limit: 536_870_912, null: false
      t.datetime :created_at, null: false
      t.integer :key_hash, limit: 8, null: false
      t.integer :byte_size, limit: 4, null: false
      t.index :byte_size, name: "index_solid_cache_entries_on_byte_size"
      t.index [:key_hash, :byte_size], name: "index_solid_cache_entries_on_key_hash_and_byte_size"
      t.index :key_hash, unique: true, name: "index_solid_cache_entries_on_key_hash"
    end
  end

  def down
    drop_table :solid_cache_entries, if_exists: true
  end
end
