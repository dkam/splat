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

ActiveRecord::Schema[8.1].define(version: 2026_06_21_000001) do
  create_table "spans", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.json "data"
    t.integer "depth", default: 0, null: false
    t.text "description"
    t.datetime "end_timestamp"
    t.string "op"
    t.string "parent_span_id"
    t.integer "project_id", null: false
    t.integer "sequence", default: 0, null: false
    t.string "span_id", null: false
    t.string "status"
    t.json "tags"
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
    t.string "environment", default: "", null: false
    t.datetime "hour_bucket", null: false
    t.bigint "project_id", null: false
    t.string "transaction_name", null: false
    t.index ["project_id", "hour_bucket"], name: "index_transaction_histograms_on_project_id_and_hour_bucket"
    t.index ["project_id", "transaction_name", "environment", "hour_bucket", "bucket_index"], name: "index_transaction_histograms_unique", unique: true
  end

  create_table "transaction_hourly_stats", force: :cascade do |t|
    t.bigint "count", default: 0, null: false
    t.bigint "db_time_count", default: 0, null: false
    t.string "environment", default: "", null: false
    t.bigint "error_count", default: 0, null: false
    t.datetime "hour_bucket", null: false
    t.integer "max_duration", default: 0, null: false
    t.integer "max_query_count", default: 0, null: false
    t.integer "min_duration"
    t.bigint "n_plus_one_count", default: 0, null: false
    t.bigint "project_id", null: false
    t.bigint "sum_db_time", default: 0, null: false
    t.bigint "sum_duration", default: 0, null: false
    t.bigint "sum_query_count", default: 0, null: false
    t.bigint "sum_view_time", default: 0, null: false
    t.string "transaction_name", null: false
    t.bigint "view_time_count", default: 0, null: false
    t.index ["project_id", "hour_bucket"], name: "index_transaction_hourly_stats_on_project_id_and_hour_bucket"
    t.index ["project_id", "transaction_name", "environment", "hour_bucket"], name: "index_transaction_hourly_stats_unique", unique: true
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
    t.index ["transaction_name", "timestamp"], name: "index_transactions_on_transaction_name_and_timestamp"
  end
end
