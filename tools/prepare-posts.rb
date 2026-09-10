# Keep the Obsidian export unchanged; generate Jekyll posts only during builds.
require 'date'
require 'digest'
require 'fileutils'
require 'yaml'

# Read tag-only lines at the beginning and end of a note.
# Content in between is never scanned, so prose, headings, links and code are safe.
def boundary_tags(body)
  tags = []
  lines = body.lines

  [lines, lines.reverse].each do |edge|
    edge.each do |line|
      next if line.strip.empty?
      tokens = line.split
      break unless tokens.all? { |token| token.match?(/\A#[\p{L}\p{M}\p{N}_-]+(?:\/[\p{L}\p{M}\p{N}_-]+)*\z/) && token.match?(/[\p{L}_-]/) }
      tags.concat(tokens.map { |token| token.delete_prefix('#') })
    end
  end

  tags
end

# Read and remove the first level-one heading outside fenced code.
# Notes use the same heading format as imported articles.
def extract_heading(body, name)
  lines = body.lines
  fence_character = nil
  fence_length = 0

  lines.each_with_index do |line, index|
    stripped = line.lstrip
    if fence_character
      closing_fence = /\A#{Regexp.escape(fence_character)}{#{fence_length},}[ \t]*(?:\r?\n)?\z/
      if stripped.match?(closing_fence)
        fence_character = nil
        fence_length = 0
      end
      next
    end

    if (fence = stripped.match(/\A(`{3,}|~{3,})/))
      fence_character = fence[1][0]
      fence_length = fence[1].length
      next
    end

    heading = line.match(/\A#[ \t]+(.+?)[ \t]*(?:\r?\n)?\z/)
    next unless heading

    dated_title = heading[1].match(/\A(\d{4}-\d{2}-\d{2})[ \t]+(.+)\z/)
    raise "Expected '# YYYY-MM-DD Title' in #{name}" unless dated_title

    date, title = dated_title.captures
    begin
      Date.iso8601(date)
    rescue Date::Error
      raise "Invalid date #{date} in #{name}"
    end
    lines.delete_at(index)
    return [date, title.strip, lines.join]
  end

  raise "Missing '# YYYY-MM-DD Title' in #{name}"
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
  date, title, body = extract_heading(body, name)
  data = { 'tags' => [] }.merge(metadata).merge('title' => title, 'date' => date)
  yaml_tags = data['tags'].is_a?(String) ? data['tags'].split : Array(data['tags'])
  data['tags'] = (yaml_tags + boundary_tags(body)).map { |tag| tag.to_s.delete_prefix('#') }.reject(&:empty?).uniq
  # A short hash gives every note a stable, URL-safe identifier independent of content.
  slug = Digest::SHA256.hexdigest(name)[0, 16]
  data['slug'] ||= slug
  File.write(File.join(destination, "#{date}-#{slug}.md"), data.to_yaml + "---\n\n" + body)
  count += 1
end
abort 'No publishable notes found' if count.zero?
puts "Prepared #{count} posts"
