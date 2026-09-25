# frozen_string_literal: true

# Prism's production OAuth App has GitHub's "Expire user authorization tokens"
# switched on, so every sign-in issues an access token good for eight hours
# and a refresh token good for six months. We stored the first and dropped the
# second on the floor, which is why every user was silently signed out of
# GitHub's view eight hours after signing in and every webhook job 401'd for
# the rest of the day.
#
# These two columns are the whole of what it takes to stop doing that: the
# refresh token, and the moment the access token stops working.
#
# Additive and nullable, so the live table needs no backfill and no rewrite.
# Existing rows start with both null, which reads as "a non-expiring token we
# cannot refresh" — exactly the behaviour they have today. They keep it until
# their owner signs in again, at which point GitHub hands us the pair and
# Prism starts refreshing on their behalf. Nothing has to be migrated because
# a sign-in is the migration.
#
# `refresh_token` is `text` to match `access_token`: Active Record encryption
# stores a JSON envelope, not the bare value, so the column has to be wider
# than the credential it holds. See User, which declares `encrypts` on both.
class KeepTheTokenAliveInsteadOfReplacingIt < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :refresh_token, :text
    add_column :users, :access_token_expires_at, :datetime
  end
end
