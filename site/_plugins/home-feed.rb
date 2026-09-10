require 'time'

# Build the combined feed after Jekyll's post-only paginator has finished.
Jekyll::Hooks.register :site, :pre_render do |site|
  home = site.pages.find { |page| page.data['layout'] == 'home' && page.url == '/' }
  next unless home

  entries = site.posts.docs.reject { |post| post.data['hidden'] }.map do |post|
    post.data.merge('url' => post.url, 'date' => post.date, 'content' => post.content)
  end
  Array(site.data['articles']).each do |article|
    source_page = site.pages.find { |page| page.url == article.fetch('url') }
    raise "Missing article page: #{article['url']}" unless source_page
    entries << source_page.data.merge('url' => source_page.url,
      'date' => Time.iso8601(article.fetch('date')), 'content' => source_page.content)
  end
  entries.sort_by! { |entry| [-entry.fetch('date').to_i, entry.fetch('url')] }
  per_page = [site.config.fetch('paginate', 10).to_i, 1].max
  total = [(entries.size.to_f / per_page).ceil, 1].max
  pattern = site.config.fetch('paginate_path', '/page:num')
  path_for = ->(number) { number == 1 ? '/' : '/' + pattern.sub(':num', number.to_s).gsub(%r{\A/+|/+$}, '') + '/' }

  site.pages.reject! { |page| page != home && page.data['layout'] == 'home' && page.respond_to?(:paginator) && page.paginator }
  (1..total).each do |number|
    page = if number == 1
      home
    else
      path = path_for.call(number)
      generated = Jekyll::PageWithoutAFile.new(site, site.source, path.sub(%r{\A/}, ''), 'index.html')
      generated.content = home.content
      generated.data = home.data.dup
      generated.data['permalink'] = path
      site.pages << generated
      generated
    end
    page.data['feed_posts'] = entries.slice((number - 1) * per_page, per_page) || []
    page.data['feed_page'] = number
    page.data['feed_total_pages'] = total
    page.data['feed_previous'] = number > 1 ? path_for.call(number - 1) : nil
    page.data['feed_next'] = number < total ? path_for.call(number + 1) : nil
  end
end
