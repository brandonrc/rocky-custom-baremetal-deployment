# Rocky Linux image mode on bare metal, with Artifact Keeper as the source of truth

This repository is a working proof of concept for running Rocky Linux 10 edge nodes in
**image mode**: the operating system is delivered as a bootc container image, installed and
updated by ostree, instead of being assembled package by package on each machine. One
[Artifact Keeper](https://github.com/artifact-keeper/artifact-keeper) instance holds
everything a node boots from: the Rocky and RKE2 RPMs, our own site-configuration RPM, the
bootc images and the public keys. An edge node (a QEMU VM in this PoC) installs from it with
the stock Rocky installer and a kickstart, comes up running RKE2, and is upgraded and rolled
back with `bootc` against the same registry. Every RPM, repo index and image is signed, and
the build host, the installer and the node each refuse anything unsigned.

!!! info "Read the blog post"
    The write-up behind this repository is on the OpenTeams engineering blog:
    [Rocky Linux Image Mode on Bare Metal, with Artifact Keeper as the Source of Truth](https://openteams.com/rocky-linux-image-mode-artifact-keeper/).
    More posts: <https://openteams.com/engineering-blog/>.

## Start here

<div class="grid cards" markdown>

-   **Run it yourself**

    ---

    [Environment setup](environment.md), then the [Walkthrough](walkthrough.md).
    About 3 minutes from power-on to a working cluster with KVM, about 17 minutes without.

-   **Understand the design and Artifact Keeper's role**

    ---

    [Architecture](architecture.md), then
    [What Artifact Keeper does here](artifact-keeper.md).

-   **Hit the same error**

    ---

    [Troubleshooting](troubleshooting.md) (one section per error string), then the
    [Findings overview](findings.md).

</div>

## One registry, every consumer

```mermaid
flowchart TB
  subgraph up[Upstream]
    direction LR
    rocky[Rocky mirror]
    rancher[Rancher RPMs]
    hub[quay.io, Docker Hub]
  end

  subgraph ak["Artifact Keeper :30080"]
    direction LR
    rpmproxy[RPM proxies]
    rpmsite[rpm-edge-site]
    ocibootc[oci-bootc]
    ociproxy[OCI proxies]
    keys[raw-edge-keys]
  end

  subgraph build[Build host]
    direction LR
    basebuild[base image build]
    rpmbuild[site RPM build]
    imgbuild[edge image build]
  end

  subgraph node["Edge node"]
    direction LR
    anaconda[installer]
    bootc[bootc upgrade]
    rke2[RKE2 containerd]
  end

  rocky --> rpmproxy
  rancher --> rpmproxy
  hub --> ociproxy

  rpmproxy --> basebuild
  basebuild -->|push, sign| ocibootc
  rpmbuild -->|upload| rpmsite
  ocibootc -->|verified FROM| imgbuild
  rpmproxy --> imgbuild
  rpmsite --> imgbuild
  imgbuild -->|push, sign| ocibootc

  keys -->|cosign key| anaconda
  ocibootc -->|verified pull| anaconda
  ocibootc -->|verified pull| bootc
  ociproxy -->|docker.io mirror| rke2
```

The repositories behind each box, their upstreams and the three addresses the registry has
are on the [Architecture](architecture.md) page. The step-by-step pipeline is at the top of
the [Walkthrough](walkthrough.md).

Source: [github.com/brandonrc/rocky-custom-baremetal-deployment](https://github.com/brandonrc/rocky-custom-baremetal-deployment).
Each top-level directory there (`registry/`, `signing/`, `base/`, `rpms/`, `image/`, `deploy/`)
has a README with the directory-specific details.
