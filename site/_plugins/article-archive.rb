require 'time'

Jekyll::Hooks.register :site, :pre_render do |site|
  entries = site.posts.docs.map do |post|
    { 'title' => post.data['title'], 'url' => post.url, 'date' => post.date }
  end
  Array(site.data['articles']).each do |article|
    entries << article.merge('date' => Time.iso8601(article.fetch('date')))
  end
  site.data['archive_entries'] = entries.sort_by { |entry| entry.fetch('date').to_i }.reverse
end
