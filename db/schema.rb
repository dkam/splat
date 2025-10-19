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

ActiveRecord::Schema[8.1].define(version: 2025_10_18_082207) do
  create_table "events", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "environment"
    t.string "event_id", null: false
    t.string "exception_type"
    t.text "exception_value"
    t.json "fingerprint"
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
    t.index ["environment"], name: "index_events_on_environment"
    t.index ["event_id"], name: "index_events_on_event_id", unique: true
    t.index ["exception_type"], name: "index_events_on_exception_type"
    t.index ["issue_id"], name: "index_events_on_issue_id"
    t.index ["platform"], name: "index_events_on_platform"
    t.index ["project_id"], name: "index_events_on_project_id"
    t.index ["timestamp"], name: "index_events_on_timestamp"
    t.index ["transaction_name"], name: "index_events_on_transaction_name"
  end

  create_table "issues", force: :cascade do |t|
    t.integer "count", default: 0
    t.datetime "created_at", null: false
    t.string "exception_type"
    t.string "fingerprint", null: false
    t.datetime "first_seen", null: false
    t.datetime "last_seen", null: false
    t.integer "project_id", null: false
    t.integer "status", default: 0, null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["count"], name: "index_issues_on_count"
    t.index ["fingerprint"], name: "index_issues_on_fingerprint", unique: true
    t.index ["last_seen"], name: "index_issues_on_last_seen"
    t.index ["project_id"], name: "index_issues_on_project_id"
    t.index ["status"], name: "index_issues_on_status"
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

  create_table "transactions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "db_time"
    t.integer "duration", null: false
    t.string "environment"
    t.string "http_method"
    t.string "http_status"
    t.string "http_url"
    t.json "measurements"
    t.string "op"
    t.integer "project_id", null: false
    t.string "release"
    t.string "server_name"
    t.json "tags"
    t.datetime "timestamp", null: false
    t.string "transaction_id", null: false
    t.string "transaction_name", null: false
    t.datetime "updated_at", null: false
    t.integer "view_time"
    t.index ["duration"], name: "index_transactions_on_duration"
    t.index ["environment", "timestamp"], name: "index_transactions_on_environment_and_timestamp"
    t.index ["http_method"], name: "index_transactions_on_http_method"
    t.index ["http_status"], name: "index_transactions_on_http_status"
    t.index ["project_id"], name: "index_transactions_on_project_id"
    t.index ["timestamp"], name: "index_transactions_on_timestamp"
    t.index ["transaction_id"], name: "index_transactions_on_transaction_id", unique: true
    t.index ["transaction_name", "timestamp"], name: "index_transactions_on_transaction_name_and_timestamp"
    t.index ["transaction_name"], name: "index_transactions_on_transaction_name"
  end

  add_foreign_key "events", "projects"
  add_foreign_key "issues", "projects"
  add_foreign_key "transactions", "projects"
end
