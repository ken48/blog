# Keep the Obsidian export unchanged; generate Jekyll posts only during builds.
require 'date'
require 'digest'
require 'fileutils'
require 'yaml'

# Read the opening tag-only lines (after optional YAML front matter).
# Stop at the first content line, so headings, links and code are never scanned.
def opening_tags(body)
  tags = []
  body.each_line do |line|
    next if line.strip.empty?
    tokens = line.split
    break unless tokens.all? { |token| token.match?(/\A#[\p{L}\p{M}\p{N}_-]+(?:\/[\p{L}\p{M}\p{N}_-]+)*\z/) && token.match?(/[\p{L}_-]/) }
    tags.concat(tokens.map { |token| token.delete_prefix('#') })
  end
  tags
end

root = File.expand_path('..', __dir__)
source_root = ARGV[0]
abort 'Usage: prepare-posts.rb NOTES_DIRECTORY' unless source_root
source_root = File.expand_path(source_root)
abort "Notes directory not found: #{source_root}" unless File.directory?(source_root)
destination = File.join(root, 'site', '_posts')
FileUtils.rm_rf(destination)
FileUtils.mkdir_p(destination)
count = 0
Dir.glob(File.join(source_root, '*.md')).sort.each do |source|
  name = File.basename(source, '.md')
  match = /\A(\d{4}-\d{2}-\d{2}) (.+)\z/.match(name)
  next unless match

  date, title = match.captures
  Date.iso8601(date) # Fail clearly on an invalid date in a filename.
  body = File.read(source, encoding: 'UTF-8')
  next if body.strip.empty?

  metadata = {}
  if body.start_with?("---\n", "---\r\n")
    parts = body.split(/^---\s*\r?\n/, 3)
    raise "Unclosed front matter: #{name}" unless parts.length == 3
    metadata = YAML.safe_load(parts[1], permitted_classes: [Date, Time]) || {}
    raise "Front matter must be a mapping: #{name}" unless metadata.is_a?(Hash)
    body = parts[2]
  end
  next if metadata['published'] == false
  data = { 'title' => title, 'date' => date, 'tags' => [] }.merge(metadata)
  yaml_tags = data['tags'].is_a?(String) ? data['tags'].split : Array(data['tags'])
  data['tags'] = (yaml_tags + opening_tags(body)).map { |tag| tag.to_s.delete_prefix('#') }.reject(&:empty?).uniq
  # A short hash gives every note a stable, URL-safe identifier independent of content.
  slug = Digest::SHA256.hexdigest(name)[0, 16]
  data['slug'] ||= slug
  File.write(File.join(destination, "#{date}-#{slug}.md"), data.to_yaml + "---\n\n" + body)
  count += 1
end
abort 'No dated notes found' if count.zero?
puts "Prepared #{count} posts"
