# Prepare notes and articles from public Git repositories for Jekyll.
require 'cgi'
require 'date'
require 'fileutils'
require 'open3'
require 'optparse'
require 'pathname'
require 'time'
require 'tmpdir'
require 'uri'
require 'yaml'

ROOT = Pathname.new(__dir__).parent
REPOSITORY_PATTERN = /\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/
CONTENT_FILENAME_PATTERN = /\A(\d{4}-\d{2}-\d{2}) ([A-Za-z0-9](?:[A-Za-z0-9 -]*[A-Za-z0-9])?)\.md\z/
TAG_PATTERN = /\A#[\p{L}\p{M}\p{N}_-]+(?:\/[\p{L}\p{M}\p{N}_-]+)*\z/

def read_utf8(path)
  path.read(encoding: 'bom|utf-8')
end

def split_front_matter(text, label)
  return [{}, text] unless text.start_with?("---\n", "---\r\n")

  parts = text.split(/^---[ \t]*\r?\n/, 3)
  raise "Unclosed front matter: #{label}" unless parts.length == 3

  metadata = YAML.safe_load(parts[1], permitted_classes: [Date, Time], aliases: false) || {}
  raise "Front matter must be a mapping: #{label}" unless metadata.is_a?(Hash)

  [metadata.transform_keys(&:to_s), parts[2]]
end

def extract_heading(body, label)
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

    title = heading[1].strip
    raise "Empty level-one heading in #{label}" if title.empty?
    if title.match?(/\A\d{4}-\d{2}-\d{2}[ \t]+/)
      raise "The level-one heading must contain only the title in #{label}; the date comes from the filename"
    end

    lines.delete_at(index)
    return [title, lines.join]
  end

  raise "Missing '# Title' in #{label}"
end

def content_identity(path, label)
  filename = path.basename.to_s
  match = filename.match(CONTENT_FILENAME_PATTERN)
  unless match
    parts = filename.match(/\A\d{4}-\d{2}-\d{2} (.+)\.md\z/)
    if parts
      invalid = parts[1].each_char.reject { |character| character.match?(/[A-Za-z0-9 -]/) }.uniq
      unless invalid.empty?
        details = invalid.map { |character| "#{character.inspect} (U+#{character.ord.to_s(16).upcase.rjust(4, '0')})" }.join(', ')
        raise "Invalid filename in #{label}: #{filename}. " \
              "After the date, use only Latin letters, digits, spaces, and hyphens. " \
              "Unsupported characters: #{details}."
      end
    end

    raise "Invalid filename in #{label}: #{filename}. Expected 'YYYY-MM-DD English name.md'."
  end

  date, = match.captures
  begin
    Date.iso8601(date)
  rescue Date::Error
    raise "Invalid date #{date} in #{label}"
  end

  slug = path.basename('.md').to_s.gsub(/[ -]+/, '-').downcase
  [date, slug]
end

def tag_tokens(line)
  tokens = line.split
  return nil if tokens.empty? || !tokens.all? { |token| token.match?(TAG_PATTERN) && token.match?(/[\p{L}_-]/) }

  tokens.map { |token| token.delete_prefix('#') }
end

def extract_boundary_tags(body)
  lines = body.lines
  tags = []

  index = 0
  index += 1 while index < lines.length && lines[index].strip.empty?
  while index < lines.length && (tokens = tag_tokens(lines[index]))
    tags.concat(tokens)
    lines.delete_at(index)
    index += 1 while index < lines.length && lines[index].strip.empty?
  end

  index = lines.length - 1
  index -= 1 while index >= 0 && lines[index].strip.empty?
  trailing = []
  while index >= 0 && (tokens = tag_tokens(lines[index]))
    trailing.unshift(*tokens)
    lines.delete_at(index)
    index -= 1
    index -= 1 while index >= 0 && lines[index].strip.empty?
  end

  [tags + trailing, lines.join]
end

def normalize_tags(value)
  values = value.is_a?(String) ? value.split : Array(value)
  values.map { |tag| tag.to_s.delete_prefix('#') }.reject(&:empty?)
end

def render_document(data, body)
  data.to_yaml + "---\n\n" + body.lstrip
end

def run_command(*command)
  output, error, status = Open3.capture3(*command)
  raise "Command failed: #{command.join(' ')}\n#{error}" unless status.success?

  output
end

def clone_repository(repository, destination)
  run_command('git', 'clone', '--depth', '1', '--', "https://github.com/#{repository}.git", destination.to_s)
end

def repository_checkout(repository, temporary)
  name = repository.split('/').last
  destination = temporary.join(name)
  clone_repository(repository, destination)
  destination
end

def relative_publication_url(from_url, to_url)
  from = Pathname.new(from_url.sub(%r{\A/+|/+\z}, ''))
  to = Pathname.new(to_url.sub(%r{\A/+|/+\z}, ''))
  return './' if from == to

  path = to.relative_path_from(from).to_s
  path = "./#{path}" unless path.start_with?('../')
  "#{path}/"
end

def rewrite_publication_links(body, document, current_url, url_map)
  chunks = body.split(/(^[ \t]*```[^\n]*\n.*?^[ \t]*```[ \t]*$|^[ \t]*~~~[^\n]*\n.*?^[ \t]*~~~[ \t]*$|`+[^`\n]*`+)/m)
  chunks.each_with_index do |chunk, index|
    next if index.odd?

    chunk = chunk.gsub(/(?<!!)\[([^\]\n]*)\]\(([^\s()]+)\)/) do
      whole = Regexp.last_match(0)
      label = Regexp.last_match(1)
      value = Regexp.last_match(2)
      match = value.match(/\A([^?#]+\.md)([?#].*)?\z/i)
      next whole unless match

      path, suffix = match.captures
      next whole if path.start_with?('//') || path.match?(/\A[A-Za-z][A-Za-z0-9+.-]*:/)

      target = document.dirname.join(URI::DEFAULT_PARSER.unescape(path)).cleanpath
      target_url = url_map[target.expand_path.to_s]
      raise "Local publication is not published from #{document}: #{value}" unless target_url

      "[#{label}](#{relative_publication_url(current_url, target_url)}#{suffix})"
    end
    chunks[index] = chunk
  end
  chunks.join
end

def prepare_posts(source, output, url_map)
  count = 0
  slugs = {}
  source.glob('*.md').sort.each do |path|
    text = read_utf8(path)
    next if text.strip.empty?

    metadata, body = split_front_matter(text, path.basename.to_s)
    next if metadata['published'] == false

    date, slug = content_identity(path, 'post repository')
    title, body = extract_heading(body, path.basename.to_s)
    previous = slugs[slug]
    raise "Duplicate post address #{slug}: #{previous} and #{path.basename}" if previous
    slugs[slug] = path.basename

    inline_tags, body = extract_boundary_tags(body)
    data = { 'layout' => 'post', 'tags' => [] }.merge(metadata)
    data['title'] = title
    data['date'] = date
    data['tags'] = (normalize_tags(data['tags']) + inline_tags).uniq
    data['permalink'] = "/posts/#{slug}/"
    body = rewrite_publication_links(body, path, data['permalink'], url_map)
    output.join("#{slug}.md").write(render_document(data, body), encoding: 'UTF-8')
    count += 1
  end

  raise 'No publishable notes found' if count.zero?

  count
end

def quote_path(path)
  path.split('/').map { |part| CGI.escape(part).gsub('+', '%20') }.join('/')
end

def article_document(checkout, repository)
  documents = checkout.children.select do |path|
    path.file? && path.basename.to_s.match?(CONTENT_FILENAME_PATTERN)
  end
  raise "Expected one root 'YYYY-MM-DD name.md' in #{repository}" unless documents.length == 1

  documents.first
end

def import_article(repository, checkout, document, slug, posts_output, assets_output, url_map)
  label = document.relative_path_from(checkout).to_s
  metadata, body = split_front_matter(read_utf8(document), label)
  date_text, = content_identity(document, label)
  title, body = extract_heading(body, label)
  inline_tags, body = extract_boundary_tags(body)
  tags = (normalize_tags(metadata['tags']) + inline_tags).uniq
  article_date = Date.iso8601(date_text)
  date = Time.new(article_date.year, article_date.month, article_date.day, 0, 0, 0, '+03:00').iso8601
  revision = run_command('git', '-C', checkout.to_s, 'rev-parse', 'HEAD').strip
  article_assets = assets_output.join(slug)
  article_assets.mkpath
  copied = {}
  checkout_root = checkout.realpath

  resolve_url = lambda do |value, image|
    value = CGI.unescapeHTML(value)
    begin
      uri = URI.parse(value)
    rescue URI::InvalidURIError
      next value
    end
    next value if uri.scheme || uri.host || uri.path.nil? || uri.path.empty?
    next value if !image && File.extname(uri.path).downcase == '.md'

    relative = URI::DEFAULT_PARSER.unescape(uri.path).sub(%r{\A/+}, '')
    local = document.dirname.join(relative).cleanpath
    raise "Missing local file in #{repository}: #{value}" unless local.file?

    resolved = local.realpath
    prefix = checkout_root.to_s + File::SEPARATOR
    unless resolved.to_s == checkout_root.to_s || resolved.to_s.start_with?(prefix)
      raise "Path outside repository: #{value}"
    end

    suffix = (uri.query ? "?#{uri.query}" : '') + (uri.fragment ? "##{uri.fragment}" : '')
    if image
      target = article_assets.join(relative)
      target.dirname.mkpath
      FileUtils.cp(resolved, target)
      copied[relative] = true
      next quote_path(relative) + suffix
    end

    next './' + (uri.fragment ? "##{uri.fragment}" : '') if resolved == document.realpath

    "https://github.com/#{repository}/blob/#{revision}/#{quote_path(relative)}#{suffix}"
  end

  chunks = body.split(/(^[ \t]*```[^\n]*\n.*?^[ \t]*```[ \t]*$|^[ \t]*~~~[^\n]*\n.*?^[ \t]*~~~[ \t]*$|`+[^`\n]*`+)/m)
  chunks.each_with_index do |chunk, index|
    next if index.odd?

    chunk = chunk.gsub(/<(?:img|a)\b[^>]*>/i) do |tag|
      image = tag.match?(/\A<img\b/i)
      tag = tag.gsub(/\b(src|href)\s*=\s*(["'])(.*?)\2/i) do
        name = Regexp.last_match(1)
        quote = Regexp.last_match(2)
        original = Regexp.last_match(3)
        resolved = resolve_url.call(original, image && name.downcase == 'src')
        "#{name}=#{quote}#{CGI.escapeHTML(resolved)}#{quote}"
      end
      if image && !tag.match?(/\balt\s*=/i)
        tag = tag.sub(/\s*\/?>\z/) { |ending| " alt=\"\"#{ending}" }
      end
      tag
    end
    chunk = chunk.gsub(/(!?\[[^\]\n]*\])\(([^\s()]+)\)/) do
      label = Regexp.last_match(1)
      value = Regexp.last_match(2)
      "#{label}(#{resolve_url.call(value, label.start_with?('!'))})"
    end
    chunks[index] = chunk
  end
  body = chunks.join

  data = metadata.merge(
    'layout' => 'post',
    'article' => true,
    'permalink' => "/articles/#{slug}/",
    'media_subpath' => "/articles/#{slug}",
    'title' => title,
    'date' => date,
    'tags' => tags,
    'toc' => true,
    'render_with_liquid' => false
  )
  body = rewrite_publication_links(body, document, data['permalink'], url_map)
  posts_output.join("#{slug}-article.md").write(render_document(data, body), encoding: 'UTF-8')
  copied.length
end

def replace_directory(source, destination)
  FileUtils.rm_rf(destination)
  FileUtils.cp_r(source, destination)
end

options = {}
OptionParser.new do |parser|
  parser.on('--repository-dir DIRECTORY') { |value| options[:repository_dir] = Pathname.new(value).expand_path }
end.parse!

config = YAML.safe_load(ROOT.join('content-sources.yml').read, aliases: false)
repository = config.fetch('repository')
raise "Invalid GitHub repository: #{repository}" unless repository.match?(REPOSITORY_PATTERN)
Dir.mktmpdir do |temporary_name|
  temporary = Pathname.new(temporary_name)
  generated = temporary.join('generated')
  posts_output = generated.join('_posts')
  assets_output = generated.join('articles')
  posts_output.mkpath
  assets_output.mkpath

  checkout = options[:repository_dir] || repository_checkout(repository, temporary)
  posts_source = checkout.join(config.fetch('posts'))
  articles_source = checkout.join(config.fetch('articles'))
  raise "Posts directory not found: #{posts_source}" unless posts_source.directory?
  raise "Articles directory not found: #{articles_source}" unless articles_source.directory?

  post_inputs = posts_source.glob('*.md').each_with_object([]) do |document, inputs|
    text = read_utf8(document)
    next if text.strip.empty?
    metadata, = split_front_matter(text, document.basename.to_s)
    next if metadata['published'] == false
    _, slug = content_identity(document, 'post repository')
    inputs << [document, slug]
  end
  article_inputs = articles_source.children.select(&:directory?).sort.map do |article_checkout|
    document = article_document(article_checkout, article_checkout.relative_path_from(checkout).to_s)
    _, slug = content_identity(document, article_checkout.relative_path_from(checkout).to_s)
    [document, slug]
  end
  article_slugs = article_inputs.map(&:last)
  raise 'Duplicate article address' unless article_slugs.uniq.length == article_slugs.length
  url_map = {}
  post_inputs.each { |document, slug| url_map[document.expand_path.to_s] = "/posts/#{slug}/" }
  article_inputs.each { |document, slug| url_map[document.expand_path.to_s] = "/articles/#{slug}/" }

  post_count = prepare_posts(posts_source, posts_output, url_map)
  puts "Prepared #{post_count} posts"

  article_inputs.each do |document, slug|
    image_count = import_article(repository, checkout, document, slug, posts_output, assets_output, url_map)
    puts "Imported #{document.relative_path_from(checkout)}: #{image_count} images"
  end

  replace_directory(posts_output, ROOT.join('site', '_posts'))
  replace_directory(assets_output, ROOT.join('site', 'articles'))
  puts "Prepared #{article_inputs.length} articles"
end
