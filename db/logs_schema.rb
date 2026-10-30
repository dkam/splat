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

ActiveRecord::Schema[8.1].define(version: 2026_10_28_000001) do
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
end
