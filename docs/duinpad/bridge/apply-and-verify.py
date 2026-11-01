#!/usr/bin/env python3
"""Apply this reviewed text-only patch to an exact baseline copy; never resets data."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

HERE=Path(__file__).resolve().parent

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('baseline_copy',type=Path,help='An isolated unpacked Duinpad-Showpakket 2.0.0 copy')
    parser.add_argument('--check',action='store_true',help='Verify baseline and patch without changing anything')
    args=parser.parse_args()
    root=args.baseline_copy.resolve()
    manifest=json.loads((HERE/'patch-manifest.json').read_text())
    patch=HERE/'duinpad-actor-v1.patch'
    if sha(patch)!=manifest['patch_sha256']:
        sys.exit('Patch checksum mismatch; nothing applied')
    for item in manifest['files']:
        path=root/item['path']
        if not path.resolve().is_relative_to(root):
            sys.exit('Invalid manifest path; nothing applied')
        if sha(path)!=item['before_sha256']:
            sys.exit('Baseline mismatch at '+item['path']+'; nothing applied. Preserve and review local changes.')
    subprocess.run(['git','apply','--check',str(patch)],cwd=root,check=True)
    if args.check:
        print('Exact changed-file baseline and patch verified; nothing changed')
        return
    subprocess.run(['git','apply',str(patch)],cwd=root,check=True)
    for item in manifest['files']:
        if sha(root/item['path'])!=item['after_sha256']:
            sys.exit('Post-apply checksum mismatch at '+item['path'])
    print('Text patch applied and verified. No runtime data, media or hardware was changed.')

if __name__=='__main__':main()
