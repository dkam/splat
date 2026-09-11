class AddPositionToProjects < ActiveRecord::Migration[8.1]
  # Card order on the projects index, set by dragging. Backfilled from the
  # order the index used before this column existed (updated_at desc) so an
  # existing install's homepage looks unchanged until someone drags a card.
  def up
    add_column :projects, :position, :integer

    Project.reset_column_information
    Project.order(updated_at: :desc).each_with_index do |project, index|
      project.update_column(:position, index + 1)
    end

    change_column_default :projects, :position, 0
    change_column_null :projects, :position, false, 0
  end

  def down
    remove_column :projects, :position
  end
end
