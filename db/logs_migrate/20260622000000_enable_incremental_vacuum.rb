class EnableIncrementalVacuum < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    execute "PRAGMA auto_vacuum = INCREMENTAL"
    execute "VACUUM"
  end

  def down
    execute "PRAGMA auto_vacuum = NONE"
    execute "VACUUM"
  end
end
