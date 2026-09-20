# frozen_string_literal: true

# The callback URL we actually registered with GitHub.
#
# Without it there is no way to notice that PRISM_PUBLIC_URL has moved since a
# subscription was created — and the symptom of that is deliveries silently
# never arriving, which is the worst kind of thing to debug. A development
# quick tunnel gets a new hostname on every restart, so this is the normal
# case locally, not an edge case.
class AddCallbackUrlToWebhookSubscriptions < ActiveRecord::Migration[8.1]
  def change
    add_column :webhook_subscriptions, :callback_url, :string
  end
end
