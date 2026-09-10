require 'nokogiri'

module StaticToc
  def self.render(item)
    return unless item.output_ext == '.html' && item.site.config['toc'] && item.data['toc']
    doc = Nokogiri::HTML.parse(item.output)
    content = doc.at_css('main article .content')
    target = doc.at_css('[data-static-toc]')
    return unless content && target
    headings = content.css('h2[id], h3[id], h4[id]').reject { |h| h.key?('data-toc-skip') }
    return if headings.empty?

    root = Nokogiri::XML::Node.new('ul', doc)
    stack = []
    headings.each do |heading|
      level = heading.name[1].to_i
      stack.pop while stack.any? && stack.last[0] >= level
      list = root
      if stack.any?
        parent = stack.last[1]
        list = parent.at_xpath('./ul')
        unless list
          list = Nokogiri::XML::Node.new('ul', doc)
          parent.add_child(list)
        end
      end
      li = Nokogiri::XML::Node.new('li', doc)
      link = Nokogiri::XML::Node.new('a', doc)
      link['href'] = '#' + heading['id']
      label = heading.dup
      label.css('.anchor').remove
      link.content = label.text.strip
      li.add_child(link)
      list.add_child(li)
      stack << [level, li]
    end
    target.add_child(root)
    details = Nokogiri::XML::Node.new('details', doc)
    details['class'] = 'static-toc-mobile'
    summary = Nokogiri::XML::Node.new('summary', doc)
    summary.content = target['aria-label']
    details.add_child(summary)
    details.add_child(root.dup)
    content.add_previous_sibling(details)
    item.output = doc.to_html
  end
end

Jekyll::Hooks.register [:pages, :documents], :post_render do |item|
  StaticToc.render(item)
end
