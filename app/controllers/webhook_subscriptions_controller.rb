# frozen_string_literal: true

# Which repositories Prism watches, and as whom.
#
# Thin, like every other controller here: Webhooks::Registrar does the GitHub
# work and owns the wording for every way it can fail.
#
# Two screens post here: /subscriptions, which reloads itself, and the watch
# control on a repository's own pull request list, which sends `from=repo` and
# gets that control back over Turbo instead. Same actions, same registrar,
# same messages — only the answer differs, which is why `settled` and `failed`
# are the only place either screen is mentioned.
class WebhookSubscriptionsController < ApplicationController
  include GithubErrorHandling

  def index
    @subscriptions = current_user.webhook_subscriptions.order(:owner, :name)
    @repos = selectable_repos
    @public_url_configured = Webhooks::PublicUrl.configured?
  end

  def create
    owner, name = split_full_name(params[:full_name])
    return redirect_to webhook_subscriptions_path, alert: "Pick a repository first.", status: :see_other if owner.nil?

    Webhooks::Registrar.new(current_user).subscribe(owner, name)

    settled owner, name,
            notice: "Prism is watching #{owner}/#{name}. New pull requests with Markdown will " \
                    "get a link to their Prism review, added as @#{current_user.login}."
  rescue Webhooks::MissingPublicUrl, Webhooks::RegistrationError => error
    failed owner, name, error.message
  end

  # Re-register: the hook exists and is fine, its callback URL has just moved.
  def update
    subscription = current_user.webhook_subscriptions.find(params[:id])
    Webhooks::Registrar.new(current_user).re_register(subscription)

    settled subscription.owner, subscription.name,
            notice: "GitHub is now delivering #{subscription.full_name} to #{subscription.callback_url}."
  rescue Webhooks::MissingPublicUrl, Webhooks::RegistrationError => error
    failed subscription.owner, subscription.name, error.message
  end

  def destroy
    subscription = current_user.webhook_subscriptions.find(params[:id])
    owner, name, full_name = subscription.owner, subscription.name, subscription.full_name
    note = Webhooks::Registrar.new(current_user).unsubscribe(subscription)

    # A note means the row is gone but the hook on GitHub is not, which leaves
    # the person something to do — that is an alert, not a confirmation.
    return failed(owner, name, note) if note

    settled owner, name, notice: "Prism has stopped watching #{full_name} and deleted its webhook."
  end

  private

  # Where the answer goes. /subscriptions reloads itself, because the action
  # changed a row in a list it is showing. The repository page gets its own
  # control back, in place, because the control is the only thing on that
  # screen the action changed.
  def settled(owner, name, notice:)
    return redirect_to(webhook_subscriptions_path, notice: notice, status: :see_other) unless from_repo?

    respond_to do |format|
      format.turbo_stream { render turbo_stream: watch_control(owner, name) }
      format.html { redirect_to repo_pulls_path(owner: owner, repo: name), notice: notice, status: :see_other }
    end
  end

  # The registrar's failures are things the person can act on — grant admin,
  # set PRISM_PUBLIC_URL, pick a repository nobody has taken. On the
  # repository page they belong beside the button that caused them rather
  # than in a flash on a screen the person didn't ask to be sent to.
  def failed(owner, name, message)
    return redirect_to(webhook_subscriptions_path, alert: message, status: :see_other) unless from_repo?

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: watch_control(owner, name, error: message), status: :unprocessable_entity
      end
      format.html { redirect_to repo_pulls_path(owner: owner, repo: name), alert: message, status: :see_other }
    end
  end

  # Re-read rather than reason about it: whether this user is now watching the
  # repository is a row in the database, and after subscribe/unsubscribe the
  # database is the only thing that knows.
  def watch_control(owner, name, error: nil)
    turbo_stream.replace(
      "repo-watch",
      partial: "webhook_subscriptions/watch",
      locals: { owner: owner, name: name, error: error,
                subscription: current_user.webhook_subscriptions.named(owner, name).first }
    )
  end

  def from_repo? = params[:from] == "repo"

  # A free-text repository field would mostly produce typos, and the repo list
  # is one already-cached GitHub call. If it fails, the screen still renders —
  # the list is a convenience, and `full_name` is submitted as text either way.
  def selectable_repos
    github.repos(page: 1).sort_by { |repo| repo.full_name.downcase }
  rescue Github::Error
    []
  end

  # Split here rather than taking two params, so the form can submit one value
  # straight out of the picker.
  def split_full_name(value)
    owner, _, name = value.to_s.strip.partition("/")
    return [ nil, nil ] if owner.blank? || name.blank? || name.include?("/")

    [ owner, name ]
  end
end
