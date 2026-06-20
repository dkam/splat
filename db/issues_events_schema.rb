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

ActiveRecord::Schema[8.1].define(version: 2026_06_20_000001) do
  create_table "compression_dictionaries", force: :cascade do |t|
    t.boolean "active", default: false, null: false
    t.float "baseline_ratio"
    t.datetime "created_at", null: false
    t.binary "dict", null: false
    t.integer "sample_count"
    t.string "segment", null: false
    t.datetime "trained_at", null: false
    t.datetime "updated_at", null: false
    t.integer "version", null: false
    t.index ["segment", "version"], name: "index_compression_dictionaries_on_segment_and_version", unique: true
    t.index ["segment"], name: "index_compression_dictionaries_on_active_segment", unique: true, where: "active = 1"
  end

  create_table "dictionary_training_runs", force: :cascade do |t|
    t.float "candidate_ratio"
    t.float "current_ratio"
    t.float "gain"
    t.text "notes"
    t.boolean "promoted", default: false, null: false
    t.integer "promoted_to_version"
    t.datetime "ran_at", null: false
    t.integer "samples"
    t.string "segment", null: false
    t.index ["segment", "ran_at"], name: "index_dictionary_training_runs_on_segment_and_ran_at"
  end

  create_table "events", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "dict_id"
    t.integer "duration", default: 0, null: false
    t.string "environment"
    t.string "event_id", null: false
    t.string "exception_type"
    t.text "exception_value"
    t.string "fingerprint", limit: 1000
    t.bigint "issue_id"
    t.text "message"
    t.binary "payload_blob"
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
    t.integer "count", default: 0
    t.datetime "created_at", null: false
    t.string "exception_type"
    t.string "fingerprint", null: false
    t.datetime "first_seen", null: false
    t.string "first_seen_release"
    t.datetime "last_burst_at"
    t.integer "last_burst_rate"
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
end
