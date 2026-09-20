# frozen_string_literal: true

# What Prism has placed on a given pull request, and whether it is still
# welcome there.
#
# The description itself is the source of truth for the *content* of the block
# — we read it back and splice, never reconstruct from here. This table exists
# for the one question the description cannot answer: our block is missing, so
# did we remove it, or did the author? Without that, deleting Prism's block by
# hand would mean it reappears on the next push, forever.
class CreatePullRequestAnnouncements < ActiveRecord::Migration[8.1]
  def change
    create_table :pull_request_announcements do |t|
      t.references :webhook_subscription, null: false, foreign_key: true, index: false
      t.integer :pull_request_number, null: false

      # "present"  — we placed the block and last saw it there
      # "absent"   — no renderable Markdown, so there is nothing to place
      # "declined" — we placed it and the author removed it. Never place again.
      t.string :state, null: false, default: "absent"

      t.integer :renderable_count, null: false, default: 0
      t.datetime :last_event_at

      t.timestamps

      t.index %i[webhook_subscription_id pull_request_number],
              unique: true, name: "index_pr_announcements_on_subscription_and_number"
    end
  end
end
