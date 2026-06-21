class AddProjectEnvironmentIndexToTransactions < ActiveRecord::Migration[8.1]
  def change
    # The endpoints page builds its environment filter list with
    # `SELECT DISTINCT environment FROM transactions WHERE project_id = ?`
    # (EndpointsController#cached_environments). With only the single-column
    # project_id index, SQLite scans every row for the project to collect the
    # handful of distinct environments — measured at ~9s on the production
    # transactions DB, the single worst transaction on that endpoint. A
    # composite on (project_id, environment) lets SQLite satisfy the DISTINCT
    # with an ordered index scan (skip-scanning between distinct values), so
    # the cache-miss path is no longer a full table scan. The standalone
    # project_id index is a prefix of this one, so drop it.
    add_index :transactions, [:project_id, :environment]
    remove_index :transactions, :project_id
  end
end
