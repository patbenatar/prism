# frozen_string_literal: true

# Which repositories Prism watches, and as whom.
#
# Thin, like every other controller here: Webhooks::Registrar does the GitHub
# work and owns the wording for every way it can fail.
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

    redirect_to webhook_subscriptions_path,
                notice: "Prism is watching #{owner}/#{name}. New pull requests with Markdown will " \
                        "get a link to their Prism review, added as @#{current_user.login}.",
                status: :see_other
  rescue Webhooks::MissingPublicUrl, Webhooks::RegistrationError => error
    redirect_to webhook_subscriptions_path, alert: error.message, status: :see_other
  end

  # Re-register: the hook exists and is fine, its callback URL has just moved.
  def update
    subscription = current_user.webhook_subscriptions.find(params[:id])
    Webhooks::Registrar.new(current_user).re_register(subscription)

    redirect_to webhook_subscriptions_path,
                notice: "GitHub is now delivering #{subscription.full_name} to #{subscription.callback_url}.",
                status: :see_other
  rescue Webhooks::MissingPublicUrl, Webhooks::RegistrationError => error
    redirect_to webhook_subscriptions_path, alert: error.message, status: :see_other
  end

  def destroy
    subscription = current_user.webhook_subscriptions.find(params[:id])
    full_name = subscription.full_name
    note = Webhooks::Registrar.new(current_user).unsubscribe(subscription)

    # A note means the row is gone but the hook on GitHub is not, which leaves
    # the person something to do — that is an alert, not a confirmation.
    return redirect_to webhook_subscriptions_path, alert: note, status: :see_other if note

    redirect_to webhook_subscriptions_path,
                notice: "Prism has stopped watching #{full_name} and deleted its webhook.",
                status: :see_other
  end

  private

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
