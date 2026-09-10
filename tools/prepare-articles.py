"""Import selected public README articles without changing their repositories."""
import argparse
from datetime import datetime
from zoneinfo import ZoneInfo
import html
import json
import re
import shutil
import subprocess
import tempfile
from pathlib import Path
from urllib.parse import quote, unquote, urlsplit

ROOT = Path(__file__).resolve().parents[1]


def article_link(value, article_links):
    """Convert repository-root links only; file, issue and code links stay external."""
    parts = urlsplit(value)
    if parts.scheme not in ('http', 'https') or parts.netloc.lower() != 'github.com':
        return value
    repo = parts.path.strip('/')
    if repo.endswith('.git'):
        repo = repo[:-4]
    slug = article_links.get(repo.lower())
    if slug is None:
        return value
    fragment = parts.fragment
    if fragment.lower() == 'readme':
        fragment = ''
    return f'../{slug}/' + ('?' + parts.query if parts.query else '') + ('#' + fragment if fragment else '')


def import_article(source, checkout, output, article_links=None):
    article_links = article_links or {}
    slug = source['slug']
    readmes = [p for p in checkout.iterdir() if p.name.lower() == 'readme.md']
    if len(readmes) != 1:
        raise ValueError(f"Expected one root README.md in {source['repo']}")
    text = readmes[0].read_text(encoding='utf-8-sig')
    heading = re.search(r'^# +(.+?)\s*$', text, re.M)
    if not heading:
        raise ValueError(f"Missing article title in {source['repo']}")
    dated_title = re.fullmatch(r'(\d{4}-\d{2}-\d{2})[ \t]+(.+)', heading[1].strip())
    if not dated_title:
        raise ValueError(f"Expected '# YYYY-MM-DD Title' in {source['repo']}")
    date_text, title = dated_title.groups()
    try:
        date = datetime.strptime(date_text, '%Y-%m-%d').replace(tzinfo=ZoneInfo('Europe/Moscow')).isoformat()
    except ValueError as error:
        raise ValueError(f"Invalid article date {date_text} in {source['repo']}") from error
    text = text[:heading.start()] + text[heading.end():]
    revision = subprocess.check_output(['git', '-C', str(checkout), 'rev-parse', 'HEAD'], text=True).strip()
    article_dir = output / 'articles' / slug
    article_dir.mkdir(parents=True)
    copied = set()

    def resolve_url(value, image=False):
        value = html.unescape(value)
        if not image:
            converted = article_link(value, article_links)
            if converted != value:
                return converted
        parts = urlsplit(value)
        if parts.scheme or parts.netloc or not parts.path:
            return value
        relative = unquote(parts.path).lstrip('/')
        local = (checkout / relative).resolve()
        if not local.is_relative_to(checkout.resolve()):
            raise ValueError(f"Path outside repository: {value}")
        if not local.is_file():
            raise ValueError(f"Missing local file in {source['repo']}: {value}")
        if image:
            target = article_dir / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(local, target)
            copied.add(relative)
            return quote(relative, safe='/') + ('?' + parts.query if parts.query else '') + ('#' + parts.fragment if parts.fragment else '')
        if local == readmes[0].resolve():
            return './' + ('#' + parts.fragment if parts.fragment else '')
        return f"https://github.com/{source['repo']}/blob/{revision}/{quote(relative, safe='/')}" + ('#' + parts.fragment if parts.fragment else '')

    def html_tag(match):
        tag = match[0]
        is_image = bool(re.match(r'<img\b', tag, re.I))
        def attribute(m):
            value = resolve_url(m[3], image=is_image and m[1].lower() == 'src')
            return m[1] + '=' + m[2] + html.escape(value, quote=True) + m[2]
        tag = re.sub(r'\b(src|href)\s*=\s*([\"\'])(.*?)\2', attribute, tag, flags=re.I)
        if is_image and not re.search(r'\balt\s*=', tag, re.I):
            tag = re.sub(r'\s*/?>$', lambda m: ' alt=""' + m[0], tag)
        return tag

    # Leave fenced and inline code examples unchanged while processing prose.
    chunks = re.split(r'(^[ \t]*```[^\n]*\n.*?^[ \t]*```[ \t]*$|^[ \t]*~~~[^\n]*\n.*?^[ \t]*~~~[ \t]*$|`+[^`\n]*`+)', text, flags=re.M | re.S)
    for i in range(0, len(chunks), 2):
        chunk = re.sub(r'<(?:img|a)\b[^>]*>', html_tag, chunks[i], flags=re.I)
        def markdown_link(m):
            return m[1] + '(' + resolve_url(m[2], image=m[1].startswith('!')) + ')'
        chunk = re.sub(r'(!?\[[^\]\n]*\])\(([^\s()]+)\)', markdown_link, chunk)
        chunks[i] = chunk
    text = ''.join(chunks)
    frontmatter = {
        'layout': 'page',
        'article': True,
        'media_subpath': f'/articles/{slug}',
        'title': title,
        'date': date,
        'toc': True,
        'render_with_liquid': False,
    }
    rendered = '---\n' + '\n'.join(k + ': ' + json.dumps(v, ensure_ascii=False) for k, v in frontmatter.items()) + '\n---\n\n' + text.lstrip()
    (article_dir / 'index.md').write_text(rendered, encoding='utf-8')
    return {'title': title, 'date': date, 'url': f'/articles/{slug}/', 'source': f"https://github.com/{source['repo']}", 'revision': revision, 'images': len(copied)}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--sources-dir', type=Path, help='Use existing local clones for verification')
    args = parser.parse_args()
    sources = json.loads((ROOT / 'article-sources.json').read_text())
    slugs = set()
    for source in sources:
        if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', source['repo']):
            raise ValueError('Invalid GitHub repository')
        if not re.fullmatch(r'[a-z0-9]+(?:-[a-z0-9]+)*', source['slug']) or source['slug'] in slugs:
            raise ValueError('Invalid or duplicate article slug')
        slugs.add(source['slug'])
    article_links = {source['repo'].lower(): source['slug'] for source in sources}
    with tempfile.TemporaryDirectory() as temporary:
        temp = Path(temporary)
        generated = temp / 'generated'
        generated.mkdir()
        articles = []
        for source in sources:
            name = source['repo'].split('/')[1]
            checkout = args.sources_dir.resolve() / name if args.sources_dir else temp / name
            if not args.sources_dir:
                subprocess.run(['git', 'clone', '--depth', '1', '--', f"https://github.com/{source['repo']}.git", str(checkout)], check=True)
            article = import_article(source, checkout, generated, article_links)
            articles.append(article)
            print(f"Imported {source['repo']}: {article['images']} images")
        target = ROOT / 'site' / 'articles'
        if target.exists():
            shutil.rmtree(target)
        shutil.copytree(generated / 'articles', target)
        data = ROOT / 'site' / '_data'
        data.mkdir(exist_ok=True)
        (data / 'articles.json').write_text(json.dumps(articles, ensure_ascii=False, indent=2) + '\n')
        print(f'Prepared {len(articles)} articles')


if __name__ == '__main__':
    main()
