# frozen_string_literal: true

# Subscriptions used to have two states, `active` and `broken`, and `broken`
# was a one-way door. That was wrong for the most common failure by far: a
# token GitHub refused once. The user signs in again, the token is replaced
# and works, and nothing ever looks at the subscription again — it is dead for
# good over a failure that fixed itself.
#
# `suspended` is the middle state. It still acts: the next delivery retries,
# and a success puts it back to `active`. `broken` is now reserved for
# failures that really are permanent, including giving up after
# WebhookSubscription::MAX_CONSECUTIVE_FAILURES consecutive refusals.
#
# Every existing `broken` row is converted to `suspended`. That is not a
# guess: the only thing that has ever set `broken` is a token or permission
# refusal, which is exactly the case that should have been recoverable. The
# rows heal themselves on their next delivery, or the moment their owner signs
# in again.
class LetWebhookSubscriptionsRecover < ActiveRecord::Migration[8.1]
  def up
    add_column :webhook_subscriptions, :consecutive_failures, :integer, null: false, default: 0
    add_column :webhook_subscriptions, :last_failure_at, :datetime

    # `broken_reason` / `broken_at` keep their names — they describe whichever
    # state the row is in, and renaming them would churn every caller for a
    # word.
    # The stored reason is rewritten along with the status. Every existing one
    # reads "Your GitHub sign-in expired", which is the wording this change
    # also removes from Github::Unauthorized: OAuth App tokens do not expire.
    # Leaving it in place would keep teaching the wrong thing on the
    # subscriptions screen until each row happened to fail again.
    execute <<~SQL
      UPDATE webhook_subscriptions
         SET status = 'suspended',
             broken_reason = 'GitHub refused this account''s token.'
       WHERE status = 'broken'
    SQL
  end

  def down
    execute <<~SQL
      UPDATE webhook_subscriptions
         SET status = 'broken'
       WHERE status = 'suspended'
    SQL

    remove_column :webhook_subscriptions, :last_failure_at
    remove_column :webhook_subscriptions, :consecutive_failures
  end
end
