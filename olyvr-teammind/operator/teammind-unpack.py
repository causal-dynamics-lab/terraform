#!/usr/bin/env python3
"""Check a TeamMind backup set and stream it, decrypted, to teammind-restore on a server:

    teammind-unpack.py ./teammind-<host>-<time> | ssh ubuntu@<ip> sudo teammind-restore -

Runs on the operator's machine, which holds the age private key; the server never does. Before anything is
sent it refuses the set unless (olyvr-teammind/docs/teammind-backup-recovery.md, "Encryption and signing"):

1. manifest.json.age.sig verifies against a key in the operator's own allowed-signers file (never one that came
   with the set), in the teammind-backup namespace;
2. the decrypted manifest names this set, and its host and time are shown for the operator to confirm (a store
   that hands back an older valid set is seen, not trusted);
3. both payloads' ciphertexts match the manifest's digests.

Then it writes a tar to stdout: manifest.json, db.dump, state.tar.zst, each decrypted on the fly and hashed as it
goes, so the plain dump never lands on this disk. A plaintext that doesn't match the manifest stops the stream, and
teammind-restore checks every digest again before it touches the server.

The set is a folder holding db.dump.age, state.tar.zst.age, manifest.json.age and its .sig (as object stores and
the pull keep it), or a folder of flat <set>.<file> names (as an SFTP destination keeps it; give --set).

Needs: python3, age, ssh-keygen (OpenSSH 8.2 or later). Defaults: --identity $TEAMMIND_AGE_IDENTITY or
~/.config/teammind/age.key; --allowed-signers ~/.config/teammind/allowed_signers, lines of
`<host> namespaces="teammind-backup" <public key>` from each server's signing_key_command.
"""
from __future__ import annotations

import argparse
import calendar
import hashlib
import json
import os
import subprocess
import sys
import tarfile
import tempfile
import time
from pathlib import Path

NAMESPACE = "teammind-backup"
PAYLOADS = ("db.dump", "state.tar.zst")


def fail(message: str) -> None:
    """Stop at once: no tar trailer is written, so a half-sent set never looks complete to the receiving side."""
    print(f"teammind-unpack: {message}", file=sys.stderr)
    sys.stderr.flush()
    os._exit(1)


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def locate(folder: Path, set_name: str) -> dict[str, Path]:
    """The set's four files, under their plain names or as flat <set>.<name>."""
    found = {}
    for name in ("db.dump.age", "state.tar.zst.age", "manifest.json.age", "manifest.json.age.sig"):
        for candidate in (folder / name, folder / f"{set_name}.{name}"):
            if candidate.is_file():
                found[name] = candidate
                break
        else:
            fail(f"{folder} has no {name} for set {set_name}")
    return found


def verify_signature(manifest: Path, sig: Path, allowed: Path) -> str:
    if not allowed.is_file():
        fail(f"no allowed-signers file at {allowed}: add each server's signing key there first (signing_key_command)")
    found = subprocess.run(["ssh-keygen", "-Y", "find-principals", "-s", str(sig), "-f", str(allowed)],
                           capture_output=True, text=True)
    principals = found.stdout.split()
    if found.returncode != 0 or not principals:
        fail("the manifest's signature is from no key in your allowed-signers file: not a set from a server you know")
    for principal in principals:
        with manifest.open("rb") as data:
            ok = subprocess.run(["ssh-keygen", "-Y", "verify", "-f", str(allowed), "-I", principal, "-n", NAMESPACE,
                                 "-s", str(sig)], stdin=data, capture_output=True)
        if ok.returncode == 0:
            return principal
    fail("the manifest's signature doesn't verify")
    return ""


def decrypt_bytes(path: Path, identity: Path) -> bytes:
    out = subprocess.run(["age", "-d", "-i", str(identity), str(path)], capture_output=True)
    if out.returncode != 0:
        fail(f"can't decrypt {path.name} with {identity}: {out.stderr.decode().strip()}")
    return out.stdout


class Hashing:
    """A reader that hashes what passes through it."""

    def __init__(self, raw):
        self.raw, self.hash, self.count = raw, hashlib.sha256(), 0

    def read(self, size: int = -1) -> bytes:
        data = self.raw.read(size)
        self.hash.update(data)
        self.count += len(data)
        return data


def confirm(manifest: dict, principal: str, assume_yes: bool) -> None:
    age = time.time() - calendar.timegm(time.strptime(manifest["created"], "%Y-%m-%dT%H:%M:%SZ"))
    print(f"set      {manifest['set']}\nsigned   by {principal}\nhost     {manifest['host']}\n"
          f"created  {manifest['created']} ({age / 3600:.1f} hours ago)\n"
          f"olyvr    {manifest['versions'].get('olyvr_version') or manifest['versions'].get('olyvr_commit')}\nrows     "
          + ", ".join(f"{t} {n}" for t, n in sorted(manifest["counts"].items())), file=sys.stderr)
    if assume_yes:
        return
    try:
        with open("/dev/tty", "r+") as tty:
            tty.write("Restore this set? [y/N] ")
            tty.flush()
            if tty.readline().strip().lower() not in ("y", "yes"):
                fail("not confirmed")
    except OSError:
        fail("no terminal to confirm on; check the lines above and pass --yes")


def main() -> None:
    home = Path.home() / ".config" / "teammind"
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0], formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("folder", type=Path)
    p.add_argument("--set", dest="set_name", help="the set's name (default: the folder's name)")
    p.add_argument("--identity", type=Path, default=Path(os.environ.get("TEAMMIND_AGE_IDENTITY", home / "age.key")))
    p.add_argument("--allowed-signers", type=Path, default=home / "allowed_signers")
    p.add_argument("--yes", action="store_true", help="don't ask on the terminal before streaming")
    args = p.parse_args()

    folder = args.folder.resolve()
    set_name = args.set_name or folder.name
    if sys.stdout.isatty():
        fail("stdout is a terminal; pipe it to ssh … sudo teammind-restore -")
    files = locate(folder, set_name)

    principal = verify_signature(files["manifest.json.age"], files["manifest.json.age.sig"], args.allowed_signers)
    manifest_bytes = decrypt_bytes(files["manifest.json.age"], args.identity)
    manifest = json.loads(manifest_bytes)
    if manifest.get("format") != 1:
        fail(f"unknown manifest format {manifest.get('format')}")
    if manifest.get("set") != set_name:
        fail(f"the manifest is for set {manifest.get('set')}, not {set_name}: the files were swapped")
    for name in PAYLOADS:
        if sha256_file(files[f"{name}.age"]) != manifest["files"][name]["age_sha256"]:
            fail(f"{name}.age doesn't match the signed manifest")
    confirm(manifest, principal, args.yes)

    try:
        stream(manifest, manifest_bytes, files, args.identity)
    except BrokenPipeError:
        fail("the receiving side stopped; its own output says why")
    print(f"streamed {set_name}", file=sys.stderr)


def stream(manifest: dict, manifest_bytes: bytes, files: dict[str, Path], identity: Path) -> None:
    with tarfile.open(fileobj=sys.stdout.buffer, mode="w|", format=tarfile.PAX_FORMAT) as tar:
        info = tarfile.TarInfo("manifest.json")
        info.size, info.mtime, info.mode = len(manifest_bytes), int(time.time()), 0o600
        with tempfile.SpooledTemporaryFile() as buf:
            buf.write(manifest_bytes)
            buf.seek(0)
            tar.addfile(info, buf)
        for name in PAYLOADS:
            expected = manifest["files"][name]
            proc = subprocess.Popen(["age", "-d", "-i", str(identity), str(files[f"{name}.age"])],
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            reader = Hashing(proc.stdout)
            info = tarfile.TarInfo(name)
            info.size, info.mtime, info.mode = expected["size"], int(time.time()), 0o600
            try:
                tar.addfile(info, reader)
            except BrokenPipeError:
                proc.kill()
                fail("the receiving side stopped; its own output says why")
            except (OSError, tarfile.TarError) as exc:
                proc.kill()
                fail(f"{name}: {exc}")
            if proc.wait() != 0:
                fail(f"can't decrypt {name}: {proc.stderr.read().decode().strip()}")
            if reader.hash.hexdigest() != expected["sha256"]:
                fail(f"{name} decrypted to other bytes than the manifest's: stream stopped")


if __name__ == "__main__":
    main()
