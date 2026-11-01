#!/usr/bin/env python3
"""Retain deterministic source-distribution bytes and exact local qualification receipts."""
import gzip
import hashlib
import io
import json
from pathlib import Path
import re
import subprocess
import tarfile

root = Path(__file__).resolve().parent.parent
version = re.search(r's.version\s*=\s*"([0-9.]+)"', (root / "DebugBundle.podspec").read_text()).group(1)

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

names = subprocess.check_output(["git", "-C", str(root), "ls-files", "--cached", "--others", "--exclude-standard", "-z"]).decode().split("\0")
sources = []
for name in sorted(set(names) - {""}):
    path = root / name
    if path.is_symlink() or not path.is_file() or any(part.startswith((".tmp", ".smoke", ".build")) for part in path.relative_to(root).parts):
        continue
    if path.suffix.lower() in {".pem", ".p12", ".key", ".mobileprovision"}:
        continue
    sources.append({"path": name, "sha256": digest(path)})

destination = root / ".tmp/evidence-artifacts"
destination.mkdir(parents=True, exist_ok=True)
artifact = destination / f"debugbundle-swift-{version}-candidate.tar.gz"
raw = io.BytesIO()
with tarfile.open(fileobj=raw, mode="w") as archive:
    for source in sources:
        path = root / source["path"]
        info = tarfile.TarInfo(f"debugbundle-swift-{version}/{source['path']}")
        info.size = path.stat().st_size
        info.mode = 0o755 if path.stat().st_mode & 0o111 else 0o644
        with path.open("rb") as handle:
            archive.addfile(info, handle)
artifact.write_bytes(gzip.compress(raw.getvalue(), mtime=0))

receipts = [
    Path("/tmp/debugbundle-zod4-swift-schema-qualification2.log"),
    Path("/tmp/debugbundle-zod4-swift-ios-qualification.log"),
    Path("/tmp/debugbundle-zod4-swift-performance.log"),
    Path("/tmp/debugbundle-zod4-swift-ios-performance.log"),
]
manifest = {
    "version": 1, "candidate_version": version, "source_state": "uncommitted local candidate",
    "base_commit": subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip(),
    "source_sha256": hashlib.sha256(json.dumps(sources, sort_keys=True, separators=(",", ":")).encode()).hexdigest(),
    "sources": sources,
    "artifacts": [{"path": str(artifact.relative_to(root)), "sha256": digest(artifact), "bytes": artifact.stat().st_size}],
    "receipts": [{"path": str(path), "sha256": digest(path)} for path in receipts],
    "remaining": ["exact archive consumer receipts including Swift5.10", "whole-phase qualification", "separate publication authority"],
    "measurement_limits": ["simulator performance is not a physical-device measurement", "Swift5.10 XCTest requires a matching older Xcode test framework"],
}
output = root / ".tmp/evidence-artifact-manifest.json"
output.write_text(json.dumps(manifest, indent=2) + "\n")
print(f"Retained {len(sources)} source identities and deterministic unpublished Swift {version} distribution: {output}")
