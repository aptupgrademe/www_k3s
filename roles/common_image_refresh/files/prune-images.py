#!/usr/bin/env python3
"""Remove container images that no container on this node uses any more.

Called by common_image_refresh (tasks/prune.yml) at the end of the update
playbooks, after the rebuilt images are running. Old builds of the same tag
and old version tags pile up otherwise (2026-10-22: ~5 GB on the blog, ~3.5 GB
on a Nextcloud host).

Kept although no container uses them right now:
  - pause            the pod sandbox image - sandboxes are not "containers",
                     so it always looks unused
  - busybox          init containers (exited init containers may be gone)
  - cert-manager-acmesolver of the running cert-manager version - only runs
                     during a certificate renewal
  - anything named on the command line (--keep <substring>)
Usage: prune-images.py [--dry-run] [--keep SUBSTRING ...]
Prints one line per removed (or, with --dry-run, removable) image and a
summary line "PRUNED <n> <MB>"; "PRUNED 0" means nothing to do.
"""
import json
import subprocess
import sys

args = sys.argv[1:]
dry = '--dry-run' in args
keep = ['pause:', 'busybox']
for i, a in enumerate(args):
    if a == '--keep' and i + 1 < len(args):
        keep.append(args[i + 1])


def crictl(*a):
    return json.loads(subprocess.run(['k3s', 'crictl', *a, '-o', 'json'], check=True,
                                     capture_output=True, text=True).stdout)


containers = crictl('ps', '-a')['containers']
images = crictl('images')['images']
used = {c['imageRef'] for c in containers} | {c['image']['image'] for c in containers}
# acmesolver: keep the one matching the running cert-manager controller
# (containers reference image IDs, the tag comes from the image list)
for img in images:
    if img['id'] in used:
        for t in img.get('repoTags') or []:
            if 'cert-manager-controller:' in t:
                keep.append('cert-manager-acmesolver:' + t.rsplit(':', 1)[1])

n = size = 0
for img in images:
    names = (img.get('repoTags') or []) + (img.get('repoDigests') or [])
    if img['id'] in used or img.get('pinned') or any(k in nm for nm in names for k in keep):
        continue
    label = names[0] if names else img['id']
    if not dry:
        r = subprocess.run(['k3s', 'crictl', 'rmi', img['id']], capture_output=True, text=True)
        if r.returncode != 0:
            print(f'SKIP {label}: {r.stderr.strip()[:120]}')
            continue
    n += 1
    size += int(img.get('size', 0))
    print(('WOULD REMOVE ' if dry else 'REMOVED ') + label)
print(f'PRUNED {n} {size // 1048576}')
