require_relative "boot"

require "rails"
# Pick the frameworks you want:
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
# require "active_storage/engine"
require "action_controller/railtie"
# require "action_mailer/railtie"
# require "action_mailbox/engine"
# require "action_text/engine"
require "action_view/railtie"
require "action_cable/engine"
require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module PrismApp
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    config.time_zone = "Pacific Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    # Active Record Encryption protects users.access_token — a GitHub OAuth
    # token with the `repo` scope, which is the most sensitive thing Prism
    # stores. Keys come from the environment so Docker and CI work without a
    # shared config/master.key (which is gitignored, as Rails intends), and fall
    # back to credentials when the environment is silent. Generate a set with
    # `bin/rails db:encryption:init`; dev values are in .env.example.
    if ENV["AR_ENCRYPTION_PRIMARY_KEY"].present?
      config.active_record.encryption.primary_key = ENV["AR_ENCRYPTION_PRIMARY_KEY"]
      config.active_record.encryption.deterministic_key = ENV["AR_ENCRYPTION_DETERMINISTIC_KEY"]
      config.active_record.encryption.key_derivation_salt = ENV["AR_ENCRYPTION_KEY_DERIVATION_SALT"]
    end
  end
end
