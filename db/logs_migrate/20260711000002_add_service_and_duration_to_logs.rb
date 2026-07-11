# Promote two OTel resource/record attributes to first-class columns:
#   - service: the emitting system (from the `service.name` resource attribute),
#     so logs can be faceted by system (postgresql / booko / nginx) rather than
#     only by ingest protocol.
#   - duration_ms: slow-query / operation duration, so it can be range-filtered
#     and sorted numerically instead of parsed out of the message text.
# Both are nullable and only populated when the source provides them (e.g. the
# Postgres OTLP collector), so the indexes are partial to stay small on the
# high-volume, mostly-null table.
class AddServiceAndDurationToLogs < ActiveRecord::Migration[8.1]
  def change
    add_column :logs, :service, :string
    add_column :logs, :duration_ms, :float

    add_index :logs, [:project_id, :service],
      where: "service IS NOT NULL", name: "index_logs_on_project_id_and_service"
    add_index :logs, [:project_id, :duration_ms],
      where: "duration_ms IS NOT NULL", name: "index_logs_on_project_id_and_duration_ms"
  end
end
