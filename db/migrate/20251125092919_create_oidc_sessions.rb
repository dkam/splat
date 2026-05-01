class CreateOidcSessions < ActiveRecord::Migration[8.1]
  def change
    create_table :oidc_sessions do |t|
      t.string :oidc_sid, null: false
      t.string :session_id, null: false
      t.string :user_email, null: false
      t.datetime :expires_at, null: false

      t.timestamps
    end
    add_index :oidc_sessions, :oidc_sid, unique: true
    add_index :oidc_sessions, :session_id
    add_index :oidc_sessions, :user_email
    add_index :oidc_sessions, :expires_at
  end
end
