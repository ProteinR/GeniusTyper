#!/usr/bin/env python3
"""Builds GeniusSwitcher/yo.txt from eyo-kernel's safe dictionary (MIT, github.com/hcodes/eyo-kernel).

Only "safe" words: where ё is always right (еще → ещё, Артем → Артём). Words where both spellings
exist (все/всё, узнаем/узнаём) are in eyo's not_safe.txt and are left out on purpose.

Output: one word form with ё per line, sorted by its bytes with ё→е, Ё→Е (the key the app searches
for in a memory-mapped file). A trailing "*" marks forms used only in lowercase (eyo's "_киёв").

    scripts/make-yo-dictionary.py path/to/safe.txt
"""
import re
import sys
from pathlib import Path


def key(form):
    return form.replace("ё", "е").replace("Ё", "Е").encode()


forms = {}
for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    word = line.split("#")[0].strip()
    if not word:
        continue
    lowercase_only = word.startswith("_")
    word = word.lstrip("_")
    if "(" in word:
        parts = re.split(r"[(|)]", word)
        expanded = [parts[0] + ending for ending in parts[1:-1]]
    else:
        expanded = [word]
    for form in expanded:
        if "ё" in form or "Ё" in form:
            forms.setdefault(key(form), form + ("*" if lowercase_only else ""))

out = Path(__file__).resolve().parent.parent / "GeniusSwitcher" / "yo.txt"
out.write_text("\n".join(forms[k] for k in sorted(forms)) + "\n", encoding="utf-8")
print(f"{len(forms)} forms → {out}")
