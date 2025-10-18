class CreateProjects < ActiveRecord::Migration[8.1]
  def change
    create_table :projects do |t|
      t.string :name, null: false
      t.string :slug, null: false
      t.string :public_key, null: false
      t.text :description
      t.string :platform
      t.boolean :active, default: true

      t.timestamps
    end

    # Essential indexes only
    add_index :projects, :slug, unique: true
    add_index :projects, :public_key, unique: true
  end
end
