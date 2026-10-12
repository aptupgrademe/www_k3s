#!/usr/bin/env python3
"""Which Deployments of a namespace run an outdated build of their image tag?

Docker Hub rebuilds unchanged tags (nextcloud:34.0.4-fpm, nginx:1.30.5-alpine,
...) for base-image security fixes, and K3s never re-pulls on its own
(imagePullPolicy IfNotPresent). For every Deployment in the namespace this
pulls the current build of each container/init-container image and compares
its digest with what the Deployment's running pods were started from.

--no-pull compares with the images already on the host instead (read-only,
for testing).

Prints JSON: {"<deployment>": ["<image that was rebuilt>", ...], ...}
(only Deployments with at least one rebuilt image). Managed by Ansible
(role common_image_refresh) - runs on the host via the script module.
"""
import json
import subprocess
import sys

ns = sys.argv[1]
pull = "--no-pull" not in sys.argv[2:]


def kubectl_json(*args):
    out = subprocess.check_output(["k3s", "kubectl", *args, "-n", ns, "-o", "json"])
    return json.loads(out)["items"]


def registry_ref(image):
    """nginx:1.30 -> docker.io/library/nginx:1.30, a/b:1 -> docker.io/a/b:1"""
    first = image.split("/")[0]
    if "/" in image and ("." in first or ":" in first or first == "localhost"):
        return image                      # already has a registry host
    return ("docker.io/" if "/" in image else "docker.io/library/") + image


deployments = kubectl_json("get", "deployments")
pods = kubectl_json("get", "pods")
digests = {}                              # pull each image only once
result = {}

for dep in deployments:
    name = dep["metadata"]["name"]
    selector = dep["spec"]["selector"].get("matchLabels", {})
    running = set()
    for pod in pods:
        labels = pod["metadata"].get("labels", {})
        if all(labels.get(k) == v for k, v in selector.items()):
            status = pod.get("status", {})
            for cs in status.get("containerStatuses", []) + status.get("initContainerStatuses", []):
                running.add(cs.get("imageID", ""))
    spec = dep["spec"]["template"]["spec"]
    rebuilt = []
    for container in spec.get("initContainers", []) + spec["containers"]:
        image = container["image"]
        if image not in digests:
            ref = registry_ref(image)
            if pull:
                subprocess.run(["crictl", "pull", ref], check=True, stdout=subprocess.DEVNULL)
            info = json.loads(subprocess.check_output(["crictl", "inspecti", "-o", "json", ref]))
            digests[image] = info["status"]["repoDigests"]
        if not any(d in running for d in digests[image]) and image not in rebuilt:
            rebuilt.append(image)
    if rebuilt:
        result[name] = rebuilt

print(json.dumps(result))
