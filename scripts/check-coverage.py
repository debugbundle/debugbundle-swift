#!/usr/bin/env python3

import json
import sys
from pathlib import Path


MINIMUM_LINE_PERCENT = 80.0
REPO_ROOT = Path(__file__).resolve().parent.parent
SOURCES_ROOT = REPO_ROOT / "Sources"

# This file only declares the diagnostic protocol and its no-op implementation.
# LLVM emits no executable coverage regions for it, so there is no percentage to
# evaluate. The ObjC exception shim is exercised by its bridge test but is not a
# Swift source file and is therefore outside this Swift per-file gate.
NO_EXECUTABLE_REGIONS = {
    (SOURCES_ROOT / "DebugBundle" / "DebugBundleInternalDiagnostic.swift").resolve()
}


def fail(message: str) -> None:
    print(f"Swift coverage gate failed: {message}", file=sys.stderr)
    raise SystemExit(1)


def main() -> None:
    if len(sys.argv) != 2:
        fail("usage: check-coverage.py <llvm-cov JSON path>")

    coverage_path = Path(sys.argv[1]).resolve()
    if not coverage_path.is_file():
        fail(f"coverage report does not exist: {coverage_path}")

    with coverage_path.open(encoding="utf-8") as report_file:
        report = json.load(report_file)

    measured: dict[Path, float] = {}
    for data_set in report.get("data", []):
        for file_report in data_set.get("files", []):
            filename = Path(file_report.get("filename", "")).resolve()
            try:
                filename.relative_to(SOURCES_ROOT)
            except ValueError:
                continue
            line_summary = file_report.get("summary", {}).get("lines", {})
            line_count = int(line_summary.get("count", 0))
            if line_count > 0:
                measured[filename] = float(line_summary.get("percent", 0.0))

    source_files = {path.resolve() for path in SOURCES_ROOT.rglob("*.swift")}
    unexpected_allowlist = NO_EXECUTABLE_REGIONS - source_files
    if unexpected_allowlist:
        fail(
            "no-region allowlist contains missing files: "
            + ", ".join(str(path.relative_to(REPO_ROOT)) for path in sorted(unexpected_allowlist))
        )

    missing = source_files - set(measured) - NO_EXECUTABLE_REGIONS
    if missing:
        fail(
            "executable Swift sources are absent from the report: "
            + ", ".join(str(path.relative_to(REPO_ROOT)) for path in sorted(missing))
        )

    failures = [
        (path, percent)
        for path, percent in measured.items()
        if percent + sys.float_info.epsilon < MINIMUM_LINE_PERCENT
    ]
    if failures:
        for path, percent in sorted(failures):
            print(
                f"  {path.relative_to(REPO_ROOT)}: {percent:.2f}% "
                f"(minimum {MINIMUM_LINE_PERCENT:.2f}%)",
                file=sys.stderr,
            )
        fail(f"{len(failures)} source file(s) are below the per-file threshold")

    lowest_path, lowest_percent = min(measured.items(), key=lambda item: item[1])
    print(
        f"Swift per-file line coverage passed for {len(measured)} executable source files; "
        f"lowest is {lowest_path.relative_to(REPO_ROOT)} at {lowest_percent:.2f}%."
    )


if __name__ == "__main__":
    main()
