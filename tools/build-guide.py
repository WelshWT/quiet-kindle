#!/usr/bin/env python3
"""Build this guide's limited Markdown subset into static HTML. No dependencies.

This intentionally supports only the constructs used in PAPERWHITE3.md; it is
not a general Markdown parser. Source text is escaped before HTML formatting.
"""
from pathlib import Path
import html
import re

ROOT = Path(__file__).resolve().parents[1]
REPO = 'https://github.com/WelshWT/quiet-kindle/blob/paperwhite3-experimental/'

def inline(text):
    text = html.escape(text)
    text = re.sub(r'`([^`]+)`', r'<code>\1</code>', text)
    text = re.sub(r'\*\*([^*]+)\*\*', r'<strong>\1</strong>', text)
    def link(m):
        url = m[2]
        if not url.startswith('https://'):
            url = REPO + url.removeprefix('../')
        return f'<a href="{url}">{m[1]}</a>'
    return re.sub(r'\[([^\]]+)\]\(([^)]+)\)', link, text)

text = (ROOT / 'PAPERWHITE3.md').read_text()
sections = re.split(r'^## ', text, flags=re.M)[1:]
body, toc = [], []
for n, part in enumerate(sections):
    title, rest = part.split('\n', 1)
    ident = 'overview' if n == 0 else ('credits' if title.startswith('Credits') else f'step-{n}')
    toc.append(f'<a href="#{ident}">{html.escape(title)}</a>')
    chunks, lines, i = [], rest.strip().splitlines(), 0
    while i < len(lines):
        line = lines[i]
        if not line.strip():
            i += 1
            continue
        if line.startswith('```'):
            block = []
            i += 1
            while i < len(lines) and not lines[i].startswith('```'):
                block.append(lines[i]); i += 1
            chunks.append('<pre><code>' + html.escape('\n'.join(block)) + '</code></pre>')
            i += 1
        elif line.startswith('|'):
            rows = []
            while i < len(lines) and lines[i].startswith('|'):
                cells = [c.strip() for c in lines[i].strip('|').split('|')]
                if not all(re.fullmatch(r'[- :]+', c) for c in cells):
                    tag = 'th' if not rows else 'td'
                    rows.append('<tr>' + ''.join(f'<{tag}>{inline(c)}</{tag}>' for c in cells) + '</tr>')
                i += 1
            chunks.append('<div class="table-wrap"><table><thead>'+rows[0]+'</thead><tbody>'+''.join(rows[1:])+'</tbody></table></div>')
        elif line.startswith('- ') or re.match(r'^\d+\. ', line):
            ordered = not line.startswith('- ')
            pattern = r'^\d+\. ' if ordered else r'^- '
            items = []
            while i < len(lines) and re.match(pattern, lines[i]):
                items.append('<li>'+inline(re.sub(pattern, '', lines[i]))+'</li>'); i += 1
            tag = 'ol' if ordered else 'ul'
            chunks.append(f'<{tag}>'+''.join(items)+f'</{tag}>')
        else:
            para = [line]; i += 1
            while i < len(lines) and lines[i].strip():
                para.append(lines[i]); i += 1
            value = ' '.join(para)
            cls = ' class="checkpoint"' if value.startswith('**Checkpoint:') or value.startswith('**Before calling it done:') else ''
            chunks.append(f'<p{cls}>{inline(value)}</p>')
    body.append(f'<section id="{ident}"><h2>{html.escape(title)}</h2>'+''.join(chunks)+'</section>')

template = '''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta name="description" content="A practical Paperwhite 3 field guide to offline reading with KOReader, SimpleUI and Quiet. Clear steps, honest testing status and recovery notes."><meta name="theme-color" content="#f6f3eb"><title>An independent Kindle — WelshWT</title><link rel="stylesheet" href="style.css"></head><body>
<a class="skip" href="#overview">Skip to the guide</a>
<header><a href="#">W / Independent Kindle</a><a href="https://github.com/WelshWT/quiet-kindle/tree/paperwhite3-experimental">Source on GitHub ↗</a></header>
<main><div class="hero"><div><div class="eyebrow">The Paperwhite 3 field guide · by WelshWT</div><h1>Your books.<br>Your reader.<br><em>On your terms.</em></h1><p class="intro">Give an older Kindle a calmer reading life. Bring your own documents, organise your library and build a Home screen that earns its space.</p><div class="pills"><span>Paperwhite 3 / 2015</span><span>Firmware 5.16.2.1.1</span><span>USB + offline reading</span></div><a class="button" href="#step-1">Start with your device ↓</a><a class="button secondary" href="#step-7">Explore our improvements</a></div>
<div class="device-wrap"><div class="device" role="img" aria-label="Illustrative home layout with two currently reading books, a clock and compact statistics. Concept only."><div class="screen"><div class="screen-top"><span>09:41 · 76%</span><span>Exit KOReader ↗</span></div><h3>Currently reading</h3><div class="books"><div class="book"><div class="cover">A book<br>of your own</div><p>Notes &amp; ideas</p><div class="progress"><i style="width:38%"></i></div>38% read</div><div class="book"><div class="cover">The next<br>chapter</div><p>Stories &amp; discoveries</p><div class="progress"><i style="width:64%"></i></div>64% read</div></div><div class="metrics"><div><strong>24</strong>minutes today</div><div><strong>7</strong>day streak</div></div><p>Your library. A little less noise.</p><div class="screen-bottom"><b>Home</b><span>Library</span><span>Collections</span><span>Settings</span></div></div></div><p class="concept">Layout concept · not an on-device screenshot</p></div></div>
<div class="notice"><strong>Experimental edition · 29 October 2026.</strong> The jailbreak and reader ran on our device. Several interface changes still need a full device check, and cover indexing remains unresolved. Amazon's underlying operating system stays installed.</div>
<div class="shell"><aside class="toc"><details open><summary>In this guide</summary>TOC</details><p class="note">One device, a documented process.<br>Check each checkpoint before moving on.</p></aside><article>BODY</article></div></main>
<footer><span>WelshWT · Independent Kindle · 2026<br>Built on KOReader, Quiet, SimpleUI and KindleModding.</span><span>No tracking, external fonts or cloud dependencies.<br><a href="https://github.com/WelshWT/quiet-kindle/blob/paperwhite3-experimental/PAPERWHITE3.md">Read the Markdown guide ↗</a></span></footer>
</body></html>'''
(ROOT/'docs/index.html').write_text(template.replace('TOC',''.join(toc)).replace('BODY',''.join(body)))
(ROOT/'docs/.nojekyll').write_text('')
print('Built docs/index.html from PAPERWHITE3.md')
