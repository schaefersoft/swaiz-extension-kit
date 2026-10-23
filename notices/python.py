import importlib.metadata as md
import json
import sys

title = sys.argv[1] if len(sys.argv) > 1 else "Python-Bibliotheken"
LICENSE_PREFIXES = ("license", "licence", "copying", "notice")

packages = {}
for dist in md.distributions():
    meta = dist.metadata
    raw = (meta.get("License") or "").strip()
    license = meta.get("License-Expression") or (raw if raw and "\n" not in raw and len(raw) < 80 else "")
    if not license:
        license = " / ".join(
            c.split("::")[-1].strip() for c in meta.get_all("Classifier") or [] if c.startswith("License ::")
        )
    text = ""
    for f in dist.files or []:
        if f.name.lower().startswith(LICENSE_PREFIXES) or "/licenses/" in str(f).lower():
            try:
                text = dist.locate_file(f).read_text(errors="replace").strip()
                break
            except OSError:
                pass
    if not text and "\n" in raw:
        text = raw
    name = meta["Name"]
    packages[(name.lower(), dist.version)] = {
        "name": name,
        "version": dist.version,
        "license": license or "siehe Lizenztext",
        "text": text,
    }

json.dump(
    {"title": title, "packages": sorted(packages.values(), key=lambda p: p["name"].lower())},
    sys.stdout,
    ensure_ascii=False,
    indent=1,
)
sys.stdout.write("\n")
