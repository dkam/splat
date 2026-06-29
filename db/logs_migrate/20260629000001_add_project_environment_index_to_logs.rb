class AddProjectEnvironmentIndexToLogs < ActiveRecord::Migration[8.1]
  # The logs index page builds an environment-filter dropdown from
  # `SELECT DISTINCT environment WHERE project_id = ?`. The existing
  # single-column index on `environment` can't satisfy the project_id filter,
  # so SQLite read ~1M full rows (~100s on the meta instance). A composite
  # [project_id, environment] index turns this into a covering, index-only scan.
  def change
    add_index :logs, [:project_id, :environment], name: "index_logs_on_project_id_and_environment"
  end
end
