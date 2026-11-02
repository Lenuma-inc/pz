"""Bounded, offline HTML/JSON extraction for web's model-facing output."""
import json
import sys
import subprocess
import re
import xml.etree.ElementTree as ET
from urllib.parse import urljoin
from html.parser import HTMLParser

LIMIT = 4 * 1024 * 1024


class Text(HTMLParser):
    VOID = {'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'param', 'source', 'track', 'wbr'}
    HIDDEN = {'script', 'style', 'noscript', 'template', 'svg', 'nav', 'footer', 'aside', 'head', 'button', 'form'}
    BLOCK = {'p', 'div', 'section', 'article', 'main', 'br', 'li', 'tr', 'pre', 'blockquote', 'h1', 'h2', 'h3', 'h4', 'ul', 'ol'}

    def __init__(self, base=''):
        super().__init__(convert_charrefs=True)
        self.base = base
        self.parts = []
        self.stack = []
        self.regions = []
        self.pre = 0
        self.tables = []
        self.headings = []
        self.list_pending = False

    def hidden(self):
        return bool(self.stack and self.stack[-1][1])

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        hidden = self.hidden() or tag in self.HIDDEN or 'hidden' in attrs or attrs.get('aria-hidden') == 'true'
        region = None
        href = ''
        if not hidden:
            classes = set(attrs.get('class', '').split())
            explicit_body = attrs.get('itemprop') == 'articleBody' or bool(classes & {'article-formatted-body', 'tm-article-body'})
            article_body = bool(classes & {'entry-content', 'post-content', 'article-content'})
            priority = 5 if explicit_body else 4 if article_body else 3 if tag == 'main' or attrs.get('role') == 'main' else 2 if attrs.get('id') in {'content', 'main-content', 'main_content'} else 1 if tag == 'article' or attrs.get('itemprop') == 'articleBody' else 0
            if priority:
                region = [priority, len(self.parts), None]
                self.regions.append(region)
            if tag == 'h1':
                self.headings.append([len(self.parts), None])
            if tag == 'table':
                self.tables.append(dict(start=len(self.parts), rows=[], row=[], cell=None, caption='', caption_start=None))
                self.parts.append('')
            if self.tables and tag == 'caption':
                self.tables[-1]['caption_start'] = len(self.parts)
            if self.tables and tag in {'td', 'th'}:
                self.tables[-1]['cell'] = len(self.parts)
            if tag in self.BLOCK and (not self.list_pending or tag == 'li'):
                self.parts.append('\n')
            if tag in {'h1', 'h2', 'h3', 'h4'}:
                self.parts.append('#' * int(tag[1]) + ' ')
            if tag == 'li':
                self.parts.append('- ')
                self.list_pending = True
            if tag == 'pre':
                self.pre += 1
                self.parts.append('```\n')
            if tag == 'a':
                target = urljoin(self.base, attrs.get('href', ''))
                if attrs.get('href') and target.startswith(('https://', 'http://', '/', '#')):
                    href = target
                    self.parts.append('[')
        if tag not in self.VOID:
            self.stack.append((tag, hidden, region, href))

    def handle_endtag(self, tag):
        index = next((i for i in range(len(self.stack) - 1, -1, -1) if self.stack[i][0] == tag), None)
        if index is None:
            return
        while len(self.stack) > index:
            name, hidden, region, href = self.stack.pop()
            if not hidden:
                if self.tables:
                    table = self.tables[-1]
                    if name == 'caption' and table['caption_start'] is not None:
                        table['caption'] = ''.join(self.parts[table['caption_start']:]).strip()
                    if name in {'td', 'th'} and table['cell'] is not None:
                        cell = ' '.join(''.join(self.parts[table['cell']:]).split()).replace('|', '\\|')
                        table['row'].append(cell)
                        table['cell'] = None
                    if name == 'tr' and table['row']:
                        table['rows'].append(table['row'])
                        table['row'] = []
                    if name == 'table':
                        self.tables.pop()
                        rows = [row for row in table['rows'] if any(cell.strip() for cell in row)]
                        if rows:
                            width = max(map(len, rows))
                            rows = [row + [''] * (width - len(row)) for row in rows]
                            rows.insert(1, ['---'] * width)
                            rendered = '\n' + (table['caption'] + '\n' if table['caption'] else '') + '\n'.join('| ' + ' | '.join(row) + ' |' for row in rows) + '\n'
                            self.parts[table['start']] = rendered
                            for i in range(table['start'] + 1, len(self.parts)):
                                self.parts[i] = ''
                if name == 'li':
                    self.list_pending = False
                if name == 'h1' and self.headings:
                    self.headings[-1][1] = len(self.parts)
                if href:
                    self.parts.append('](' + href.replace(')', '%29') + ')')
                if name == 'pre':
                    self.pre -= 1
                    self.parts.append('\n```')
                if name in self.BLOCK:
                    self.parts.append('\n')
            if region is not None:
                region[2] = len(self.parts)

    def handle_data(self, data):
        if not self.hidden():
            if data.strip():
                self.list_pending = False
            self.parts.append(data if self.pre else re.sub(r'\s+', ' ', data))

    def text(self):
        # Prefer one explicit article body; multiple bodies usually mean a listing.
        regions = self.regions
        bodies = []
        for rank, start, end in regions:
            if rank == 4 and (not bodies or start >= bodies[-1]):
                bodies.append(end if end is not None else len(self.parts))
        if len(bodies) > 1:
            regions = [r for r in regions if r[0] != 4]
        if regions:
            priority = max(r[0] for r in regions)
            ranges = []
            for rank, start, end in regions:
                if rank != priority:
                    continue
                end = end if end is not None else len(self.parts)
                if ranges and start < ranges[-1][1]:
                    ranges[-1][1] = max(ranges[-1][1], end)
                else:
                    ranges.append([start, end])
            if priority >= 4 and not any(ranges[0][0] <= start < ranges[-1][1] for start, _ in self.headings):
                preceding = [(start, end) for start, end in self.headings if end is not None and end <= ranges[0][0]]
                if preceding:
                    ranges.insert(0, list(preceding[-1]))
            parts = [part for start, end in ranges for part in self.parts[start:end]]
        else:
            parts = self.parts
        text = re.sub(r'\[\s*\]\([^\n)]*\)', '', ''.join(parts))
        lines = []
        code = False
        for line in text.splitlines():
            if line.strip() == '```':
                code = not code
            if line.strip():
                lines.append(line.rstrip() if code else line.strip())
        return '\n'.join(lines)


def html_text(value, base=''):
    parser = Text(base)
    parser.feed(value)
    parser.close()
    return parser.text()


def feed_text(raw, base):
    # UTF-8 XML only; disallow DTD/entity expansion before parsing.
    if '<!DOCTYPE' in raw.upper() or '<!ENTITY' in raw.upper():
        raise ValueError('XML declarations are not supported')
    root = ET.fromstring(raw)
    local = lambda node: node.tag.rsplit('}', 1)[-1]
    if local(root) not in {'rss', 'RDF', 'feed'}:
        return None
    def field(node, *names):
        for name in names:
            for child in node:
                if local(child) == name:
                    return ''.join(child.itertext())
        return ''
    channel = next((n for n in root if local(n) == 'channel'), root)
    out = ['# ' + field(channel, 'title')]
    for node in root.iter():
        if local(node) not in {'item', 'entry'}:
            continue
        link = field(node, 'link')
        if local(node) == 'entry':
            link = next((n.get('href', '') for n in node if local(n) == 'link' and n.get('rel', 'alternate') == 'alternate'), '')
        out.extend(['## ' + field(node, 'title'), urljoin(base, link), field(node, 'pubDate', 'published', 'updated', 'date'), html_text(field(node, 'description', 'summary', 'encoded', 'content'), base)])
    return '\n'.join(line for line in out if line.strip())


def extract(raw, mode='auto', path='', base=''):
    if mode == 'raw':
        return raw
    value = raw.lstrip()
    lower = raw.lower()
    if ('<title>just a moment' in lower and ('cf-chl-' in lower or 'challenges.cloudflare.com' in lower)) or ('<form' in lower and 'name="solution"' in lower and 'requestsubmit' in lower):
        return '[Access blocked: the server returned a browser/JavaScript verification page. Article content was not retrieved.]'
    if re.match(r'<(?:\?xml\b|rss\b|feed\b|rdf:rdf\b)', value, re.I):
        try:
            feed = feed_text(value, base)
        except ET.ParseError:
            feed = None
        if feed is not None:
            return feed
    if path or value.startswith(('{', '[')):
        try:
            data = json.loads(raw)
        except ValueError:
            if path:
                raise
        else:
            if path:
                for key in path.split('.'):
                    data = data[int(key)] if isinstance(data, list) else data[key]
                return html_text(data, base) if isinstance(data, str) else json.dumps(data, ensure_ascii=False, separators=(',', ':'))
            # Common article API responses expose their body as an HTML string.
            candidates = [data]
            while candidates:
                node = candidates.pop()
                if isinstance(node, dict):
                    for key in ('textHtml', 'bodyHtml', 'contentHtml', 'articleBody'):
                        if isinstance(node.get(key), str) and node[key].strip():
                            title = node.get('titleHtml', node.get('title', ''))
                            return '[Article text extracted from JSON; metadata omitted]\n' + html_text(str(title), base) + '\n' + html_text(node[key], base)
                    candidates.extend(node.values())
            return json.dumps(data, ensure_ascii=False, separators=(',', ':'))
    if value.startswith('<'):
        return html_text(raw, base)
    return raw


def search(text, pattern):
    # Reuse grep's installed, linear-time regex engine instead of backtracking re.
    if not pattern or text.startswith('[Access blocked:'):
        return text
    result = subprocess.run(['rg', '--no-config', '--only-matching', '--ignore-case', '--color', 'never', '--', pattern], input=text, text=True, capture_output=True, timeout=5)
    if result.returncode not in {0, 1}:
        raise ValueError('invalid search pattern')
    return result.stdout.rstrip('\n') if result.returncode == 0 else '[No matches for pattern]'


if __name__ == '__main__':
    try:
        raw = sys.stdin.buffer.read(LIMIT + 1)
        if len(raw) > LIMIT:
            raise ValueError('response exceeds extraction limit')
        text = extract(raw.decode('utf-8', errors='replace'), sys.argv[1], sys.argv[2], sys.argv[3])
        print(search(text, sys.argv[4] if len(sys.argv) > 4 else ''), end='')
    except (ValueError, KeyError, IndexError, TypeError, RecursionError, OSError, subprocess.SubprocessError) as exc:
        sys.exit(str(exc))
