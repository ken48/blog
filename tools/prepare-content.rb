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
SLUG_PATTERN = /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/
POST_FILENAME_PATTERN = /\A(\d{4}-\d{2}-\d{2}) ([a-z0-9]+(?:-[a-z0-9]+)*)\.md\z/
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

    dated_title = heading[1].match(/\A(\d{4}-\d{2}-\d{2})[ \t]+(.+)\z/)
    raise "Expected '# YYYY-MM-DD Title' in #{label}" unless dated_title

    date, title = dated_title.captures
    begin
      Date.iso8601(date)
    rescue Date::Error
      raise "Invalid date #{date} in #{label}"
    end
    lines.delete_at(index)
    return [date, title.strip, lines.join]
  end

  raise "Missing '# YYYY-MM-DD Title' in #{label}"
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

def repository_checkout(repository, temporary, sources_dir)
  name = repository.split('/').last
  return sources_dir.join(name) if sources_dir

  destination = temporary.join(name)
  clone_repository(repository, destination)
  destination
end

def prepare_posts(source, output)
  count = 0
  slugs = {}
  source.glob('*.md').sort.each do |path|
    text = read_utf8(path)
    next if text.strip.empty?

    metadata, body = split_front_matter(text, path.basename.to_s)
    next if metadata['published'] == false

    date, title, body = extract_heading(body, path.basename.to_s)
    filename = path.basename.to_s.match(POST_FILENAME_PATTERN)
    unless filename
      raise "Expected 'YYYY-MM-DD english-unique-name.md': #{path.basename}"
    end
    filename_date, slug = filename.captures
    raise "Date in filename and heading differs: #{path.basename}" unless filename_date == date
    previous = slugs[slug]
    raise "Duplicate post name #{slug}: #{previous} and #{path.basename}" if previous
    slugs[slug] = path.basename

    inline_tags, body = extract_boundary_tags(body)
    data = { 'layout' => 'post', 'tags' => [] }.merge(metadata)
    data['title'] = title
    data['date'] = date
    data['tags'] = (normalize_tags(data['tags']) + inline_tags).uniq
    data['permalink'] = "/posts/#{slug}/"
    output.join("#{date}-#{slug}.md").write(render_document(data, body), encoding: 'UTF-8')
    count += 1
  end

  raise 'No publishable notes found' if count.zero?

  count
end

def article_link(value, article_links)
  uri = URI.parse(value)
  return value unless %w[http https].include?(uri.scheme) && uri.host&.downcase == 'github.com'

  repository = uri.path.sub(%r{\A/+|/+$}, '').sub(/\.git\z/, '')
  slug = article_links[repository.downcase]
  return value unless slug

  fragment = uri.fragment&.downcase == 'readme' ? nil : uri.fragment
  "../#{slug}/" + (uri.query ? "?#{uri.query}" : '') + (fragment ? "##{fragment}" : '')
rescue URI::InvalidURIError
  value
end

def quote_path(path)
  path.split('/').map { |part| CGI.escape(part).gsub('+', '%20') }.join('/')
end

def import_article(source, checkout, posts_output, assets_output, article_links)
  readmes = checkout.children.select { |path| path.file? && path.basename.to_s.downcase == 'readme.md' }
  raise "Expected one root README.md in #{source.fetch('repo')}" unless readmes.length == 1

  readme = readmes.first
  metadata, body = split_front_matter(read_utf8(readme), source.fetch('repo'))
  date_text, title, body = extract_heading(body, source.fetch('repo'))
  inline_tags, body = extract_boundary_tags(body)
  tags = (normalize_tags(metadata['tags']) + inline_tags).uniq
  article_date = Date.iso8601(date_text)
  date = Time.new(article_date.year, article_date.month, article_date.day, 0, 0, 0, '+03:00').iso8601
  revision = run_command('git', '-C', checkout.to_s, 'rev-parse', 'HEAD').strip
  slug = source.fetch('slug')
  article_assets = assets_output.join(slug)
  article_assets.mkpath
  copied = {}
  checkout_root = checkout.realpath

  resolve_url = lambda do |value, image|
    value = CGI.unescapeHTML(value)
    converted = article_link(value, article_links) unless image
    next converted if converted && converted != value

    begin
      uri = URI.parse(value)
    rescue URI::InvalidURIError
      next value
    end
    next value if uri.scheme || uri.host || uri.path.nil? || uri.path.empty?

    relative = URI::DEFAULT_PARSER.unescape(uri.path).sub(%r{\A/+}, '')
    local = checkout.join(relative).cleanpath
    raise "Missing local file in #{source.fetch('repo')}: #{value}" unless local.file?

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

    next './' + (uri.fragment ? "##{uri.fragment}" : '') if resolved == readme.realpath

    "https://github.com/#{source.fetch('repo')}/blob/#{revision}/#{quote_path(relative)}#{suffix}"
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
  posts_output.join("#{date_text}-article-#{slug}.md").write(render_document(data, body), encoding: 'UTF-8')
  copied.length
end

def replace_directory(source, destination)
  FileUtils.rm_rf(destination)
  FileUtils.cp_r(source, destination)
end

options = {}
OptionParser.new do |parser|
  parser.on('--sources-dir DIRECTORY') { |value| options[:sources_dir] = Pathname.new(value).expand_path }
  parser.on('--posts-dir DIRECTORY') { |value| options[:posts_dir] = Pathname.new(value).expand_path }
end.parse!

config = YAML.safe_load(ROOT.join('content-sources.yml').read, aliases: false)
posts_source = config.fetch('posts')
articles = config.fetch('articles')
repositories = [posts_source, *articles]
repositories.each do |source|
  repository = source.fetch('repo')
  raise "Invalid GitHub repository: #{repository}" unless repository.match?(REPOSITORY_PATTERN)
end
slugs = articles.map { |source| source.fetch('slug') }
raise 'Invalid article slug' unless slugs.all? { |slug| slug.match?(SLUG_PATTERN) }
raise 'Duplicate article slug' unless slugs.uniq.length == slugs.length
article_links = articles.to_h { |source| [source.fetch('repo').downcase, source.fetch('slug')] }

Dir.mktmpdir do |temporary_name|
  temporary = Pathname.new(temporary_name)
  generated = temporary.join('generated')
  posts_output = generated.join('_posts')
  assets_output = generated.join('articles')
  posts_output.mkpath
  assets_output.mkpath

  posts_checkout = options[:posts_dir] || repository_checkout(posts_source.fetch('repo'), temporary, options[:sources_dir])
  post_count = prepare_posts(posts_checkout, posts_output)
  puts "Prepared #{post_count} posts"

  articles.each do |source|
    checkout = repository_checkout(source.fetch('repo'), temporary, options[:sources_dir])
    image_count = import_article(source, checkout, posts_output, assets_output, article_links)
    puts "Imported #{source.fetch('repo')}: #{image_count} images"
  end

  replace_directory(posts_output, ROOT.join('site', '_posts'))
  replace_directory(assets_output, ROOT.join('site', 'articles'))
  puts "Prepared #{articles.length} articles"
end
