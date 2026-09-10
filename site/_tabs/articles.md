---
layout: page
title: Статьи
icon: fas fa-book-open
order: 1
permalink: /articles/
---

{% assign sorted_articles = site.data.articles | sort: 'date' | reverse %}
{% for article in sorted_articles %}
- {{ article.date | date: '%d.%m.%Y' }} — [{{ article.title | escape }}]({{ article.url | relative_url }})
{% endfor %}
