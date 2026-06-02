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

ActiveRecord::Schema[8.1].define(version: 2026_06_03_000005) do
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
    t.index ["segment"], name: "index_compression_dictionaries_on_active_segment", where: "active = 1"
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

  create_table "spans", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "depth", default: 0, null: false
    t.text "description"
    t.bigint "dict_id"
    t.datetime "end_timestamp"
    t.string "op"
    t.string "parent_span_id"
    t.binary "payload_blob"
    t.integer "project_id", null: false
    t.integer "sequence", default: 0, null: false
    t.string "span_id", null: false
    t.string "status"
    t.datetime "timestamp", null: false
    t.string "trace_id"
    t.string "transaction_id", null: false
    t.index ["project_id", "op", "timestamp"], name: "index_spans_on_project_id_and_op_and_timestamp"
    t.index ["project_id", "transaction_id", "sequence"], name: "index_spans_on_project_id_and_transaction_id_and_sequence"
    t.index ["timestamp"], name: "index_spans_on_timestamp"
  end

  create_table "transaction_histograms", force: :cascade do |t|
    t.integer "bucket_index", null: false
    t.integer "count", null: false
    t.datetime "hour_bucket", null: false
    t.bigint "project_id", null: false
    t.string "transaction_name", null: false
    t.index ["project_id", "hour_bucket"], name: "index_transaction_histograms_on_project_id_and_hour_bucket"
    t.index ["project_id", "transaction_name", "hour_bucket", "bucket_index"], name: "index_transaction_histograms_unique", unique: true
  end

  create_table "transactions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "db_time"
    t.bigint "dict_id"
    t.integer "duration", null: false
    t.string "environment"
    t.boolean "has_n_plus_one", default: false, null: false
    t.string "http_method"
    t.string "http_status"
    t.string "http_url"
    t.string "op"
    t.binary "payload_blob"
    t.integer "project_id", null: false
    t.integer "query_count", default: 0, null: false
    t.string "release"
    t.string "server_name"
    t.boolean "spans_truncated", default: false, null: false
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
end
