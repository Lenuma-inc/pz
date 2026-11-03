"""Bounded, offline HTML/JSON extraction for web's model-facing output."""
import json
from html import escape
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
    BLOCK = {'p', 'div', 'section', 'article', 'main', 'br', 'li', 'tr', 'pre', 'blockquote', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'ul', 'ol'}

    def __init__(self, base=''):
        super().__init__(convert_charrefs=True)
        self.base = base
        self.parts = []
        self.stack = []
        self.regions = []
        self.pre = 0
        self.tables = []
        self.headings = []
        self.sections = []
        self.list_pending = False
        self.lists = []
        self.has_script = False
        self.app_mount = False
        self.requires_js = False

    def hidden(self):
        return bool(self.stack and self.stack[-1][1])

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        self.has_script |= tag == 'script'
        self.app_mount |= tag in {'div', 'main'} and attrs.get('id') in {'root', 'app', '__next', '__nuxt'}
        hidden = self.hidden() or tag in self.HIDDEN or 'hidden' in attrs or attrs.get('aria-hidden', '').lower() == 'true' or attrs.get('role') in {'navigation', 'banner', 'contentinfo', 'complementary'}
        region = None
        href = ''
        if not hidden:
            classes = set(attrs.get('class', '').split())
            explicit_body = attrs.get('itemprop') == 'articleBody' or bool(classes & {'article-formatted-body', 'tm-article-body'})
            article_body = bool(classes & {'entry-content', 'post-content', 'article-content'})
            priority = 5 if explicit_body else 4 if article_body else 3 if tag == 'main' or attrs.get('role') == 'main' else 2 if attrs.get('id') in {'content', 'main-content', 'main_content'} else 1 if tag == 'article' or attrs.get('itemprop') == 'articleBody' else 0
            # Keep a bounded set of unlabelled containers for conservative
            # article scoring when semantic markup is absent or too broad.
            if priority or (tag in {'div', 'section'} and len(self.regions) < 256):
                region = [priority, len(self.parts), None]
                self.regions.append(region)
            if tag == 'h1':
                self.headings.append([len(self.parts), None])
            if tag == 'h2':
                self.sections.append(len(self.parts))
            if tag == 'table':
                self.tables.append(dict(start=len(self.parts), rows=[], row=[], cell=None, caption='', caption_start=None))
                self.parts.append('')
            if self.tables and tag == 'caption':
                self.tables[-1]['caption_start'] = len(self.parts)
            if self.tables and tag in {'td', 'th'}:
                self.tables[-1]['cell'] = len(self.parts)
            if tag in self.BLOCK and (not self.list_pending or tag == 'li'):
                self.parts.append('\n')
            if tag in {'h1', 'h2', 'h3', 'h4', 'h5', 'h6'}:
                self.parts.append('#' * int(tag[1]) + ' ')
            if tag == 'li':
                if self.lists and self.lists[-1][0] == 'ol':
                    if re.fullmatch(r'-?[0-9]{1,9}', attrs.get('value', '')):
                        self.lists[-1][1] = int(attrs['value'])
                    self.parts.append(str(self.lists[-1][1]) + '. ')
                    self.lists[-1][1] += 1
                else:
                    self.parts.append('- ')
                self.list_pending = True
            if tag in {'ol', 'ul'}:
                start = attrs.get('start', '')
                self.lists.append([tag, int(start) if re.fullmatch(r'-?[0-9]{1,9}', start) else 1])
            if tag == 'pre':
                self.pre += 1
                self.parts.append('```\n')
            if tag == 'a':
                target = urljoin(self.base, attrs.get('href', ''))
                if attrs.get('href') and target.startswith(('https://', 'http://', '/', '#')):
                    href = (target, len(self.parts))
                    self.parts.append('[')
        code_start = len(self.parts) if tag == 'code' and not hidden and not self.pre else None
        if tag not in self.VOID:
            self.stack.append((tag, hidden, region, href, code_start))

    def handle_endtag(self, tag):
        index = next((i for i in range(len(self.stack) - 1, -1, -1) if self.stack[i][0] == tag), None)
        if index is None:
            return
        while len(self.stack) > index:
            name, hidden, region, href, code_start = self.stack.pop()
            if not hidden:
                if name in {'ol', 'ul'}:
                    self.lists.pop()
                if code_start is not None:
                    value = ' '.join(''.join(self.parts[code_start:]).split())
                    if value:
                        fence = '`' * (max((len(m[0]) for m in re.finditer(r'`+', value)), default=0) + 1)
                        padding = ' ' if value.startswith('`') or value.endswith('`') else ''
                        self.parts[code_start:] = [fence + padding + value + padding + fence] + [''] * (len(self.parts) - code_start - 1)
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
                    target, start = href
                    label = re.sub(r'\s+', ' ', ''.join(self.parts[start + 1:])).strip()
                    # Keep part indices stable for regions, headings and tables.
                    self.parts[start] = '[' + label + '](' + target.replace(')', '%29') + ')' if label else ''
                    for i in range(start + 1, len(self.parts)):
                        self.parts[i] = ''
                if name == 'pre':
                    self.pre -= 1
                    self.parts.append('\n```')
                if name in self.BLOCK:
                    self.parts.append('\n')
            if region is not None:
                region[2] = len(self.parts)

    def handle_data(self, data):
        if self.stack and self.stack[-1][0] == 'noscript':
            self.requires_js |= bool(re.search(r'(?:enable|requires?|turn on)\b[^.\n]{0,80}\bjavascript\b|javascript\b[^.\n]{0,80}\b(?:required|disabled)', data, re.I))
        if not self.hidden():
            if data.strip():
                self.list_pending = False
            self.parts.append(data if self.pre else re.sub(r'\s+', ' ', data))

    def text(self):
        # Prefer one explicit article body; multiple bodies usually mean a listing.
        regions = self.regions
        bodies = []
        body_priority = max((r[0] for r in regions if r[0] >= 4), default=4)
        for rank, start, end in regions:
            if rank == body_priority and (not bodies or start >= bodies[-1]):
                bodies.append(end if end is not None else len(self.parts))
        if len(bodies) > 1:
            # Multiple explicit articleBody blocks are a feed, not one article.
            # Retain their enclosing cards so titles and permalinks survive.
            regions = [r for r in regions if r[0] < 4]
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
            if priority == 0:
                ranges = [[0, len(self.parts)]]
            if priority >= 4 and not any(ranges[0][0] <= start < ranges[-1][1] for start, _ in self.headings):
                preceding = [(start, end) for start, end in self.headings if end is not None and end <= ranges[0][0]]
                if preceding:
                    ranges.insert(0, list(preceding[-1]))
            # A multi-section landing page or directory is not a single prose
            # article. Do not discard shorter product sections or linked cards.
            section_count = sum(any(lo <= index < hi for lo, hi in ranges) for index in self.sections)
            if priority < 4 and len(bodies) <= 1 and len(ranges) == 1 and section_count < 2:
                start, end = ranges[0]
                def score(lo, hi):
                    text = ''.join(self.parts[lo:hi])
                    links = sum(len(match[1]) for match in re.finditer(r'\[([^\]]*)\]\([^\n)]*\)', text))
                    plain = re.sub(r'\[([^\]]*)\]\([^\n)]*\)', r'\1', text)
                    paragraphs = [line.strip() for line in plain.splitlines() if len(line.strip()) >= 80]
                    size = len(plain.strip())
                    if size < 300 or len(paragraphs) < 3 or links > size * 0.35:
                        return 0
                    return size - 3 * links
                baseline = score(start, end)
                best = None
                for rank, lo, hi in regions:
                    hi = hi if hi is not None else len(self.parts)
                    if lo < start or hi > end or (lo == start and hi == end):
                        continue
                    candidate = score(lo, hi)
                    # Prefer a compact prose block only when it retains most
                    # of the useful text. Listings and short pages stay intact.
                    if candidate > 0 and candidate >= baseline * 0.9:
                        if best is None or candidate > best[0] or (candidate == best[0] and hi - lo < best[2] - best[1]):
                            best = (candidate, lo, hi)
                if best:
                    ranges = [[best[1], best[2]]]
                    preceding = [(lo, hi) for lo, hi in self.headings if hi is not None and hi <= best[1]]
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
            if line.strip() and (code or line.strip() != '-'):
                lines.append(line.rstrip() if code else line.strip())
        return '\n'.join(lines)


class FlightScripts(HTMLParser):
    """Collect inline Flight data only; never evaluate JavaScript."""
    def __init__(self):
        super().__init__(convert_charrefs=False)
        self.active = False
        self.scripts = []

    def handle_starttag(self, tag, attrs):
        self.active = tag == 'script' and not dict(attrs).get('src')

    def handle_endtag(self, tag):
        if tag == 'script':
            self.active = False

    def handle_data(self, data):
        if self.active:
            self.scripts.append(data)


def rsc_text(raw, base=''):
    # Bound parsing, reference expansion and output independently. Unsupported
    # Flight records are ignored rather than interpreted as executable code.
    if len(raw) > LIMIT or 'self.__next_f.push' not in raw:
        return ''
    parser = FlightScripts()
    parser.feed(raw)
    decoder = json.JSONDecoder()
    chunks = []
    for script in parser.scripts:
        for match in re.finditer(r'self\.__next_f\.push\s*\(\s*', script):
            try:
                value, end = decoder.raw_decode(script, match.end())
            except (ValueError, RecursionError):
                continue
            if script[end:].lstrip().startswith(')') and isinstance(value, list) and len(value) == 2 and value[0] == 1 and isinstance(value[1], str):
                chunks.append(value[1])
            if len(chunks) >= 4096:
                break
        if len(chunks) >= 4096:
            break
    records = {}
    for line in ''.join(chunks).splitlines():
        key, sep, payload = line.partition(':')
        if sep and re.fullmatch(r'[0-9a-fA-F]{1,8}', key) and payload.startswith(('[', '{', '"')):
            try:
                records[key.lower()] = json.loads(payload)
            except (ValueError, RecursionError):
                pass
        if len(records) >= 4096:
            break
    budget = [20000, LIMIT]
    active = set()

    def render(node, depth=0):
        budget[0] -= 1
        if depth > 64 or budget[0] < 0 or budget[1] <= 0:
            return ''
        if isinstance(node, str):
            ref = re.fullmatch(r'\$(?:L)?([0-9a-fA-F]{1,8})', node)
            if ref:
                key = ref[1].lower()
                if key in active:
                    return ''
                active.add(key)
                result = render(records.get(key), depth + 1)
                active.remove(key)
                return result
            if node.startswith('$'):
                return ''
            text = escape(node[:budget[1]])
            budget[1] -= len(text)
            return text
        if isinstance(node, list):
            if len(node) >= 4 and node[0] == '$' and isinstance(node[3], dict):
                tag, props = node[1], node[3]
                if isinstance(tag, str) and tag in Text.HIDDEN:
                    return ''
                body = render(props.get('children'), depth + 1)
                if isinstance(tag, str) and tag in Text.BLOCK | {'a', 'code', 'strong', 'em', 'table', 'td', 'th'}:
                    href = props.get('href')
                    attr = ' href="' + escape(href, quote=True) + '"' if tag == 'a' and isinstance(href, str) else ''
                    return '<' + tag + attr + '>' + body + '</' + tag + '>'
                return body
            return ''.join(render(item, depth + 1) for item in node[:4096])
        if isinstance(node, dict):
            # Component props are not prose: only follow the children field.
            return render(node.get('children'), depth + 1)
        return ''

    result = html_text(render(records.get('0')), base)
    if result:
        return result
    # Routing envelopes may not expose children. Consider only explicit React
    # element records, never metadata objects or standalone string records.
    referenced = set()
    for node in records.values():
        if isinstance(node, list) and len(node) >= 4 and node[0] == '$':
            referenced.update(re.findall(r'"\$(?:L)?([0-9a-fA-F]{1,8})"', json.dumps(node)))
    roots = [node for key, node in records.items() if key not in {ref.lower() for ref in referenced} and isinstance(node, list) and len(node) >= 4 and node[0] == '$']
    return html_text(render(roots), base)


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
    vercel_checkpoint = 'vercel.link/security-checkpoint' in lower and ('verifying your browser' in lower or 'vercel security checkpoint' in lower)
    if vercel_checkpoint or ('<title>just a moment' in lower and ('cf-chl-' in lower or 'challenges.cloudflare.com' in lower)) or ('<form' in lower and 'name="solution"' in lower and 'requestsubmit' in lower):
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
        parser = Text(base)
        parser.feed(raw)
        parser.close()
        text = parser.text()
        if len(text) < 200:
            flight = rsc_text(raw, base)
            if len(flight) > len(text):
                return '[Text extracted from Next.js/RSC data]\n' + flight
            # shortcut: conservative shell detection; expand markers only with real-page fixtures.
            if parser.requires_js or (parser.app_mount and parser.has_script and not text):
                return '[JavaScript rendering required: the server returned an app shell. Full page content was not retrieved.]' + ('\n' + text if text else '')
        return text
    return raw


def search(text, pattern):
    # Reuse grep's installed, linear-time regex engine instead of backtracking re.
    if not pattern or text.startswith(('[Access blocked:', '[JavaScript rendering required:')):
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
        decoded = raw.decode('utf-8', errors='replace')
        text = extract(decoded, sys.argv[1], sys.argv[2], sys.argv[3])
        print(search(text, sys.argv[4] if len(sys.argv) > 4 else ''), end='')
    except (ValueError, KeyError, IndexError, TypeError, RecursionError, OSError, subprocess.SubprocessError) as exc:
        sys.exit(str(exc))
