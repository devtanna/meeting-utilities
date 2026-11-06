#!/bin/zsh
# Fails on placeholder values, <...> strings, zero byte counts, non-commit revisions or unsafe paths (§15.1).
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - App/Resources/ModelCatalog.json <<'PY'
import json, re, sys
c = json.load(open(sys.argv[1])); errors = []
for m in c["models"]:
    for k in ("artifactRevision", "attribution", "minimumAppVersion", "licenseSPDX"):
        if not m.get(k) or "<" in m[k] or ">" in m[k]: errors.append(f"{m['id']}: placeholder {k}")
    if not re.fullmatch(r"[0-9a-f]{40}", m["artifactRevision"]): errors.append(f"{m['id']}: revision not immutable")
    if not m["files"]: errors.append(f"{m['id']}: no files")
    for f in m["files"]:
        if f["byteCount"] <= 0: errors.append(f"{m['id']}: {f['relativePath']} zero bytes")
        if not re.fullmatch(r"[0-9a-f]{64}", f["sha256"]): errors.append(f"{m['id']}: {f['relativePath']} bad sha256")
        if ".." in f["relativePath"] or f["relativePath"].startswith("/"): errors.append(f"{m['id']}: unsafe path")
if errors: print("\n".join(errors)); sys.exit(1)
print(f"Manifest OK: {len(c['models'])} models, {sum(len(m['files']) for m in c['models'])} files")
PY
