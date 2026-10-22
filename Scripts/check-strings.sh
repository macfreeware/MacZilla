#!/bin/bash
# Lists interface strings that have no entry in Resources/en.lproj or
# Resources/tr.lproj. The keys are the Turkish source strings; the compiler
# extracts them from Text("…"), Button("…"), String(localized: "…") and so on.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

# A clean build so every file reports its strings.
rm -rf .build/strings
swift build --product MacZilla --build-path .build/strings \
    -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$OUT" >/dev/null

python3 -I - "$OUT" Resources <<'EOF'
import glob, json, os, plistlib, re, subprocess, sys
out, res = sys.argv[1], sys.argv[2]
keys = set()
for f in glob.glob(os.path.join(out, "*.stringsdata")):
    for entries in json.load(open(f)).get("tables", {}).values():
        keys.update(e["key"] for e in entries)
keys = {k for k in keys if re.search(r"[A-Za-zçğıöşüÇĞİÖŞÜ]{2,}", k)}

def table(lang):
    """Keys of <lang>.lproj/Localizable.strings and .stringsdict."""
    found = set()
    path = os.path.join(res, f"{lang}.lproj", "Localizable.strings")
    if os.path.exists(path):
        text = subprocess.run(["plutil", "-convert", "json", "-o", "-", path],
                              capture_output=True, text=True, check=True).stdout
        found |= set(json.loads(text))
    path = os.path.join(res, f"{lang}.lproj", "Localizable.stringsdict")
    if os.path.exists(path):
        found |= set(plistlib.load(open(path, "rb")))
    return found

status = 0
for lang in ("en", "tr"):
    missing = sorted(keys - table(lang), key=str.casefold)
    if missing:
        status = 1
        print(f"{lang}: {len(missing)} eksik çeviri")
        for k in missing:
            print("   ", json.dumps(k, ensure_ascii=False))
    else:
        print(f"{lang}: {len(keys)} metnin hepsi var")
sys.exit(status)
EOF
