# Keep the Obsidian export unchanged; generate Jekyll posts only during builds.
require 'date'
require 'digest'
require 'fileutils'
require 'yaml'

root = File.expand_path('..', __dir__)
destination = File.join(root, 'site', '_posts')
FileUtils.rm_rf(destination)
FileUtils.mkdir_p(destination)
count = 0
Dir.glob(File.join(root, '*.md')).sort.each do |source|
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
  # A short hash gives every note a stable, URL-safe identifier independent of content.
  slug = Digest::SHA256.hexdigest(name)[0, 16]
  data['slug'] ||= slug
  File.write(File.join(destination, "#{date}-#{slug}.md"), data.to_yaml + "---\n\n" + body)
  count += 1
end
abort 'No dated notes found' if count.zero?
puts "Prepared #{count} posts"
