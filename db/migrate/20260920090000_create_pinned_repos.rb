# frozen_string_literal: true

# Prism's first persisted preference. See PinnedRepo for why this is not a
# violation of PLAN.md principle 1 ("GitHub is the only source of truth").
class CreatePinnedRepos < ActiveRecord::Migration[8.1]
  def change
    create_table :pinned_repos do |t|
      t.references :user, null: false, foreign_key: true

      # Not a foreign key into anything Prism owns — GitHub's repos have no
      # local id. owner/name is the natural key a client actually has on hand
      # (the repo picker never looks up a PinnedRepo id before it can render
      # the toggle).
      t.string :owner, null: false
      t.string :name, null: false

      # Pin order, oldest pin first. A plain integer rather than a timestamp
      # so a future drag-to-reorder has somewhere to write without a second
      # migration.
      t.integer :position, null: false

      t.timestamps
    end

    add_index :pinned_repos, %i[user_id owner name], unique: true, name: "index_pinned_repos_on_user_and_repo"
  end
end
