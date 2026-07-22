class CreateIssueFacets < ActiveRecord::Migration[8.1]
  def change
    # Grouping is deliberately cross-environment — one issue can span staging
    # and production — so "environment" can't be a column on issues. What the
    # filter actually means is "issues with at least one event in env X", and
    # answering that from events is a DISTINCT over the widest table we have.
    #
    # So: the (issue, name, value) pairs are denormalised here at ingest, same
    # shape as the primary DB's facets table. Unlike that one this is joined —
    # it drives the filter, not just the dropdown — hence it lives beside
    # issues rather than beside projects.
    create_table :issue_facets do |t|
      t.integer :project_id, null: false
      t.integer :issue_id, null: false
      t.string :name, null: false
      t.string :value, null: false
      t.datetime :last_seen_at, null: false

      t.timestamps
    end

    # Upsert target on the ingest path, and the "which envs has this issue been
    # seen in?" lookup for the row chips.
    add_index :issue_facets, [:issue_id, :name, :value], unique: true,
      name: "index_issue_facets_on_issue_and_value"

    # The web UI is always project-scoped: this serves both its filter subquery
    # (value -> issue_ids) and the dropdown's DISTINCT. issue_id is included so
    # the filter is index-only.
    add_index :issue_facets, [:project_id, :name, :value, :issue_id],
      name: "index_issue_facets_on_scope_and_value"

    # MCP spans every project unless the caller narrows it, so the same filter
    # runs with no project_id and can't use the index above (project_id is its
    # leading column). Cheap to carry — this table is issues x environments,
    # not events.
    add_index :issue_facets, [:name, :value, :project_id, :issue_id],
      name: "index_issue_facets_on_value_across_projects"

    # The daily retention sweep deletes by last_seen_at, which leads none of the
    # indexes above — without this it's a full scan of a table that grows with
    # issues x values, every day, forever.
    add_index :issue_facets, :last_seen_at
  end
end
