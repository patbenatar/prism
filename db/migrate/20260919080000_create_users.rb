# frozen_string_literal: true

# The only table Prism has. GitHub owns everything else: repositories, pull
# requests, comments, reviews and threads are fetched on demand and cached, so
# there is nothing here to keep in sync and nothing to migrate when GitHub's
# data changes.
class CreateUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :users do |t|
      # GitHub's own user id. Stable across renames, which `login` is not, so
      # this is what we match on when someone signs in again.
      t.bigint  :github_id, null: false
      t.string  :login,     null: false
      t.string  :name
      t.string  :avatar_url

      # Encrypted with ActiveRecord::Encryption (see User#access_token).
      # Ciphertext is a JSON envelope several times the size of the raw
      # `gho_…` token, so this is text rather than a bounded string.
      t.text    :access_token

      # The space-delimited scope list GitHub actually granted, which can be
      # narrower than what we asked for. Checked before we offer to write.
      t.string  :token_scopes

      t.datetime :last_signed_in_at

      t.timestamps
    end

    add_index :users, :github_id, unique: true
    add_index :users, :login
  end
end
