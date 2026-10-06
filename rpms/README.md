# rpms/ — edge-site-config

A small noarch RPM that carries everything site-specific, so the OS image
stays generic and a site change is "bump a release, rebuild, `bootc upgrade`".

| File installed | Purpose |
|---|---|
| `/etc/rancher/rke2/config.yaml` | single-node server, `write-kubeconfig-mode: "0644"`, `selinux: true`, `tls-san` localhost/127.0.0.1 |
| `/etc/rancher/rke2/registries.yaml` | `docker.io` mirror `http://10.0.2.2:30080` with `rewrite "^(.*)$" -> "oci-dockerhub-proxy/$1"` |
| `/etc/containers/registries.conf.d/50-artifact-keeper.conf` | `10.0.2.2:30080` insecure, for `bootc upgrade`/`switch` |
| `/etc/NetworkManager/conf.d/rke2-canal.conf` | NetworkManager ignores CNI interfaces (RKE2 known issue) |
| `/etc/motd.d/edge` | MOTD with the package version-release (day-2 is visible at login) |
| `/usr/share/edge-site/manifests/nginx-demo.yaml` | Deployment + NodePort Service (30090), `docker.io/library/nginx:alpine` |
| `/usr/lib/systemd/system/edge-site-manifests.service` | oneshot, `Before=rke2-server.service`, copies the manifests into `/var/lib/rancher/rke2/server/manifests/` on every boot |
| `/usr/lib/systemd/system-preset/80-edge-site.preset` | enables the oneshot |

Release 1 vs 2 differ only in the MOTD note and the `edge-site/config-release`
label on the nginx Deployment/pod template/Service (`--define "rel N"`).
`Requires: rke2-server`.

## Usage

```bash
make rpm                 # = rpms/build.sh && rpms/upload.sh
RELEASES=3 rpms/build.sh # another release (add a %changelog entry)
```

- `build.sh`: `rpmbuild` inside `localhost:30080/oci-quay-proxy/rockylinux/rockylinux:10`
  (rootless), dnf restricted to the Artifact Keeper Rocky proxies. Output in `rpms/out/`.
- `upload.sh`: `PUT /rpm/rpm-edge-site/packages/<file>` with the CI token, then
  reads the server-generated `repodata/primary.xml.gz` and fails unless every
  uploaded release is listed. An existing file returns HTTP 409 and is left
  as is (Artifact Keeper does not overwrite; bump the release instead).
