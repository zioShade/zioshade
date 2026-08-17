#!/usr/bin/env python3
"""Carve a bounded, deterministic corpus slice out of a WebGPU CTS WGSL dump.

Input: dump.json as produced by tools/webgpu_cts_dump.mjs (see
tools/webgpu_cts_fetch.sh for the full regeneration pipeline). Each entry is one
(expectCompileResult | expectCompileWarning) call the CTS framework would have
made against a real WebGPU implementation: {file, test, params, expected, code}.

Output: <dst>/cases/cts_<sha1>.wgsl plus <dst>/manifest.tsv, one case per unique
shader source. The slice is DETERMINISTIC: within each spec file the unique
shaders are sorted by sha1 and the first --per-file are kept, so re-running the
pipeline at the same CTS commit yields a byte-identical corpus (and a refreshed
corpus changes only what the CTS actually changed, not an arbitrary prefix).

Keep filters, all counted into the stats block so the slice stays auditable:
  - expected=true only. expected=false is WGSL the CTS itself expects to FAIL
    compilation; it can never enter a WGSL -> SPIR-V -> WGSL round trip.
  - at least one @vertex/@fragment/@compute entry point. Module-scope-only
    tests (const/override/type decls) have no entry point, so no compiler can
    lower them to SPIR-V; they are out of the harness's measurable path.
  - non-empty source; dedup by exact text. Dedup is bucketed per spec file (the
    cap is per spec file), so a shader witnessed by two spec files can be
    picked from both; the case id is the content sha1, so the SECOND pick is
    dropped at emission (the lexicographically first spec file records the
    witness) and counted as duplicate_id_skipped. Without this, manifest rows
    and case files disagree, which the sweep's fail-closed consistency check
    treats as harness breakage.

Usage: webgpu_cts_extract.py <dump.json> <dst> [--per-file N] (default 4)
"""
import argparse
import hashlib
import json
import os
import re
import sys

ENTRY_RE = re.compile(r'@(vertex|fragment|compute)[^{}]*?fn\s+(\w+)', re.S)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('dump')
    ap.add_argument('dst')
    ap.add_argument('--per-file', type=int, default=4)
    args = ap.parse_args()

    with open(args.dump) as f:
        entries = json.load(f)

    stats = {
        'dumped': len(entries),
        'expected_false': 0,
        'no_entry_point': 0,
        'empty': 0,
        'unique_total': 0,
        'slice_cases': 0,
        'slice_bytes': 0,
        'spec_files_in_slice': 0,
        'duplicate_id_skipped': 0,
    }

    # Pass 1: filter + global exact-text dedup, bucketed by originating spec file.
    by_file: dict[str, dict[str, dict]] = {}
    for e in entries:
        code = e['code']
        if not e.get('expected'):
            stats['expected_false'] += 1
            continue
        if not code.strip():
            stats['empty'] += 1
            continue
        m = ENTRY_RE.search(code)
        if not m:
            stats['no_entry_point'] += 1
            continue
        sha = hashlib.sha1(code.encode()).hexdigest()
        bucket = by_file.setdefault(e['file'], {})
        if sha in bucket:
            continue
        # Prefer an entry literally named main (zioshade's default), else the
        # first stage-annotated function in source order.
        all_entries = ENTRY_RE.findall(code)
        name = next((n for s, n in all_entries if n == 'main'), m.group(2))
        bucket[sha] = {
            'sha': sha,
            'code': code,
            'stage': m.group(1),
            'entry': name,
            'test': e['test'],
            'params': json.dumps(e.get('params', {}), sort_keys=True, separators=(',', ':')),
        }
    stats['unique_total'] = sum(len(b) for b in by_file.values())

    # Pass 2: deterministic per-file slice.
    cases = []
    for f in sorted(by_file):
        picked = sorted(by_file[f].values(), key=lambda c: c['sha'])[: args.per_file]
        cases.extend((f, c) for c in picked)
    stats['spec_files_in_slice'] = len({f for f, _ in cases})

    cases_dir = os.path.join(args.dst, 'cases')
    os.makedirs(cases_dir, exist_ok=True)
    manifest = ['id\twgsl\tentry\tstage\tspec\ttest\tparams']
    emitted_ids: set[str] = set()
    for f, c in cases:
        cid = 'cts_' + c['sha'][:12]
        if cid in emitted_ids:
            # Same shader text picked from another spec file: the case file is
            # content-addressed and already written; a second manifest row
            # would desynchronize rows vs files (sweep fail-closed check).
            stats['duplicate_id_skipped'] += 1
            continue
        emitted_ids.add(cid)
        path = f'cases/{cid}.wgsl'
        with open(os.path.join(args.dst, path), 'w') as w:
            w.write(c['code'] if c['code'].endswith('\n') else c['code'] + '\n')
        manifest.append(
            '\t'.join((cid, path, c['entry'], c['stage'], f, c['test'], c['params']))
        )
        stats['slice_cases'] += 1
        stats['slice_bytes'] += len(c['code'])
    with open(os.path.join(args.dst, 'manifest.tsv'), 'w') as w:
        w.write('\n'.join(manifest) + '\n')

    print(json.dumps(stats, indent=1))
    # Fails closed: an extractor bug that yields an empty slice must be loud.
    if stats['slice_cases'] == 0:
        print('error: empty slice -- dump unusable or filters wrong', file=sys.stderr)
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main())
