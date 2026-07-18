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

ActiveRecord::Schema[8.1].define(version: 2026_07_18_100000) do
  create_table "cron_monitors", force: :cascade do |t|
    t.integer "checkin_margin"
    t.json "config"
    t.datetime "created_at", null: false
    t.string "environment"
    t.datetime "in_progress_since"
    t.datetime "last_checkin_at"
    t.float "last_duration"
    t.datetime "last_ok_at"
    t.string "last_status"
    t.integer "max_runtime"
    t.integer "project_id", null: false
    t.string "schedule_type"
    t.string "schedule_unit"
    t.string "schedule_value"
    t.string "slug", null: false
    t.string "state", default: "unknown", null: false
    t.string "timezone"
    t.datetime "updated_at", null: false
    t.index ["project_id", "slug"], name: "index_cron_monitors_on_project_id_and_slug", unique: true
  end

  create_table "facets", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "last_seen_at", null: false
    t.string "name", null: false
    t.integer "project_id", null: false
    t.string "stream", null: false
    t.datetime "updated_at", null: false
    t.string "value", null: false
    t.index ["project_id", "stream", "name", "value"], name: "index_facets_on_scope_and_value", unique: true
    t.index ["project_id", "stream", "name"], name: "index_facets_on_scope"
  end

  create_table "mcp_tokens", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "last_authenticated_at"
    t.datetime "last_used_at"
    t.string "token", null: false
    t.datetime "updated_at", null: false
    t.string "user_email", null: false
    t.index ["token"], name: "index_mcp_tokens_on_token", unique: true
    t.index ["user_email"], name: "index_mcp_tokens_on_user_email", unique: true
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
    t.json "forward_dsns", default: []
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
    t.integer "burst_threshold", default: 1000, null: false
    t.datetime "created_at", null: false
    t.integer "events_data_retention_days", default: 30, null: false
    t.integer "histograms_retention_days", default: 540, null: false
    t.integer "logs_data_retention_days", default: 14, null: false
    t.string "mcp_token"
    t.datetime "mcp_token_last_used_at"
    t.integer "mcp_token_ttl_days", default: 7, null: false
    t.string "ntfy_priority", default: "default", null: false
    t.string "ntfy_token"
    t.string "ntfy_url"
    t.integer "spans_data_retention_days", default: 30, null: false
    t.boolean "store_events", default: true, null: false
    t.boolean "store_logs", default: false, null: false
    t.boolean "store_transactions", default: true, null: false
    t.integer "transactions_data_retention_days", default: 90, null: false
    t.datetime "updated_at", null: false
  end

# Could not dump table "sqlite_stat1" because of following StandardError
#   Unknown type '' for column 'idx'


  add_foreign_key "cron_monitors", "projects"
  add_foreign_key "facets", "projects"
  add_foreign_key "releases", "projects"
end
