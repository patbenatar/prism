# frozen_string_literal: true

# One row per repository Prism watches, and the account it acts as.
#
# This is Prism's own configuration, not a copy of GitHub's data (principle 1):
# nothing here can be derived from GitHub, and nothing here goes stale when
# GitHub changes. See app/models/webhook_subscription.rb.
class CreateWebhookSubscriptions < ActiveRecord::Migration[8.1]
  def change
    create_table :webhook_subscriptions do |t|
      t.references :user, null: false, foreign_key: true

      # owner/name in GitHub's own casing, because these end up in a link a
      # human reads. GitHub treats them case-insensitively, so the uniqueness
      # index below is on lower(), not on the stored bytes.
      #
      # github_repo_id is the rename-proof identity: a delivery is matched on
      # it first, so renaming the repository on GitHub doesn't orphan the hook.
      t.string :owner, null: false
      t.string :name, null: false
      t.bigint :github_repo_id

      # GitHub's id for the hook we created, so unsubscribing can delete it.
      t.bigint :hook_id

      # Per-subscription HMAC secret, encrypted at rest like users.access_token.
      # Deterministic is wrong here (we never query by it) and would leak
      # equality between subscriptions.
      t.text :secret, null: false

      # "active" | "broken". Broken means GitHub refused us as this user —
      # revoked token, lost admin, repository gone — and the job stops trying.
      t.string :status, null: false, default: "active"
      t.string :broken_reason
      t.datetime :broken_at

      t.datetime :last_delivery_at

      t.timestamps

      t.index "lower(owner), lower(name)",
              unique: true, name: "index_webhook_subscriptions_on_lower_owner_name"
      t.index :github_repo_id
    end
  end
end
