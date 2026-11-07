---
title: "ocsmit.sh — Install Guide & User Manual"
subtitle: "Version 1.0 · November 7, 2026 · George"
---

## 1. Overview

`ocsmit.sh` gives OpenShift an AIX smitty-style menu interface: numbered menus, fill-in entry screens, and a confirmation screen before every change. Under the covers it runs ordinary `oc` (and optionally `virtctl`) commands, so anything it does you could also type by hand.

What it adds on top of `oc`:

- **ARE YOU SURE? screen** — every change shows the exact command (and any YAML it generated) before it runs.
- **COMMAND STATUS screen** — shows OK or failed, the return code and the output, like smitty.
- **Pick lists** — type `?` in a field to choose from live cluster objects (the smitty F4 list).
- **Logs** — `ocsmit.log` records every command; `ocsmit.script` records every successful change as a replayable `oc` command (like `smit.log` and `smit.script`).
- **Automatic YAML backups** — objects are saved before they are edited, patched or deleted, and can be restored from the menu.
- **Dry-run mode** — preview commands without changing anything.
- **Fastpaths** — jump straight to a screen, e.g. `ocsmit.sh scale` (like `smitty mktcpip`).

It covers 11 areas: cluster health, projects, workloads, application configuration, networking, storage, security and users, nodes, cluster configuration, OpenShift Virtualization / MTV migrations, and its own settings.

## 2. Requirements

You need bash, the `oc` client and a cluster login; everything else is optional.

| Item | Needed? | Used for | Where to get it |
| --- | --- | --- | --- |
| Linux or macOS workstation / bastion | Required | Running the script | RHEL, Fedora, Debian, Ubuntu, macOS all work |
| bash 3.2 or later | Required | The script itself | Built in on Linux and macOS |
| `oc` (OpenShift CLI) | Required | Every command | Web console → ? → Command line tools, or `crc oc-env` on OpenShift Local |
| Cluster login | Required | Talking to the API | `oc login`, or the script's own login screen |
| `less` | Optional | Paging long output | Usually pre-installed; without it output is printed and paused |
| `virtctl` | Optional | VM console; preferred for VM start/stop/restart/migrate | Web console → ? → Command line tools (needs OpenShift Virtualization) |
| `htpasswd` | Optional | Adding / removing HTPasswd users | `httpd-tools` (RHEL/Fedora), `apache2-utils` (Debian/Ubuntu), built in on macOS |
| `tput` | Optional | Screen width and colour | ncurses; falls back to 80 columns, no colour |

**Cluster permissions.** Read-only screens work for any user who can see the objects. Cluster-wide screens (nodes, cluster operators, cluster configuration, SCCs, HTPasswd, storage classes) need `cluster-admin`, e.g. `kubeadmin` on OpenShift Local (CRC). Project-level screens need `admin` or `edit` in that project.

**Add-ons.** The Virtualization menu needs the OpenShift Virtualization operator; its MTV items need the Migration Toolkit for Virtualization operator (default namespace `openshift-mtv`). NMState items need the Kubernetes NMState operator.

## 3. Installation

Installation is one file copied onto your PATH; there is nothing to compile and no root access is needed for a personal install.

1. **Copy the script** to the machine where you run `oc` (your workstation, a bastion host, or the OpenShift Local server).

    ```bash
    scp ocsmit.sh user@host:~/
    ```

2. **Make it executable and put it on your PATH.** Choose one:

    ```bash
    # Personal install (no sudo)
    mkdir -p ~/bin
    install -m 755 ~/ocsmit.sh ~/bin/ocsmit
    echo 'export PATH="$HOME/bin:$PATH"' >> ~/.bashrc   # macOS zsh: ~/.zshrc

    # System-wide install (all users)
    sudo install -m 755 ~/ocsmit.sh /usr/local/bin/ocsmit
    ```

3. **Make sure `oc` is on the PATH.** On an OpenShift Local (CRC) host:

    ```bash
    eval $(crc oc-env)
    oc version --client
    ```

4. **Optional tools.** Install the ones you need from section 2:

    ```bash
    sudo dnf install httpd-tools less      # RHEL / Fedora
    sudo apt install apache2-utils less    # Debian / Ubuntu
    ```

    For `virtctl`, download it from the web console (? → Command line tools), then `install -m 755 virtctl ~/bin/`.

5. **Verify the install.**

    ```bash
    ocsmit -V      # prints: ocsmit 1.0
    ocsmit -h      # prints the built-in help
    ```

6. **Log in to the cluster** (or let ocsmit prompt you on first start):

    ```bash
    oc login https://api.crc.testing:6443 -u kubeadmin
    ```

On first run ocsmit creates `~/.ocsmit/` (mode 700) for its log, change script and backups. If you prefer not to rename the file, the commands in this manual work the same as `./ocsmit.sh`.

## 4. Quick start

This walkthrough scales a deployment from 2 to 3 replicas in dry-run mode first, then for real.

1. Start in preview mode: `ocsmit -d`. The header shows **[DRY-RUN]**.
2. At the main menu type `3` (Workloads), then `4` (Scale a Deployment).
3. At **Project (namespace)** press Enter to accept your current project, or type `?` and pick one by number.
4. At **Deployment** type `?`, then the number of the deployment.
5. At **Number of replicas** the current value is shown in brackets, e.g. `[2]`. Type `3` and press Enter.
6. The **ARE YOU SURE?** screen shows `oc scale deploy/web --replicas=3 -n myapp`. In dry-run mode it is only recorded in `ocsmit.script`.
7. Press `q` to quit, then run `ocsmit` without `-d` and repeat. This time answer `y` to **Continue?**.
8. The **COMMAND STATUS** screen shows `Command: OK` and the output. Press Enter to go back to the menu.

What a typical screen looks like:

```
              Workloads (Deployments, Pods, Rollouts)
-----------------------------------------------------------------
 Server : https://api.crc.testing:6443
 User   : kubeadmin                    Project: myapp
-----------------------------------------------------------------
 Type the number of the desired item and press Enter.

    1  List Deployments
    2  List Pods
    3  Show Deployment Details
    4  Scale a Deployment
   ...
 b=Back  q=Exit  /=Fastpath  r=Refresh  l=Log  ?=Help
 Selection:
```

## 5. Using the interface

There are four kinds of screen: menus, entry screens, the ARE YOU SURE? screen and the COMMAND STATUS screen. Every screen's header shows the API server, your user name, your current project, and the **[DRY-RUN]** or **[NO-BACKUP]** flags when they are on.

### Menu keys

| Key | Action |
| --- | --- |
| `1`–`n` | Select the numbered item |
| `b` | Back to the previous menu |
| `q` | Exit ocsmit |
| `/name` | Jump to a fastpath, e.g. `/scale` (section 6) |
| `r` | Refresh the server / user / project shown in the header |
| `l` | Show the command log |
| `?` | Help screen |
| Ctrl-C | At a menu: exit. While a command runs: stops that command only |

### Entry fields

Entry screens ask one field at a time, the way a smitty dialog lists fields.

| You see / type | Meaning |
| --- | --- |
| `*` before the field | Required field |
| `[value]` after the prompt | Default; press Enter to accept it |
| `(?=list)` | A pick list is available: type `?` for a numbered list of live objects (like F4) |
| `!` | Cancel the whole dialog and return to the menu |
| Tab | Filename completion in path fields |
| Arrow keys | Line editing and history |

Some screens collect several **KEY=VALUE** lines (ConfigMap and Secret literals, environment variables). Enter one per line; values may contain spaces. A blank line finishes the list.

### ARE YOU SURE?

Shown before anything that changes the cluster. It displays the exact command, any warning (for example a single-node drain) and any generated YAML. Answer `y` to run it; anything else cancels. Deletes of projects, PVCs and HTPasswd users first ask you to type the object's name.

### COMMAND STATUS

Shown after every command: `Command: OK` or `Command: failed (rc=N)`, the command line, then the output (paged with `less` when it is longer than the screen; press `q` to leave the pager).

Interactive commands — `oc edit`, `oc rsh`, live log follow, port-forward, node debug and the VM console — take over the terminal directly. When they end you get the same OK / failed line.

## 6. Command line, settings and fastpaths

```
ocsmit [-d] [-B] [-h] [-V] [fastpath]
```

| Option | Effect |
| --- | --- |
| `-d` | Dry-run: show and record commands, never execute changes |
| `-B` | Turn off automatic YAML backups for this session |
| `-h` | Print help |
| `-V` | Print version |
| `fastpath` | Open that screen directly; ocsmit exits when you leave it (except `main`) |

### Environment variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `OC` | `oc` | CLI to run, e.g. `OC=kubectl` or a full path |
| `OCSMIT_HOME` | `~/.ocsmit` | Where the log, change script and backups are kept |
| `OCSMIT_DRYRUN` | `no` | `yes` starts in dry-run mode |
| `OCSMIT_BACKUP` | `yes` | `no` starts with backups off |
| `MTV_NS` | `openshift-mtv` | Default namespace for MTV migration plans |
| `TMPDIR` | `/tmp` | Where generated YAML is written briefly |

Example: `OCSMIT_HOME=/srv/ocsmit MTV_NS=mtv-lab ocsmit vm`

### Fastpaths

Use them on the command line (`ocsmit drain`) or from any menu (`/drain`).

| Fastpath | Opens |
| --- | --- |
| `main`, `top` | Main menu |
| `health`, `cluster` | Cluster Information & Health |
| `proj`, `project`, `projects` | Projects |
| `workload`, `workloads`, `deploy` | Workloads |
| `scale` | Scale a Deployment |
| `restart` | Restart a Deployment |
| `image` | Change Container Image |
| `logs`, `log` | View Pod Logs |
| `rsh` | Open Remote Shell in a Pod |
| `config`, `cm`, `secret` | Application Configuration |
| `env` | Set / Update Environment Variables |
| `net`, `network`, `route` | Networking |
| `netpol` | Apply a NetworkPolicy Template |
| `storage`, `pvc` | Storage |
| `security`, `rbac`, `user`, `users` | Security & Users |
| `htpasswd` | Add / Change HTPasswd User Password |
| `nodes`, `node` | Nodes & Machine Config |
| `drain` | Drain a Node |
| `clustercfg`, `operators`, `co` | Cluster Configuration |
| `upgrade` | Show Update Status |
| `virt`, `vm`, `vms`, `mtv` | Virtualization & VM Migration |
| `settings` | ocsmit Settings, Logs & Backups |
| `login` | Log In to a Cluster |

## 7. Menu reference

Each table lists a menu's items in order with the command it runs. **Change** marks items that modify the cluster (ARE YOU SURE? shown); **Backup** marks items that save YAML first.

### 1 Cluster Information & Health

| # | Item | Runs |
| --- | --- | --- |
| 1 | Show Cluster Version | `oc get clusterversion` |
| 2 | Show Console URL and Login Identity | `oc whoami`, `--show-console`, `oc version` |
| 3 | List Cluster Operators | `oc get clusteroperators` |
| 4 | Show Degraded / Unavailable Operators | Operators not Available or Degraded=True |
| 5 | List Nodes and Status | `oc get nodes -o wide` |
| 6 | Node Resource Usage | `oc adm top nodes` |
| 7 | Pods Not Running | `oc get pods -A` excluding Running / Succeeded |
| 8 | Recent Warning Events | `oc get events -A --field-selector=type=Warning` |
| 9 | List Certificate Signing Requests | `oc get csr` |
| 10 | Approve All Pending CSRs — Change | `oc adm certificate approve <pending>` |
| 11 | Collect must-gather Diagnostics | `oc adm must-gather --dest-dir=…` |

### 2 Projects

| # | Item | Runs |
| --- | --- | --- |
| 1 | List All Projects | `oc get projects` |
| 2 | Change Current Project | `oc project <name>` |
| 3 | Show Project Details, Quotas & Limits | `oc describe project`, `oc get resourcequota,limitrange` |
| 4 | Create a Project — Change | `oc new-project` (display name, description) |
| 5 | Set a Resource Quota — Change | `oc create quota --hard=requests.cpu,requests.memory,pods,persistentvolumeclaims` |
| 6 | Show Events in a Project | `oc get events --sort-by=.lastTimestamp` |
| 7 | Delete a Project — Change, type name | `oc delete project` |

### 3 Workloads

| # | Item | Runs |
| --- | --- | --- |
| 1–3 | List Deployments / Pods, Show Details | `oc get deploy`, `oc get pods`, `oc describe deploy` |
| 4 | Scale a Deployment — Change | `oc scale deploy/<d> --replicas=N` |
| 5 | Restart a Deployment — Change | `oc rollout restart` |
| 6 | Show Rollout History | `oc rollout history` |
| 7 | Roll Back — Change, Backup | `oc rollout undo [--to-revision]` |
| 8 | Change Container Image — Change, Backup | `oc set image deploy/<d> <container>=<image>` |
| 9 | Set CPU / Memory Requests and Limits — Change, Backup | `oc set resources --requests --limits` |
| 10 | Configure Autoscaling — Change | `oc autoscale --min --max --cpu-percent` |
| 11 | Edit Deployment YAML — Backup | `oc edit deploy` |
| 12 | View Pod Logs | `oc logs --tail [-c] [--previous] [-f]` |
| 13 | Open Remote Shell | `oc rsh` |
| 14 | Delete (recycle) a Pod — Change | `oc delete pod` |
| 15 | Deploy from an Image — Change | `oc new-app --image --name` |

### 4 Application Configuration

| # | Item | Runs |
| --- | --- | --- |
| 1–2 | List / Show ConfigMap | `oc get configmaps`, `-o yaml` |
| 3 | Create ConfigMap from Key=Value — Change | `oc create configmap --from-literal` |
| 4 | Create ConfigMap from a File — Change | `oc create configmap --from-file=[key=]path` |
| 5–6 | Edit / Delete ConfigMap — Backup | `oc edit`, `oc delete configmap` |
| 7 | List Secrets | `oc get secrets` |
| 8 | Show a Secret (decoded) | `oc extract secret/<s> --to=-` (asks first; values shown in clear text) |
| 9 | Create a Generic Secret — Change | `oc create secret generic --from-literal` |
| 10 | Edit a Secret — Backup | `oc edit secret` (data is base64; use `stringData:` for plain text) |
| 11 | Show Environment Variables | `oc set env --list` |
| 12 | Set / Update Env Vars — Change, Backup | `oc set env deploy/<d> K=V …` (triggers a rollout) |
| 13 | Remove an Env Var — Change, Backup | `oc set env deploy/<d> K-` |
| 14 | Load Env from ConfigMap/Secret — Change, Backup | `oc set env --from=configmap/<n> [--prefix]` |
| 15 | Mount ConfigMap/Secret as Volume — Change, Backup | `oc set volume --add --type=configmap\|secret --mount-path` |

### 5 Networking

| # | Item | Runs |
| --- | --- | --- |
| 1–3 | List Services / Routes, Show Route | `oc get svc`, `oc get routes`, `oc describe route` |
| 4 | Expose a Service as HTTP Route — Change | `oc expose svc/<s> [--hostname]` |
| 5 | Create Secure (edge TLS) Route — Change | `oc create route edge --insecure-policy=Redirect` |
| 6 | Delete a Route — Change, Backup | `oc delete route` |
| 7 | List NetworkPolicies | `oc get networkpolicy` |
| 8 | Apply a NetworkPolicy Template — Change | `oc apply -f` one of: deny-all, allow-same-namespace, allow-from-ingress, allow-from-monitoring |
| 9 | Delete a NetworkPolicy — Change, Backup | `oc delete networkpolicy` |
| 10 | Port-Forward to a Pod | `oc port-forward pod/<p> LOCAL:REMOTE` |

### 6 Storage

| # | Item | Runs |
| --- | --- | --- |
| 1–3 | List PVCs / PVs / Storage Classes | `oc get pvc`, `pv`, `storageclass` |
| 4 | Create a PVC — Change | `oc apply -f` generated PVC (size, class, access mode, volume mode) |
| 5 | Expand a PVC — Change, Backup | `oc patch pvc` new size (class must allow expansion; cannot shrink) |
| 6 | Add a PVC Volume to a Deployment — Change, Backup | `oc set volume --add --type=pvc --claim-name` |
| 7 | Set the Default Storage Class — Change, Backup | Annotates new default `true`, old default `false` |
| 8 | Delete a PVC — Change, type name, Backup | `oc delete pvc` |

### 7 Security & Users

| # | Item | Runs |
| --- | --- | --- |
| 1–3 | List Users/Identities, Groups, Role Bindings | `oc get users,identities`, `groups`, `rolebindings` |
| 4 | Who Can Perform an Action? | `oc adm policy who-can <verb> <resource>` |
| 5–7 | Grant / Remove Project Role — Change | `oc adm policy add-role-to-user\|add-role-to-group\|remove-role-from-user` |
| 8–9 | Grant / Remove Cluster Role — Change | `oc adm policy add-cluster-role-to-user\|remove-cluster-role-from-user` |
| 10–11 | Create Group, Add Users — Change | `oc adm groups new`, `add-users` |
| 12–13 | List / Create Service Account | `oc get sa`, `oc create serviceaccount` |
| 14–15 | List SCCs, Grant SCC to SA — Change | `oc get scc`, `oc adm policy add-scc-to-user -z` |
| 16 | Show Identity Providers | `oc get oauth cluster -o yaml` |
| 17 | Add / Change HTPasswd User — Change, Backup | Updates the HTPasswd secret in `openshift-config` via `oc set data` |
| 18 | Remove an HTPasswd User — Change, type name, Backup | Removes the entry, then deletes the `user` and `identity` objects |

Passwords are typed hidden, passed to `htpasswd` on standard input (never on the command line), and the temporary file is removed. Allow 1–2 minutes for the OAuth pods to restart before logging in.

### 8 Nodes & Machine Config

| # | Item | Runs |
| --- | --- | --- |
| 1–4 | List Nodes (wide, labels), Details, top | `oc get nodes`, `oc describe node`, `oc adm top nodes` |
| 5 | View Node Service Logs | `oc adm node-logs -u kubelet\|crio\|NetworkManager\|ovs-vswitchd --tail` |
| 6–7 | Cordon / Uncordon — Change | `oc adm cordon`, `oc adm uncordon` |
| 8 | Drain a Node — Change | `oc adm drain --ignore-daemonsets --delete-emptydir-data --force --timeout` (warns on single-node clusters) |
| 9 | Node Label — Change | `oc label node <n> key=value \| key- --overwrite` |
| 10 | Node Taint — Change | `oc adm taint nodes <n> key=value:Effect \| key-` |
| 11 | Debug Shell on a Node | `oc debug node/<n>` (then `chroot /host`) |
| 12–13 | Machine Config Pools / Configs | `oc get machineconfigpool`, `machineconfig` |

### 9 Cluster Configuration

| # | Item | Runs |
| --- | --- | --- |
| 1 | List Cluster Operators | `oc get clusteroperators` |
| 2 | Update Status and Available Versions | `oc adm upgrade` |
| 3 | Change the Update Channel — Change, Backup | `oc adm upgrade channel <channel>` |
| 4–5 | View / Edit a Cluster Config Resource — Backup | `oc get\|edit <kind>.config.openshift.io cluster` for apiserver, authentication, build, console, dns, featuregate, image, infrastructure, ingress, network, oauth, project, proxy, scheduler |
| 6–7 | Ingress Controllers, Change Replicas — Change, Backup | `oc get ingresscontroller`, `oc patch … spec.replicas` |
| 8–9 | Image Registry Config, Expose Route — Change, Backup | `oc get configs.imageregistry…`, patch `defaultRoute: true` |
| 10–12 | Operators (CSVs), Subscriptions, Catalogs | `oc get csv -A`, `subscriptions -A`, `catalogsource` |

### 10 Virtualization & VM Migration

| # | Item | Runs |
| --- | --- | --- |
| 1–3 | List VMs, Running VMIs, VM Details | `oc get vm -A`, `oc get vmi -A`, `oc describe vm` |
| 4–6 | Start / Stop / Restart VM — Change | `virtctl start\|stop\|restart`; without virtctl, patch `runStrategy` Always/Halted or delete the VMI |
| 7 | Live-Migrate a VM — Change | `virtctl migrate`, or a `VirtualMachineInstanceMigration` object |
| 8 | VM Serial Console | `virtctl console` (Ctrl-] to exit; needs virtctl) |
| 9 | Edit VM YAML — Backup | `oc edit vm` |
| 10–12 | DataVolumes, Network Attachments, NMState | `oc get datavolumes -A`, `network-attachment-definitions -A`, `nncp`, `nnce` |
| 13–14 | MTV Providers, Plans | `oc get providers.forklift.konveyor.io -A`, `plans… -A` |
| 15 | MTV Plan Details | `oc describe plans.forklift.konveyor.io` |
| 16 | MTV Start a Migration Plan — Change | `oc create -f` a `Migration` object for the plan |
| 17 | MTV List Migrations | `oc get migrations.forklift.konveyor.io -A` |

For a VMware-to-OpenShift lab: check the vSphere provider is Ready (13), check the plan is Ready (15), start it (16) and watch progress (17), then manage the migrated VMs with items 1–9.

### 11 Settings, Logs & Backups

| # | Item | Effect |
| --- | --- | --- |
| 1 | Toggle Dry-Run Mode | Same as `-d`, for this session |
| 2 | Toggle Automatic YAML Backups | Same as `-B`, for this session |
| 3–4 | Show ocsmit.log / ocsmit.script | Pages the files |
| 5 | List Backups | `ls -lt ~/.ocsmit/backups` |
| 6 | Restore an Object from a Backup — Change | `oc apply -f` the cleaned backup (section 8) |
| 7–8 | List / Switch kubeconfig Context | `oc config get-contexts`, `use-context` |
| 9 | Log In to a Cluster | `oc login <url> -u <user>` (default `https://api.crc.testing:6443`, `kubeadmin`) |

## 8. Logs, change script, backups and dry-run

Everything ocsmit keeps lives in `~/.ocsmit/` (or `$OCSMIT_HOME`), readable only by you.

| File | Contents |
| --- | --- |
| `ocsmit.log` | One line per command: timestamp, user, mode (view / change / tty / dryrun), return code, command |
| `ocsmit.script` | Every successful change as a runnable `oc` command, with a timestamp and cluster comment; dry-run commands are added as comments |
| `backups/` | YAML copies named `YYYYMMDD-HHMMSS_<namespace>_<kind>_<name>.yaml` |

Sample `ocsmit.log` line:

```
2026-11-07 12:04:31 [kubeadmin] change rc=0  oc scale deploy/web --replicas=3 -n myapp
```

### Replaying changes

`ocsmit.script` is plain shell. To repeat a set of changes on another cluster, copy the lines you want into a new file, review it, and run it with `bash`. Lines starting with `#` are comments.

### Backups and restore

Before an edit, patch, image change, env change, volume change, rollback or delete, ocsmit runs `oc get <kind> <name> -o yaml` and saves the result. Backups are skipped in dry-run mode or when started with `-B`.

To restore, use **Settings → Restore an Object from a Backup**. ocsmit strips the server-managed fields (`resourceVersion`, `uid`, `creationTimestamp`, `generation`, `selfLink` and the `status:` block), shows you the YAML, and runs `oc apply -f` after you confirm. A restore puts the object's spec back; it does not bring back data in a deleted PVC.

Backups are never deleted automatically. Clean up old ones with, for example, `find ~/.ocsmit/backups -mtime +30 -delete`.

### Dry-run mode

Start with `ocsmit -d`, set `OCSMIT_DRYRUN=yes`, or toggle it in Settings. In dry-run, every change shows its ARE YOU SURE? screen and is recorded as a comment in `ocsmit.script`, but nothing runs. Read-only screens still query the cluster normally, so pick lists and current values work.

## 9. Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `ocsmit: 'oc' not found in PATH` | `oc` not installed or not on PATH | Install it, run `eval $(crc oc-env)` on CRC, or set `OC=/path/to/oc` |
| Header shows `(not logged in)` | No valid login or the token expired | Settings → Log In, or `oc login`; then `r` to refresh |
| `?` shows `(no items found)` | Wrong project, nothing exists yet, or no permission to list | Check the Project field; type the value by hand instead |
| `Forbidden` on COMMAND STATUS | Your user lacks the role | Log in as a cluster-admin (e.g. `kubeadmin`) or ask for the role |
| `the server doesn't have a resource type "vm"` | OpenShift Virtualization not installed | Install the operator; MTV items need the MTV operator too |
| `oc adm top` fails | Metrics not available yet | Wait for the monitoring stack; on CRC enable it with `crc config set enable-cluster-monitoring true` |
| VM console says virtctl is required | `virtctl` not on PATH | Download it from the web console (? → Command line tools) |
| HTPasswd screens say no provider found | The OAuth config has no HTPasswd identity provider | Add one under Cluster Configuration → Edit → `oauth` first |
| PVC expand does nothing | Storage class lacks `allowVolumeExpansion: true` | Use a class that supports expansion |
| Boxes or odd characters on screen | Terminal without colour support | `export TERM=xterm-256color`, or run with `TERM=dumb` for plain text |
| Restore fails with a conflict | The object changed after the backup | Edit the object directly, using the backup file as a reference |
| Text in prompts wraps oddly | Very narrow terminal | Widen the window to at least 80 columns |

For anything else, check `~/.ocsmit/ocsmit.log` for the exact command and return code, then run that command by hand to see the full error.

## 10. Uninstall

Removing ocsmit leaves the cluster untouched; only the script and its local files go.

```bash
rm ~/bin/ocsmit                 # or: sudo rm /usr/local/bin/ocsmit
rm -rf ~/.ocsmit                # log, change script and backups
```

Copy `~/.ocsmit/ocsmit.script` and `~/.ocsmit/backups/` somewhere safe first if you may need the change history or the saved YAML later.
