# frozen_string_literal: true

lib = File.expand_path("lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "solidus_numeral/version"

Gem::Specification.new do |spec|
  spec.name = "solidus_numeral"
  spec.version = SolidusNumeral::VERSION
  spec.authors = ["Numeral"]
  spec.email = ["support@numeralhq.com"]

  spec.summary = "Numeral sales tax calculation, reporting, and filing for Solidus"
  spec.description = "Official Numeral (numeralhq.com) extension for Solidus. " \
    "Provides live tax calculation at checkout via Numeral's tax engine, " \
    "records completed orders to Numeral's transaction ledger for filing, and " \
    "reports refunds and cancellations."
  spec.homepage = "https://www.numeralhq.com"
  spec.license = "MIT"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["documentation_uri"] = "https://docs.numeral.com/integrations/solidus"
  spec.metadata["source_code_uri"] = "https://github.com/NumeralHQ/solidus_numeral"
  spec.metadata["bug_tracker_uri"] = "https://github.com/NumeralHQ/solidus_numeral/issues"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.required_ruby_version = ">= 3.2"

  spec.files = Dir["{app,config,db,lib}/**/*", "LICENSE", "Rakefile", "README.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency "solidus_core", [">= 4.6", "< 5"]
  spec.add_dependency "solidus_support", ">= 0.12"

  spec.add_development_dependency "rake"
  spec.add_development_dependency "rspec-rails"
  spec.add_development_dependency "solidus_dev_support"
  spec.add_development_dependency "webmock"
end
