class AddSourceUrlTemplateToProjects < ActiveRecord::Migration[8.1]
  # Where a stack frame's line lives in the project's repository, as a URL with
  # {sha}, {path} and {line} in it — see Project#source_url.
  def change
    add_column :projects, :source_url_template, :string
  end
end
