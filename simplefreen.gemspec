Gem::Specification.new do |spec|
  spec.name          = "simplefreen"
  spec.version       = File.read(File.expand_path("lib/simplefreen/version.rb", __dir__))[/VERSION = "(.*?)"/, 1]
  spec.authors       = ["Simplefreen contributors"]
  spec.summary       = "SimpleFIN bridge that drives freentonic for bank data scraping"
  spec.description   = <<~DESC
    Simplefreen is a standalone SimpleFIN emulator for Actual Budget and
    other SimpleFIN-compatible clients. It manages bank profiles, stores
    encrypted credentials, schedules syncs, caches results, and exposes
    the SimpleFIN wire protocol — while delegating the actual browser-
    driven scraping to a separate freentonic server it reaches over HTTP.
    Zero runtime gem dependencies.
  DESC
  spec.homepage      = "https://github.com/GermanDZ/simplefreen"
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.files         = Dir[
    "lib/**/*.rb",
    "lib/simplefreen/ui/**/*",
    "bin/simplefreen",
    "docs/**/*.md",
    "README.md",
    "SECURITY.md",
    "LICENSE"
  ]
  spec.bindir        = "bin"
  spec.executables   = ["simplefreen"]
  spec.require_paths = ["lib"]

  spec.metadata = {
    "source_code_uri" => spec.homepage,
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "rubygems_mfa_required" => "true"
  }

  # Runtime dependencies: none. Simplefreen is pure stdlib by design,
  # mirroring freentonic's zero-runtime-deps invariant.
end
