# frozen_string_literal: true

source "https://rubygems.org"

branch = ENV.fetch("SOLIDUS_BRANCH", "v4.7")
git "https://github.com/solidusio/solidus.git", branch: branch do
  gem "solidus_core"
  gem "solidus_backend"
  gem "solidus_api"
  gem "solidus_sample"
end

gem "rails"

# Provides basic authentication functionality for testing parts of the engine.
gem "solidus_auth_devise"

case ENV.fetch("DB", nil)
when "mysql"
  gem "mysql2"
when "postgresql"
  gem "pg"
else
  gem "sqlite3"
end

group :development, :test do
  gem "solidus_dev_support"
end

gemspec

# Use a local Gemfile to include development dependencies that might not be
# relevant for the project or for other contributors, e.g. pry-byebug.
send(:eval_gemfile, "Gemfile-local") if File.exist?("Gemfile-local")
