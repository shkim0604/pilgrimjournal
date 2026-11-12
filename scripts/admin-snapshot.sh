#!/bin/sh
# Regenerates the admin console snapshot (web/admin/snapshot by default).
#   schema.json        SwiftData schema of the Canonical and LocalAuxiliary stores (AdminSnapshot)
#   architecture.json  SwiftPM targets, dependencies and linked frameworks (swift package dump-package)
#   commits.json       latest 30 commit subjects, with the generation time
# schema.json and architecture.json are deterministic; scripts/check.sh compares them.
# Run after changing a SwiftData model or Package.swift, then commit the result.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
out=${1:-"$root/web/admin/snapshot"}
mkdir -p "$out"
cd "$root"

swift run --quiet AdminSnapshot "$out"

swift package dump-package | python3 -I -c '
import json, sys

package = json.load(sys.stdin)
kinds = {"regular": "library", "executable": "executable", "test": "test"}
targets = []
for target in package["targets"]:
    dependencies = []
    for dependency in target.get("dependencies", []):
        for value in dependency.values():
            if isinstance(value, list) and value and isinstance(value[0], str):
                dependencies.append(value[0])
    frameworks = []
    for setting in target.get("settings", []):
        kind = setting.get("kind", {})
        if "linkedFramework" in kind:
            frameworks.append(kind["linkedFramework"]["_0"])
        elif "linkedLibrary" in kind:
            frameworks.append(kind["linkedLibrary"]["_0"])
    targets.append({
        "name": target["name"],
        "kind": kinds.get(target["type"], target["type"]),
        "dependencies": sorted(set(dependencies)),
        "linkedFrameworks": sorted(set(frameworks)),
    })
targets.sort(key=lambda t: t["name"])
json.dump({"targets": targets}, sys.stdout, indent=2, sort_keys=True, ensure_ascii=False)
sys.stdout.write("\n")
' > "$out/architecture.json"

git log -n 30 --format='%h%x09%cI%x09%s' | python3 -I -c '
import datetime, json, sys

commits = []
for line in sys.stdin.read().splitlines():
    sha, date, subject = line.split("\t", 2)
    commits.append({"hash": sha, "date": date, "subject": subject})
generated = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat()
json.dump({"generatedAt": generated, "commits": commits}, sys.stdout, indent=2, sort_keys=True, ensure_ascii=False)
sys.stdout.write("\n")
' > "$out/commits.json"

echo "admin snapshot written to $out"
