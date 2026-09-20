# frozen_string_literal: true

# The delivery log. Its first job is replay rejection: `delivery_id` is
# GitHub's X-GitHub-Delivery GUID and the unique index on it is what makes a
# redelivered payload a no-op rather than a second edit.
#
# It deliberately stores no payload — only what Prism did and why, which is an
# audit trail of our own actions rather than a copy of GitHub's data.
class CreateWebhookDeliveries < ActiveRecord::Migration[8.1]
  def change
    create_table :webhook_deliveries do |t|
      t.references :webhook_subscription, null: false, foreign_key: true

      t.string :delivery_id, null: false
      t.string :event, null: false
      t.string :action

      # The one number we keep: which pull request this delivery was about.
      t.integer :pull_request_number

      # "accepted" (queued) | "ignored" (an event we don't act on) |
      # "processed" | "failed".
      t.string :status, null: false, default: "accepted"
      t.text :result
      t.datetime :processed_at

      t.timestamps

      t.index :delivery_id, unique: true
      t.index :created_at
    end
  end
end
