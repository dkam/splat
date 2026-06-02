# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_06_02_232710) do
  create_table "events", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "duration", default: 0, null: false
    t.string "environment"
    t.string "event_id", null: false
    t.string "exception_type"
    t.text "exception_value"
    t.string "fingerprint", limit: 1000
    t.bigint "issue_id"
    t.text "message"
    t.json "payload"
    t.string "platform"
    t.integer "project_id", null: false
    t.string "release"
    t.string "sdk_name"
    t.string "sdk_version"
    t.string "server_name"
    t.datetime "timestamp", null: false
    t.string "transaction_name"
    t.datetime "updated_at", null: false
    t.index ["duration"], name: "index_events_on_duration"
    t.index ["environment"], name: "index_events_on_environment"
    t.index ["issue_id"], name: "index_events_on_issue_id"
    t.index ["project_id", "event_id"], name: "index_events_on_project_id_and_event_id", unique: true
    t.index ["project_id"], name: "index_events_on_project_id"
    t.index ["timestamp"], name: "index_events_on_timestamp"
  end

  create_table "issues", force: :cascade do |t|
    t.integer "auto_ignore_rate"
    t.datetime "auto_ignored_at"
    t.integer "count", default: 0
    t.datetime "created_at", null: false
    t.string "exception_type"
    t.string "fingerprint", null: false
    t.datetime "first_seen", null: false
    t.string "first_seen_release"
    t.datetime "last_seen", null: false
    t.string "last_seen_release"
    t.integer "project_id", null: false
    t.integer "status", default: 0, null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["last_seen"], name: "index_issues_on_last_seen"
    t.index ["project_id", "fingerprint"], name: "index_issues_on_project_id_and_fingerprint", unique: true
    t.index ["project_id"], name: "index_issues_on_project_id"
    t.index ["status"], name: "index_issues_on_status"
  end

  create_table "oidc_sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "oidc_sid", null: false
    t.string "session_id", null: false
    t.datetime "updated_at", null: false
    t.string "user_email", null: false
    t.index ["expires_at"], name: "index_oidc_sessions_on_expires_at"
    t.index ["oidc_sid"], name: "index_oidc_sessions_on_oidc_sid", unique: true
    t.index ["session_id"], name: "index_oidc_sessions_on_session_id"
    t.index ["user_email"], name: "index_oidc_sessions_on_user_email"
  end

  create_table "projects", force: :cascade do |t|
    t.boolean "active", default: true
    t.datetime "created_at", null: false
    t.text "description"
    t.string "name", null: false
    t.string "platform"
    t.string "public_key", null: false
    t.string "slug", null: false
    t.datetime "updated_at", null: false
    t.index ["public_key"], name: "index_projects_on_public_key", unique: true
    t.index ["slug"], name: "index_projects_on_slug", unique: true
  end

  create_table "releases", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "event_count", default: 0, null: false
    t.datetime "first_seen_at", null: false
    t.datetime "last_seen_at", null: false
    t.integer "project_id", null: false
    t.integer "transaction_count", default: 0, null: false
    t.datetime "updated_at", null: false
    t.string "version", null: false
    t.index ["project_id", "first_seen_at"], name: "index_releases_on_project_id_and_first_seen_at"
    t.index ["project_id", "version"], name: "index_releases_on_project_id_and_version", unique: true
    t.index ["project_id"], name: "index_releases_on_project_id"
  end

  create_table "settings", force: :cascade do |t|
    t.boolean "auto_ignore_enabled", default: false, null: false
    t.integer "auto_ignore_threshold", default: 1000, null: false
    t.datetime "created_at", null: false
    t.integer "ducklake_events_retention_days", default: 365, null: false
    t.integer "ducklake_issues_retention_days", default: 730, null: false
    t.integer "ducklake_spans_retention_days", default: 30, null: false
    t.integer "ducklake_transactions_retention_days", default: 365, null: false
    t.integer "event_payloads_retention_days", default: 7, null: false
    t.integer "events_data_retention_days", default: 30, null: false
    t.string "forward_dsn"
    t.string "ntfy_priority", default: "default", null: false
    t.string "ntfy_token"
    t.string "ntfy_url"
    t.integer "transaction_measurements_retention_days", default: 7, null: false
    t.integer "transactions_data_retention_days", default: 90, null: false
    t.datetime "updated_at", null: false
  end

  create_table "transactions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "db_time"
    t.integer "duration", null: false
    t.string "environment"
    t.boolean "has_n_plus_one", default: false, null: false
    t.string "http_method"
    t.string "http_status"
    t.string "http_url"
    t.json "measurements"
    t.string "op"
    t.integer "project_id", null: false
    t.integer "query_count", default: 0, null: false
    t.string "release"
    t.string "server_name"
    t.boolean "spans_truncated", default: false, null: false
    t.json "tags"
    t.datetime "timestamp", null: false
    t.string "transaction_id", null: false
    t.string "transaction_name", null: false
    t.datetime "updated_at", null: false
    t.integer "view_time"
    t.index ["duration"], name: "index_transactions_on_duration"
    t.index ["project_id", "timestamp"], name: "index_transactions_on_project_id_and_timestamp"
    t.index ["project_id", "transaction_id"], name: "index_transactions_on_project_id_and_transaction_id", unique: true
    t.index ["project_id"], name: "index_transactions_on_project_id"
    t.index ["timestamp"], name: "index_transactions_on_timestamp"
    t.index ["transaction_name"], name: "index_transactions_on_transaction_name"
  end

  add_foreign_key "events", "projects"
  add_foreign_key "issues", "projects"
  add_foreign_key "releases", "projects"
  add_foreign_key "transactions", "projects"
end
