# frozen_string_literal: true

class Release < ApplicationRecord
  belongs_to :project

  validates :version, presence: true, uniqueness: {scope: :project_id}
  validates :first_seen_at, :last_seen_at, presence: true

  scope :recent, -> { order(first_seen_at: :desc) }
  scope :seen_since, ->(time) { where("first_seen_at >= ?", time) }

  # Record an event/transaction sighting against a release. Creates the row on
  # first sighting and bumps counters/last_seen_at on subsequent ones. Idempotent
  # under racing workers via the (project_id, version) unique index.
  def self.record_sighting!(project:, version:, timestamp:, kind: :event)
    return nil if version.blank?

    counter_column = (kind == :transaction) ? :transaction_count : :event_count

    rec = find_or_create_by!(project_id: project.id, version: version) do |r|
      r.first_seen_at = timestamp
      r.last_seen_at = timestamp
    end

    # Bump counters and last_seen_at without re-running validations or callbacks.
    Release.where(id: rec.id).update_all(<<~SQL.squish)
      #{counter_column} = #{counter_column} + 1,
      last_seen_at = CASE
        WHEN last_seen_at < #{connection.quote(timestamp)} THEN #{connection.quote(timestamp)}
        ELSE last_seen_at
      END,
      first_seen_at = CASE
        WHEN first_seen_at > #{connection.quote(timestamp)} THEN #{connection.quote(timestamp)}
        ELSE first_seen_at
      END,
      updated_at = #{connection.quote(Time.current)}
    SQL

    rec
  rescue ActiveRecord::RecordNotUnique
    retry
  end
end
