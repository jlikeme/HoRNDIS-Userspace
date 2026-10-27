# SPDX-License-Identifier: GPL-3.0-or-later
require "cask/cask_loader"
require "tmpdir"

root = Pathname.new(__dir__).parent
source = (root/"Packaging/horndis.rb.in").read
{ "VERSION"=>"0.3.10", "SHA256"=>"0"*64, "URL"=>"https://example.com/horndis.pkg", "PACKAGE"=>"horndis.pkg" }.each do |key, value|
  source = source.gsub("@#{key}@", value.inspect)
end
cask = Cask::CaskLoader.load(source)
artifacts = cask.artifacts_list(uninstall_only: true)
directives = artifacts.flat_map { |value| value.fetch(:uninstall, []) }
script = directives.find { |value| value.key?(:script) }.fetch(:script)
raise "Must select the operation at execution time" unless script[:args] == ["--homebrew"]
raise "Package cleanup is missing" unless directives.any? { |value| value[:pkgutil] == "io.github.noahhhi.horndis.pkg" }

# Test the real installed-metadata loader with explicit artifact overrides. This
# must override the legacy receipt's unconditional uninstall script too.
Dir.mktmpdir("horndis-cask-loader-") do |directory|
  original_path = Cask::Caskroom.path
  Cask::Caskroom.instance_variable_set(:@path, Pathname.new(directory))
  path = Pathname.new(directory)/"horndis/.metadata/0.3.9/20261001000000/Casks/horndis.json"
  path.dirname.mkpath
  definition = { "version" => "0.3.9", "artifacts" => [{ "uninstall" => [{
    "script" => { "executable" => "/tmp/reviewed/horndis-uninstall", "args" => ["--keep-network-service"], "sudo" => true },
    "pkgutil" => "io.github.noahhhi.horndis.pkg",
  }] }] }
  path.write(JSON.generate(definition))
  receipt = path.dirname.parent.parent.parent/"INSTALL_RECEIPT.json"
  receipt.write(JSON.generate({"homebrew_version"=>HOMEBREW_VERSION,"uninstall_flight_blocks"=>false,
    "source"=>{"tap"=>"noahhhi/tap","version"=>"0.3.9"},"uninstall_artifacts"=>definition["artifacts"]}))
  loaded = Cask::CaskLoader.load_from_installed_caskfile(path, api_fallback: false)
  args = loaded.artifacts_list(uninstall_only: true).flat_map { |value| value.fetch(:uninstall, []) }
  actual = args.find { |value| value.key?(:script) }.fetch(:script)
  raise "Legacy receipt overrides the preservation adapter" unless actual[:args] == ["--keep-network-service"]
ensure
  Cask::Caskroom.instance_variable_set(:@path, original_path)
end
puts "Homebrew cask schema, runtime-mode argument and legacy metadata override passed"
