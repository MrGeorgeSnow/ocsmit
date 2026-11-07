# ocsmit

**SMIT/smitty-style menus for OpenShift.** `ocsmit.sh` lets you review and update an OpenShift cluster through numbered menus and fill-in entry screens, the way `smitty` works on AIX. Every change shows the exact `oc` command and asks **ARE YOU SURE?** before it runs.

```
                    Workloads (Deployments, Pods, Rollouts)
--------------------------------------------------------------------------------
 Server : https://api.crc.testing:6443
 User   : kubeadmin                    Project: myapp
--------------------------------------------------------------------------------
 Type the number of the desired item and press Enter.

    1  List Deployments
    2  List Pods
    3  Show Deployment Details
    4  Scale a Deployment
   ...
 b=Back  q=Exit  /=Fastpath  r=Refresh  l=Log  ?=Help
```

## Features

- 11 menus: cluster health, projects, workloads, ConfigMaps/Secrets/env, networking, storage, security & users (RBAC, SCC, HTPasswd), nodes, cluster configuration, OpenShift Virtualization / MTV migrations, settings
- `?` in any field opens a pick list of live cluster objects (like smitty F4)
- ARE YOU SURE? and COMMAND STATUS screens
- `~/.ocsmit/ocsmit.log` (every command) and `~/.ocsmit/ocsmit.script` (every successful change, replayable), like `smit.log` / `smit.script`
- Automatic YAML backups before edits, patches and deletes, with restore from the menu
- Dry-run mode (`-d`) and fastpaths (`ocsmit scale`, `ocsmit vm`, `ocsmit drain`, ...)

## Install

```bash
git clone https://github.com/MrGeorgeSnow/ocsmit.git
cd ocsmit
install -m 755 ocsmit.sh ~/bin/ocsmit      # or: sudo install -m 755 ocsmit.sh /usr/local/bin/ocsmit
oc login https://api.crc.testing:6443 -u kubeadmin
ocsmit
```

Requires bash 3.2+ and the `oc` CLI. Optional: `virtctl` (VM console), `htpasswd` (user management), `less`.

## Documentation

- [docs/MANUAL.md](docs/MANUAL.md) — install guide and full user manual
- [docs/ocsmit-Install-Guide-and-Manual.docx](docs/ocsmit-Install-Guide-and-Manual.docx) — the same manual in Word format

## Usage

```
ocsmit [-d] [-B] [-h] [-V] [fastpath]
  -d   dry-run: show commands, never execute changes
  -B   no YAML backups
  -h   help and list of fastpaths
  -V   version
```
