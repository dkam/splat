class AddResolvedInReleaseToIssues < ActiveRecord::Migration[8.1]
  # Resolve in next release: the project's newest release when the issue was
  # resolved. Events from it, or from an older one, don't reopen the issue —
  # see Issue#regressed_by?.
  def change
    add_column :issues, :resolved_in_release, :string
  end
end
