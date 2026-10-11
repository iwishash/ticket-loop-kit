# -*- coding: utf-8 -*-
# docs/guide.html 부록 D를 files/scripts/ticket-loop.sh로 다시 채운다.
#   python3 docs/sync-guide.py && bash docs/build-pdf.sh
import html
import os
import re

kit = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
p = os.path.join(kit, "docs", "guide.html")
s = open(p, encoding="utf-8").read()
script = open(os.path.join(kit, "files", "scripts", "ticket-loop.sh"), encoding="utf-8").read().rstrip("\n")
pat = re.compile(r'(<h3>D\..*?<pre class="script"><code>)(.*?)(</code></pre>)', re.S)
assert len(pat.findall(s)) == 1
s = pat.sub(lambda m: m.group(1) + html.escape(script, quote=False) + m.group(3), s)
open(p, "w", encoding="utf-8").write(s)
print("부록 D 갱신")
