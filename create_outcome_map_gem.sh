#!/usr/bin/env bash
set -euo pipefail

# create_outcome_map_gem.sh
# Creates the outcome_map gem skeleton files in the current directory.
# Usage:
#   1) cd to the repository root (or folder where you want files created)
#   2) chmod +x create_outcome_map_gem.sh
#   3) ./create_outcome_map_gem.sh
#
# After running the script:
#   - Run `bundle install`
#   - Make bin/outcome_map executable if needed (script does this)
#   - Run example build: bin/outcome_map build "sample/fixture_resultado_geral.csv" --out-dir ./dist --base-url "https://<your>.github.io/<repo>/"
#
# NOTE: Edit author/email and any repo-specific values in outcome_map.gemspec and README.md before committing.

# Create directories
mkdir -p bin lib/outcome_map templates spec sample .github/workflows

# outcome_map.gemspec
cat > outcome_map.gemspec <<'RUBY'
Gem::Specification.new do |s|
  s.name        = "outcome_map"
  s.version     = "0.1.0"
  s.summary     = "Gerador de site estático de outcome map a partir de CSV"
  s.description = "Lê o CSV 'Resultado Geral', agrega outcomes por padrão e gera ./dist pronto para GitHub Pages."
  s.authors     = ["angelica-cavalheiro"]
  s.email       = "you@example.com"
  s.license     = "MIT"
  s.files       = Dir["lib/**/*", "bin/*", "templates/**/*", "README.md", "Rakefile", "sample/**/*", "spec/**/*", ".github/workflows/*"]
  s.executables = ["outcome_map"]
  s.required_ruby_version = ">= 2.7.0"

  s.add_runtime_dependency "thor", "~> 1.2"
  s.add_runtime_dependency "json"
  s.add_development_dependency "rspec", "~> 3.0"
end
RUBY

# Gemfile
cat > Gemfile <<'GEMFILE'
source "https://rubygems.org"

gemspec

group :development do
  gem "rake"
  gem "rspec"
end
GEMFILE

# Rakefile
cat > Rakefile <<'RAKE'
require "rake"
require "rspec/core/rake_task"

task default: :spec

RSpec::Core::RakeTask.new(:spec) do |t|
  t.rspec_opts = "--format documentation"
end
RAKE

# bin/outcome_map
cat > bin/outcome_map <<'BASH'
#!/usr/bin/env ruby
# frozen_string_literal: true
require "bundler/setup"
require "outcome_map"

OutcomeMap::CLI.start(ARGV)
BASH
chmod +x bin/outcome_map

# lib/outcome_map.rb
cat > lib/outcome_map.rb <<'RUBY'
# frozen_string_literal: true
require "thor"
require "json"
require "csv"
require "webrick"
require_relative "outcome_map/version"
require_relative "outcome_map/cli"
require_relative "outcome_map/parser"
require_relative "outcome_map/generator"

module OutcomeMap
  class Error < StandardError; end
end
RUBY

# lib/outcome_map/version.rb
cat > lib/outcome_map/version.rb <<'RUBY'
# frozen_string_literal: true
module OutcomeMap
  VERSION = "0.1.0"
end
RUBY

# lib/outcome_map/cli.rb
cat > lib/outcome_map/cli.rb <<'RUBY'
# frozen_string_literal: true
require "thor"

module OutcomeMap
  class CLI < Thor
    desc "build INPUT_CSV", "Build site assets from INPUT_CSV"
    option :out_dir,       type: :string,  default: "./dist", desc: "Output directory"
    option :base_url,      type: :string,  default: nil,      desc: "Base URL for site (optional)"
    option :encoding,      type: :string,  default: "auto",   desc: "File encoding (auto|utf-8|iso-8859-1)"
    option :decimal_sep,   type: :string,  default: ",",      desc: "Decimal separator in CSV (',' or '.')"
    option :no_aggregate,  type: :boolean, default: false,    desc: "Do not aggregate duplicates"
    option :agg_method,    type: :string,  default: "average", desc: "Aggregation method: average|median|first|max|min"
    def build(input_csv)
      say "Building site from #{input_csv} ..."
      parser_opts = {
        encoding: options[:encoding],
        decimal_sep: options[:decimal_sep],
        aggregate: !options[:no_aggregate],
        agg_method: options[:agg_method]
      }
      data = OutcomeMap::Parser.parse(input_csv, parser_opts)
      gen_opts = {
        out_dir: options[:out_dir],
        base_url: options[:base_url]
      }
      OutcomeMap::Generator.generate(data, gen_opts)
      say "Build complete. Output in #{options[:out_dir]}"
    rescue StandardError => e
      warn "Error: #{e.message}"
      exit 1
    end

    desc "serve", "Serve a directory (default ./dist) on a local HTTP server"
    option :dir, type: :string, default: "./dist"
    option :port, type: :numeric, default: 4000
    def serve
      dir = options[:dir]
      port = options[:port]
      unless Dir.exist?(dir)
        warn "Directory #{dir} not found. Run build first."
        exit 1
      end
      say "Serving #{dir} at http://localhost:#{port}"
      server = WEBrick::HTTPServer.new(Port: port, DocumentRoot: File.expand_path(dir))
      trap("INT") { server.shutdown }
      server.start
    end

    desc "deploy", "Helper: print instructions for deploying to GitHub Pages"
    option :repo, type: :string, required: false, desc: "owner/repo for deploy"
    def deploy
      say "Deploy helper: recommended approach is to use the included .github/workflows/deploy.yml"
      say "You can also publish ./dist with peaceiris/actions-gh-pages or push to gh-pages branch manually."
      say "Example local steps:"
      say "  git checkout --orphan gh-pages"
      say "  git --work-tree dist add --all"
      say "  git --work-tree dist commit -m 'Publish site'"
      say "  git push origin HEAD:gh-pages --force"
    end
  end
end
RUBY

# lib/outcome_map/parser.rb
cat > lib/outcome_map/parser.rb <<'RUBY'
# frozen_string_literal: true
require "csv"
require "json"
require "time"

module OutcomeMap
  class Parser
    # entry:
    # parse(file_path, options: { encoding: "auto", decimal_sep: ",", aggregate: true, agg_method: "average" })
    def self.parse(path, opts = {})
      opts = { encoding: "auto", decimal_sep: ",", aggregate: true, agg_method: "average" }.merge(opts || {})
      content = read_file_with_encoding(path, opts[:encoding])
      csv = CSV.new(content, headers: true, liberal_parsing: true)
      rows = []
      csv.each do |row|
        next if row.nil? || row.headers.nil?
        normalized = normalize_row(row)
        rows << normalized
      end
      if rows.empty?
        raise "No data parsed from #{path}"
      end
      grouped = if opts[:aggregate]
                  aggregate_rows(rows, opts[:agg_method])
                else
                  rows
                end
      build_output(grouped, path)
    end

    def self.read_file_with_encoding(path, encoding)
      raw = File.binread(path)
      return StringIO.new(raw.encode("UTF-8")) if encoding && encoding.downcase != "iso-8859-1" && raw.valid_encoding?

      # Try UTF-8 first, then ISO-8859-1
      begin
        StringIO.new(raw.force_encoding("UTF-8").encode("UTF-8"))
      rescue Encoding::UndefinedConversionError, Encoding::InvalidByteSequenceError
        StringIO.new(raw.force_encoding("ISO-8859-1").encode("UTF-8"))
      end
    end
    private_class_method :read_file_with_encoding

    def self.normalize_row(row)
      h = {}
      # Normalize header keys to ascii downcased words
      row.each do |k, v|
        key = k.to_s.strip.downcase
        key = key.gsub(/[^\p{Alnum}\s_-]/, "") # remove accents from header names rough
        key = key.gsub(/\s+/, " ")
        key = key.strip
        h[key] = v.nil? ? "" : v.to_s.strip
      end

      # Map known headers
      focus = h.find { |kk, _| kk.match?(/^focus/) }&.last || h["focus job"] || h["focusjob"] || h["focus"]
      outcomes = h.find { |kk, _| kk.match?(/outcom/) }&.last || h["outcomes"] || h["outcome"]
      score_s = h.find { |kk, _| kk.match?(/score/) }&.last || h["score"]
      importancia_s = h.find { |kk, _| kk.match?(/import/) }&.last || h["importância"] || h["importancia"]
      satisfacao_s = h.find { |
