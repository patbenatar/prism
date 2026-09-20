# frozen_string_literal: true

module Webhooks
  # Creates and removes the repository webhook on GitHub, and keeps the local
  # subscription row honest about it.
  #
  # The `repo` scope Prism already asks for covers repository webhooks — it
  # grants "read and write access to … repository webhooks" verbatim (see
  # docs/research/github-api.md §1.2) — so subscribing needs no new scope and
  # no re-authorization. What it does need is *admin* on the repository, which
  # GitHub signals by 404ing the hooks endpoints rather than 403ing them: a
  # collaborator with write access gets the same answer as someone asking
  # about a repository that doesn't exist. Every message below therefore says
  # both possibilities out loud instead of guessing.
  class Registrar
    EVENTS = [ "pull_request" ].freeze

    attr_reader :user

    def initialize(user)
      @user = user
    end

    # Returns the saved subscription. Raises RegistrationError with wording
    # meant for the person who clicked the button.
    def subscribe(owner, name)
      raise MissingPublicUrl unless PublicUrl.configured?

      repo = fetch_repo(owner, name)
      subscription = build_subscription(repo)

      begin
        hook = create_or_adopt_hook(subscription)
        subscription.update!(hook_id: hook.id, callback_url: callback_url)
      rescue StandardError
        # A subscription with no hook behind it would sit in the list looking
        # live and never receive a delivery. Better to leave no trace.
        subscription.destroy
        raise
      end

      subscription
    end

    # Points an existing hook at the current callback URL.
    #
    # Updating in place rather than making someone delete and recreate: the
    # subscription, its secret and its delivery history are all still good,
    # and the only thing wrong is an address. Deleting would also lose the
    # `declined` record of every pull request whose author asked Prism to
    # stop, which is the one piece of state here that must never be
    # resurrected by accident.
    def re_register(subscription)
      raise MissingPublicUrl unless PublicUrl.configured?

      hook = update_or_create_hook(subscription)
      subscription.update!(hook_id: hook.id, callback_url: callback_url)
      # Whatever broke it, GitHub has just accepted us as this user on this
      # repository, so the evidence for "broken" is gone.
      subscription.mark_active! if subscription.broken?

      subscription
    end

    # Deletes the hook on GitHub and then the row. Returns a short note about
    # what happened on GitHub's side, or nil when it went cleanly, because
    # "we removed it locally but GitHub still has the hook" is something the
    # person needs to be told.
    def unsubscribe(subscription)
      note = delete_hook(subscription)
      subscription.destroy!
      note
    end

    private

    def fetch_repo(owner, name)
      client.repo(owner, name)
    rescue Github::NotFound
      raise RegistrationError, "#{owner}/#{name} doesn't exist, or your GitHub account can't see it."
    rescue Github::Forbidden => error
      raise RegistrationError, error.user_message
    end

    def build_subscription(repo)
      WebhookSubscription.create!(
        user: user,
        owner: repo.owner,
        name: repo.name,
        github_repo_id: repo.id,
        secret: WebhookSubscription.generate_secret
      )
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
      raise RegistrationError, "#{repo.full_name} is already subscribed."
    end

    def create_or_adopt_hook(subscription)
      client.create_hook(subscription.owner, subscription.name,
                         url: callback_url, secret: subscription.secret, events: EVENTS)
    rescue Github::Unprocessable => error
      # GitHub refuses a second hook with the same callback URL. The existing
      # one is almost always ours from a subscription that was removed without
      # its hook being deleted — but its secret is write-only and we cannot
      # read it back, so adopting it means overwriting its config with a
      # secret we do know. Anything else and we could never verify a delivery.
      adopt_existing_hook(subscription) ||
        raise(RegistrationError, "GitHub refused the webhook: #{error.message}")
    rescue Github::NotFound
      raise RegistrationError, admin_required(subscription)
    rescue Github::Forbidden
      raise RegistrationError, admin_required(subscription)
    end

    # PATCH replaces the hook's whole `config`, so the secret has to be sent
    # again or GitHub would clear it and every later delivery would arrive
    # unsigned. It is the same secret, deliberately: nothing about a changed
    # hostname makes the old one suspect, and rotating it would be one more
    # thing to go wrong.
    def update_or_create_hook(subscription)
      return create_or_adopt_hook(subscription) if subscription.hook_id.blank?

      client.update_hook(subscription.owner, subscription.name, subscription.hook_id,
                         url: callback_url, secret: subscription.secret, events: EVENTS)
    rescue Github::NotFound
      # Either the hook is gone from GitHub — deleted by hand, or the
      # repository was recreated — or this account is no longer an admin.
      # GitHub gives the same 404 for both, and creating is the right next
      # move either way: it either works, or it fails with the admin message.
      create_or_adopt_hook(subscription)
    rescue Github::Forbidden
      raise RegistrationError, admin_required(subscription)
    end

    def adopt_existing_hook(subscription)
      existing = client.hooks(subscription.owner, subscription.name)
                       .find { |hook| hook.url == callback_url }
      return nil if existing.nil?

      client.update_hook(subscription.owner, subscription.name, existing.id,
                         url: callback_url, secret: subscription.secret, events: EVENTS)
    rescue Github::NotFound, Github::Forbidden
      nil
    end

    def delete_hook(subscription)
      return "No webhook was registered on GitHub." if subscription.hook_id.blank?

      client.delete_hook(subscription.owner, subscription.name, subscription.hook_id)
      nil
    rescue Github::NotFound
      # Already gone: someone deleted it in GitHub's settings, or the whole
      # repository is gone. Either way there is nothing left to clean up.
      nil
    rescue Github::Error => error
      "Prism stopped watching #{subscription.full_name}, but GitHub wouldn't let us " \
        "delete the webhook (#{error.user_message}). Remove it in the repository's " \
        "Settings → Webhooks."
    end

    def admin_required(subscription)
      "You need admin access to #{subscription.full_name} on GitHub to add a webhook. " \
        "GitHub gives the same answer when the repository doesn't exist, so check the name too."
    end

    def callback_url = @callback_url ||= CallbackUrl.current

    def client = @client ||= Github::Client.new(user)
  end
end
