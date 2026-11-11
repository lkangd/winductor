#!/usr/bin/env python3
"""Agent-neutral, read-only Git review evidence. No checkout, staging or commits."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile


def git(repo, *args):
    return subprocess.check_output(["git", "-C", str(repo), *args], stderr=subprocess.PIPE)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inside(root, relative):
    path = (root / relative).resolve()
    if not path.is_relative_to(root.resolve()):
        raise ValueError(f"path escapes evidence/repository: {relative}")
    return path


def check(out):
    out = Path(out).resolve()
    manifest = json.loads((out / "manifest.json").read_text())
    if manifest.get("schema") != 1 or not manifest.get("files"):
        raise ValueError("invalid or empty review manifest")
    required = {"range.diff", "commits.txt", "README.md"}
    if manifest.get("spec"):
        required.add(manifest["spec"])
    if not required.issubset(manifest["files"]) or not any(name.startswith("snapshot/") for name in manifest["files"]):
        raise ValueError("review manifest lacks required range/commits/snapshot/context evidence")
    for relative, expected in manifest["files"].items():
        path = inside(out, relative)
        if not path.is_file() or digest(path) != expected:
            raise ValueError(f"missing or changed evidence: {relative}")
    if not (out / "range.diff").stat().st_size:
        raise ValueError("empty range.diff")
    return manifest


def prepare(repo, base, head, out, spec=None, contexts=()):
    repo = Path(git(repo, "rev-parse", "--show-toplevel").decode().strip()).resolve()
    base_sha = git(repo, "rev-parse", "--verify", f"{base}^{{commit}}").decode().strip()
    head_sha = git(repo, "rev-parse", "--verify", f"{head}^{{commit}}").decode().strip()
    merge_base = git(repo, "merge-base", base_sha, head_sha).decode().strip()
    diff = git(repo, "diff", "--binary", "--full-index", f"{merge_base}..{head_sha}")
    if not diff:
        raise ValueError("empty fixed-range diff; working-tree changes are not included")
    # Validate every requested context before creating output. Ignored local specs are supported.
    sources = {}
    for relative in ([spec] if spec else []) + list(contexts):
        path = inside(repo, relative)
        if not path.is_file():
            raise ValueError(f"missing context: {relative}")
        sources[str(path.relative_to(repo))] = path
    out = Path(out).resolve()
    if out.exists():
        raise ValueError(f"output already exists; use a fresh directory: {out}")
    out.parent.mkdir(parents=True, exist_ok=True)
    # A failed preparation never leaves an apparently complete evidence directory.
    with tempfile.TemporaryDirectory(prefix=".review-", dir=out.parent) as tmp:
        staging = Path(tmp) / "evidence"
        staging.mkdir()
        (staging / "range.diff").write_bytes(diff)
        (staging / "commits.txt").write_bytes(git(repo, "log", "--format=%H %s", f"{base_sha}..{head_sha}"))
        snapshot = staging / "snapshot"
        snapshot.mkdir()
        with tarfile.open(fileobj=io.BytesIO(git(repo, "archive", "--format=tar", head_sha))) as archive:
            archive.extractall(snapshot, filter="data")
        context_info = {}
        for relative, source in sources.items():
            target = staging / "context" / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(source.read_bytes())
            context_info[relative] = {"source": "current checkout (not necessarily HEAD)", "sha256": digest(target)}
        (staging / "README.md").write_text(
            f"# Fixed-range review evidence\n\nBase: `{base_sha}`\n\nHead: `{head_sha}`\n\n"
            f"Merge base: `{merge_base}`\n\n"
            "`range.diff` is merge-base..head, not the working-tree diff. `snapshot/` is the committed head.\n"
            "`context/` contains explicitly supplied local documents, copied at preparation time; it is not head source.\n"
            "Read manifest.json first. Missing or unreadable evidence blocks review, not proof of a code defect.\n"
            "This artifact does not validate a child agent's tool permissions; the dispatcher must check those separately.\n"
        )
        files = {}
        for path in staging.rglob("*"):
            if path.is_file():
                inside(staging, path.relative_to(staging))
                files[str(path.relative_to(staging))] = digest(path)
        manifest = {
            "schema": 1, "base": base_sha, "head": head_sha, "merge_base": merge_base,
            "spec": f"context/{inside(repo, spec).relative_to(repo)}" if spec else None,
            "context": context_info, "files": files,
        }
        (staging / "manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
        check(staging)
        staging.rename(out)
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("base", nargs="?")
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--repo", default=".")
    parser.add_argument("--out", type=Path)
    spec = parser.add_mutually_exclusive_group()
    spec.add_argument("--spec")
    spec.add_argument("--no-spec", action="store_true")
    parser.add_argument("--context", action="append", default=[])
    parser.add_argument("--check", type=Path, help="verify an existing artifact without Git access")
    args = parser.parse_args()
    try:
        if args.check:
            manifest = check(args.check)
            print(f"Review evidence OK: {manifest['base'][:12]}...{manifest['head'][:12]} ({len(manifest['files'])} files)")
        else:
            if not args.base or not args.out or not (args.spec or args.no_spec):
                parser.error("preparation requires BASE, --out and either --spec or --no-spec")
            manifest = prepare(args.repo, args.base, args.head, args.out, args.spec, args.context)
            print(f"Review evidence ready: {args.out.resolve()}\nPinned head: {manifest['head']}\nScope: committed changes only")
        return 0
    except (ValueError, OSError, subprocess.CalledProcessError, tarfile.TarError) as error:
        print(f"Review preflight FAILED: {error}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
