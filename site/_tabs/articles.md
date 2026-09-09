---
layout: page
title: Статьи
icon: fas fa-book-open
order: 1
permalink: /articles/
---

{% for article in site.data.articles %}
- {{ article.date | date: '%d.%m.%Y' }} — [{{ article.title | escape }}]({{ article.url | relative_url }})
{% endfor %}
