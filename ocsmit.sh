#!/usr/bin/env bash
#==============================================================================
#  ocsmit.sh - SMIT/smitty-style menu front end for OpenShift (oc)
#
#  Review and update OpenShift configuration through numbered menus and
#  entry-field dialogs, the way smitty works on AIX:
#    * Every change shows the exact "oc" command first, then asks
#      "ARE YOU SURE?" before running it.
#    * Results appear on a COMMAND STATUS screen (OK / failed).
#    * Every command is logged to ~/.ocsmit/ocsmit.log and every successful
#      change is appended to ~/.ocsmit/ocsmit.script (like smit.log and
#      smit.script), so you can replay or turn the changes into automation.
#    * Objects are backed up as YAML before they are edited/patched/deleted.
#    * Fastpaths:  ./ocsmit.sh nodes   ./ocsmit.sh scale   ./ocsmit.sh vm
#
#  Usage:  ocsmit.sh [-d] [-B] [-h] [fastpath]
#     -d   dry-run (preview) mode: show commands, never execute changes
#     -B   do not take YAML backups before changes
#     -h   help / list fastpaths
#
#  Keys inside menus:  number=select  b=back  q=quit  /=fastpath
#                      r=refresh login info  l=show log  ?=help
#  Keys inside entry fields:  Enter=accept default  ?=list choices (F4)
#                             !=cancel the dialog
#
#  Requirements: bash 3.2+, oc (logged in). Optional: virtctl, htpasswd, less
#==============================================================================

VERSION="1.0"
OC=${OC:-oc}
OCSMIT_HOME=${OCSMIT_HOME:-$HOME/.ocsmit}
LOG_FILE="$OCSMIT_HOME/ocsmit.log"
SCRIPT_FILE="$OCSMIT_HOME/ocsmit.script"
BACKUP_DIR="$OCSMIT_HOME/backups"
DRYRUN=${OCSMIT_DRYRUN:-no}
AUTO_BACKUP=${OCSMIT_BACKUP:-yes}

CTX_SERVER="" CTX_USER="" CTX_NS=""
CONFIRM_NOTE=""      # extra text shown on the ARE YOU SURE screen
CONFIRM_FILE=""      # file (e.g. generated YAML) shown on the ARE YOU SURE screen
KV_LIST=()

if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ -n $(tput colors 2>/dev/null) ]]; then
  B=$(tput bold); R=$(tput sgr0); RED=$(tput setaf 1); GRN=$(tput setaf 2); YEL=$(tput setaf 3); CYN=$(tput setaf 6)
else
  B="" R="" RED="" GRN="" YEL="" CYN=""
fi

#------------------------------------------------------------------------------
#  Screen helpers
#------------------------------------------------------------------------------
term_cols() { local c; c=$(tput cols 2>/dev/null) || c=80; [[ $c =~ ^[0-9]+$ ]] || c=80; ((c > 110)) && c=110; echo "$c"; }

header() {
  local title=$1 cols line pad flags=""
  cols=$(term_cols)
  line=$(printf '%*s' "$cols" '' | tr ' ' '-')
  clear 2>/dev/null || printf '\n\n'
  pad=$(( (cols - ${#title}) / 2 )); ((pad < 0)) && pad=0
  printf '%*s%s\n' "$pad" '' "${B}${title}${R}"
  printf '%s\n' "$line"
  [[ $DRYRUN == yes ]] && flags+=" ${YEL}[DRY-RUN]${R}"
  [[ $AUTO_BACKUP == yes ]] || flags+=" ${YEL}[NO-BACKUP]${R}"
  printf ' Server : %s\n' "$CTX_SERVER"
  printf ' User   : %-28s Project: %s%s\n' "$CTX_USER" "$CTX_NS" "$flags"
  printf '%s\n\n' "$line"
}

form() {
  header "$1"
  echo " Type or select values in entry fields."
  echo " Press Enter AFTER making all desired changes."
  echo " ${CYN}* = required   ? = list choices (F4)   ! = cancel${R}"
  echo
}

pause() { echo; read -rp "  Press Enter to continue..." _ ; }
msg()   { echo; printf '  %s\n' "$@"; pause; }
confirm() { local a; read -rp "  $1 [y/N]: " a; [[ $a == y || $a == Y || $a == yes ]]; }

confirm_typed() {
  local want=$1 a
  echo
  echo "  ${RED}${B}DESTRUCTIVE ACTION.${R} Type the name '${want}' to confirm:"
  read -rp "  > " a
  [[ $a == "$want" ]] && return 0
  msg "Name did not match - cancelled."
  return 1
}

page_file() {
  if [[ -t 1 ]] && command -v less >/dev/null 2>&1; then less -RXF "$1"; else cat "$1"; fi
}

refresh_ctx() {
  CTX_SERVER=$("$OC" whoami --show-server 2>/dev/null) || CTX_SERVER="(not logged in)"
  CTX_USER=$("$OC" whoami 2>/dev/null)                 || CTX_USER="(not logged in)"
  CTX_NS=$("$OC" project -q 2>/dev/null)                || CTX_NS="default"
}

#------------------------------------------------------------------------------
#  Entry fields and lists (the smitty "F4" list)
#------------------------------------------------------------------------------
# pick VAR command [args...]   - run command, number its output lines, choose one
pick() {
  local _p_var=$1; shift
  local -a _p_items=()
  local _p_line _p_n _p_i
  while IFS= read -r _p_line; do
    [[ -n $_p_line ]] && _p_items+=("$_p_line")
  done < <("$@" 2>/dev/null)
  if ((${#_p_items[@]} == 0)); then echo "    (no items found)"; return 1; fi
  echo
  echo "    ${B}---------------- Select from list ----------------${R}"
  for ((_p_i = 0; _p_i < ${#_p_items[@]}; _p_i++)); do
    printf '    %3d) %s\n' $((_p_i + 1)) "${_p_items[_p_i]}"
  done
  read -rp "    Number (Enter = type a value instead): " _p_n
  if [[ $_p_n =~ ^[0-9]+$ ]] && ((_p_n >= 1 && _p_n <= ${#_p_items[@]})); then
    printf -v "$_p_var" '%s' "${_p_items[_p_n - 1]}"
    return 0
  fi
  return 1
}

# ask VAR "Prompt" "default" required(y|n) [list-command args...]
ask() {
  local _a_var=$1 _a_prompt=$2 _a_def=$3 _a_req=$4 _a_ans _a_mark=" " _a_hint=""
  shift 4
  [[ $_a_req == y ]] && _a_mark="*"
  (($# > 0)) && _a_hint=" (?=list)"
  while true; do
    read -erp "  ${_a_mark} ${_a_prompt}${_a_hint} [${_a_def}]: " _a_ans || return 1
    [[ -z $_a_ans ]] && _a_ans=$_a_def
    if [[ $_a_ans == "!" ]]; then return 1; fi
    if [[ $_a_ans == "?" ]]; then
      if (($# > 0)) && pick _a_ans "$@"; then
        echo "    -> $_a_ans"
      else
        continue
      fi
    fi
    if [[ -z $_a_ans && $_a_req == y ]]; then echo "    ${RED}This field is required.${R}"; continue; fi
    printf -v "$_a_var" '%s' "$_a_ans"
    return 0
  done
}

ask_num() {  # ask_num VAR "Prompt" default
  local _n_v
  while true; do
    ask _n_v "$2" "$3" y || return 1
    [[ $_n_v =~ ^[0-9]+$ ]] && { printf -v "$1" '%s' "$_n_v"; return 0; }
    echo "    ${RED}Enter a whole number.${R}"
  done
}

# Repeating KEY=VALUE entry - values may contain spaces. Result in KV_LIST.
read_kv_list() {
  local _kv
  KV_LIST=()
  echo "    Enter ${1:-KEY=VALUE} entries one per line; blank line when done (! = cancel)."
  while read -erp "      ${1:-KEY=VALUE}: " _kv && [[ -n $_kv ]]; do
    [[ $_kv == "!" ]] && return 1
    if [[ $_kv != *=* ]]; then echo "      (must contain '=')"; continue; fi
    KV_LIST+=("$_kv")
  done
  ((${#KV_LIST[@]} > 0)) || { echo "    Nothing entered."; return 1; }
}

# Listers used for "?" choices
choices()        { printf '%s\n' "$@"; }
names()          { if [[ -n ${2:-} ]]; then "$OC" get "$1" -n "$2" -o name; else "$OC" get "$1" -o name; fi | sed 's#^.*/##'; }
deploy_containers() { "$OC" get deploy "$1" -n "$2" -o jsonpath='{range .spec.template.spec.containers[*]}{.name}{"\n"}{end}'; }
pod_containers()    { "$OC" get pod "$1" -n "$2" -o jsonpath='{range .spec.containers[*]}{.name}{"\n"}{end}'; }
ls_backups()     { ls -1t "$BACKUP_DIR" 2>/dev/null; }
ls_contexts()    { "$OC" config get-contexts -o name; }
default_sc()     { "$OC" get sc -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -1; }

ask_ns() { ask "$1" "Project (namespace)" "$CTX_NS" y names projects; }

#------------------------------------------------------------------------------
#  Command execution, logging, backups
#------------------------------------------------------------------------------
fmt_cmd() { local s="" a; for a in "$@"; do s+="$(printf '%q' "$a") "; done; printf '%s' "${s% }"; }

log_cmd() {  # log_cmd mode rc cmdstring
  mkdir -p "$OCSMIT_HOME"
  printf '%s [%s] %-6s rc=%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$CTX_USER" "$1" "$2" "$3" >>"$LOG_FILE"
  if [[ $1 == change || $1 == tty-chg ]] && [[ $2 == 0 ]]; then
    printf '# %s  (%s)\n%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$CTX_USER@$CTX_SERVER" "$3" >>"$SCRIPT_FILE"
  fi
  if [[ $1 == dryrun ]]; then
    printf '# DRY-RUN %s\n# %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$3" >>"$SCRIPT_FILE"
  fi
}

_exec() {  # _exec view|change command args...
  local mode=$1; shift
  local cmdstr out rc
  cmdstr=$(fmt_cmd "$@")
  if [[ $mode == change ]]; then
    header "ARE YOU SURE?"
    echo "  Command to be run:"
    echo "    ${B}${cmdstr}${R}"
    [[ -n $CONFIRM_NOTE ]] && { echo; printf '  %s\n' "$CONFIRM_NOTE"; }
    if [[ -n $CONFIRM_FILE && -f $CONFIRM_FILE ]]; then
      echo; echo "  ---- contents of $(basename "$CONFIRM_FILE") ----"; sed 's/^/    /' "$CONFIRM_FILE"; echo "  -------------------------------"
    fi
    CONFIRM_NOTE=""; CONFIRM_FILE=""
    echo
    if [[ $DRYRUN == yes ]]; then
      echo "  ${YEL}DRY-RUN mode: command was NOT executed (recorded in ocsmit.script).${R}"
      log_cmd dryrun - "$cmdstr"; pause; return 0
    fi
    if ! confirm "Continue?"; then echo "  Cancelled."; pause; return 1; fi
  fi
  out=$(mktemp "${TMPDIR:-/tmp}/ocsmit.XXXXXX")
  echo "  Running...  (Ctrl-C to interrupt)"
  trap ':' INT
  "$@" >"$out" 2>&1
  rc=$?
  trap - INT
  header "COMMAND STATUS"
  if ((rc == 0)); then
    echo "  Command: ${GRN}${B}OK${R}"
  else
    echo "  Command: ${RED}${B}failed${R}  (rc=$rc)"
  fi
  echo "  ${CYN}$cmdstr${R}"
  echo
  [[ -s $out ]] && page_file "$out" || echo "  (no output)"
  rm -f "$out"
  log_cmd "$mode" "$rc" "$cmdstr"
  pause
  return "$rc"
}
run_view()   { _exec view "$@"; }
run_change() { _exec change "$@"; }

# Interactive commands (edit, rsh, logs -f, console, debug)
run_tty() {  # run_tty view|change cmd args...
  local mode=$1; shift
  local cmdstr rc
  cmdstr=$(fmt_cmd "$@")
  header "INTERACTIVE COMMAND"
  echo "  ${B}${cmdstr}${R}"
  echo
  if [[ $mode == change && $DRYRUN == yes ]]; then
    echo "  ${YEL}DRY-RUN mode: not executed.${R}"; log_cmd dryrun - "$cmdstr"; pause; return 0
  fi
  trap ':' INT          # Ctrl-C stops the child command, not ocsmit
  "$@"; rc=$?
  trap - INT
  echo
  ((rc == 0)) && echo "  Command: ${GRN}${B}OK${R}" || echo "  Command: ${RED}${B}failed${R} (rc=$rc)"
  [[ $mode == change ]] && log_cmd tty-chg "$rc" "$cmdstr" || log_cmd tty "$rc" "$cmdstr"
  pause
  return "$rc"
}

backup_obj() {  # backup_obj kind name [namespace]
  [[ $AUTO_BACKUP == yes && $DRYRUN != yes ]] || return 0
  local kind=$1 name=$2 ns=${3:-} f
  mkdir -p "$BACKUP_DIR"
  f="$BACKUP_DIR/$(date +%Y%m%d-%H%M%S)_${ns:-cluster}_${kind//\//-}_${name}.yaml"
  if [[ -n $ns ]]; then "$OC" get "$kind" "$name" -n "$ns" -o yaml >"$f" 2>/dev/null
  else "$OC" get "$kind" "$name" -o yaml >"$f" 2>/dev/null; fi
  if [[ -s $f ]]; then echo "  Backup saved: $f"; else rm -f "$f"; echo "  ${YEL}WARNING: could not back up $kind/$name${R}"; fi
}

edit_obj() {  # edit_obj kind name [namespace]
  local kind=$1 name=$2 ns=${3:-}
  backup_obj "$kind" "$name" "$ns"
  if [[ -n $ns ]]; then run_tty change "$OC" edit "$kind" "$name" -n "$ns"
  else run_tty change "$OC" edit "$kind" "$name"; fi
}

tmp_yaml() { mktemp "${TMPDIR:-/tmp}/ocsmit-XXXXXX"; }

#------------------------------------------------------------------------------
#  Menu engine
#------------------------------------------------------------------------------
# menu "Title" "Item label" function "Item label" function ...
menu() {
  local title=$1; shift
  local -a labels=() actions=()
  local ch i
  while (($# >= 2)); do labels+=("$1"); actions+=("$2"); shift 2; done
  while true; do
    header "$title"
    echo " Type the number of the desired item and press Enter."
    echo
    for ((i = 0; i < ${#labels[@]}; i++)); do
      printf '   %2d  %s\n' $((i + 1)) "${labels[i]}"
    done
    echo
    echo " ${CYN}b=Back  q=Exit  /=Fastpath  r=Refresh  l=Log  ?=Help${R}"
    read -rp " Selection: " ch || exit 0
    case $ch in
      b|B)  return 0 ;;
      q|Q)  quit ;;
      r|R)  refresh_ctx ;;
      l|L)  a_show_log ;;
      "?")  a_help ;;
      /*)   local fp=${ch#/}; [[ -z $fp ]] && read -rp " Fastpath name: " fp; fastpath "$fp" || msg "Unknown fastpath '$fp'. Type ? for help." ;;
      "")   ;;
      *)    if [[ $ch =~ ^[0-9]+$ ]] && ((ch >= 1 && ch <= ${#labels[@]})); then
              "${actions[ch - 1]}"
            else
              msg "Invalid selection '$ch'."
            fi ;;
    esac
  done
}

quit() { clear 2>/dev/null; echo "ocsmit: log in $LOG_FILE, change script in $SCRIPT_FILE"; exit 0; }

#==============================================================================
#  MAIN MENU
#==============================================================================
m_main() {
  menu "OpenShift System Management (ocsmit $VERSION)" \
    "Cluster Information & Health"                       m_cluster \
    "Projects (Namespaces)"                              m_projects \
    "Workloads (Deployments, Pods, Rollouts)"            m_workloads \
    "Application Configuration (ConfigMaps, Secrets, Env)" m_config \
    "Networking (Services, Routes, NetworkPolicies)"     m_network \
    "Storage (PVCs, PVs, StorageClasses)"                m_storage \
    "Security & Users (RBAC, Groups, SCC, HTPasswd)"     m_security \
    "Nodes & Machine Config"                             m_nodes \
    "Cluster Configuration (Operators, Ingress, Registry, Updates)" m_clustercfg \
    "Virtualization & VM Migration (CNV / MTV)"          m_virt \
    "ocsmit Settings, Logs & Backups"                    m_settings
}

#==============================================================================
#  1. CLUSTER INFORMATION & HEALTH
#==============================================================================
m_cluster() {
  menu "Cluster Information & Health" \
    "Show Cluster Version"                         a_cluster_version \
    "Show Console URL and Login Identity"          a_whoami \
    "List Cluster Operators"                       a_co \
    "Show Degraded / Unavailable Operators"        a_co_bad \
    "List Nodes and Status"                        a_nodes \
    "Node Resource Usage (top)"                    a_top_nodes \
    "Pods Not Running (all projects)"              a_pods_bad \
    "Recent Warning Events (all projects)"         a_warn_events \
    "List Certificate Signing Requests"            a_csr_list \
    "Approve All Pending CSRs"                     a_csr_approve \
    "Collect must-gather Diagnostics"              a_must_gather
}
a_cluster_version() { run_view "$OC" get clusterversion; }
a_whoami()          { run_view f_whoami; }
f_whoami()          { echo "User:    $("$OC" whoami)"; echo "API:     $("$OC" whoami --show-server)"; echo "Console: $("$OC" whoami --show-console 2>/dev/null)"; echo; "$OC" version; }
a_co()              { run_view "$OC" get clusteroperators; }
a_co_bad()          { run_view f_co_bad; }
f_co_bad() {
  "$OC" get clusteroperators --no-headers | awk '
    $3!="True" || $5=="True" { print; n++ }
    END { if (n==0) print "All cluster operators are Available and not Degraded." }'
}
a_pods_bad()        { run_view "$OC" get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded; }
a_warn_events()     { run_view "$OC" get events -A --field-selector=type=Warning --sort-by=.lastTimestamp; }
a_csr_list()        { run_view "$OC" get csr; }
f_pending_csrs()    { "$OC" get csr -o go-template='{{range .items}}{{if not .status}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}'; }
a_csr_approve() {
  local -a csrs=(); local c
  while IFS= read -r c; do [[ -n $c ]] && csrs+=("$c"); done < <(f_pending_csrs 2>/dev/null)
  ((${#csrs[@]})) || { msg "No pending CSRs."; return; }
  run_change "$OC" adm certificate approve "${csrs[@]}"
}
a_must_gather() {
  local DEST
  form "Collect must-gather Diagnostics"
  ask DEST "Destination directory" "$HOME/must-gather-$(date +%Y%m%d-%H%M)" y || return
  run_tty view "$OC" adm must-gather --dest-dir="$DEST"
}

#==============================================================================
#  2. PROJECTS
#==============================================================================
m_projects() {
  menu "Projects (Namespaces)" \
    "List All Projects"                    a_projects \
    "Change Current Project"               a_project_switch \
    "Show Project Details, Quotas & Limits" a_project_details \
    "Create a Project"                     a_project_new \
    "Set a Resource Quota on a Project"    a_project_quota \
    "Show Events in a Project"             a_project_events \
    "Delete a Project"                     a_project_delete
}
a_projects() { run_view "$OC" get projects; }
a_project_switch() {
  local P
  form "Change Current Project"
  ask P "Project name" "$CTX_NS" y names projects || return
  run_view "$OC" project "$P"; refresh_ctx
}
a_project_details() {
  local P; form "Show Project Details"; ask_ns P || return
  run_view f_project_details "$P"
}
f_project_details() { "$OC" describe project "$1"; echo; "$OC" get resourcequota,limitrange -n "$1"; }
a_project_new() {
  local P DISP DESC
  form "Create a Project"
  ask P "Project name (lowercase, a-z0-9-)" "" y || return
  ask DISP "Display name" "" n || return
  ask DESC "Description" "" n || return
  local -a args=(new-project "$P")
  [[ -n $DISP ]] && args+=("--display-name=$DISP")
  [[ -n $DESC ]] && args+=("--description=$DESC")
  run_change "$OC" "${args[@]}" && refresh_ctx
}
a_project_quota() {
  local P Q CPU MEM PODS PVC
  form "Set a Resource Quota on a Project"
  ask_ns P || return
  ask Q    "Quota name"                         "compute-quota" y || return
  ask CPU  "CPU requests limit (e.g. 4)"        "4"     n || return
  ask MEM  "Memory requests limit (e.g. 8Gi)"   "8Gi"   n || return
  ask PODS "Max pods"                           "20"    n || return
  ask PVC  "Max PVCs"                           "10"    n || return
  local hard=""
  [[ -n $CPU  ]] && hard+="requests.cpu=$CPU,"
  [[ -n $MEM  ]] && hard+="requests.memory=$MEM,"
  [[ -n $PODS ]] && hard+="pods=$PODS,"
  [[ -n $PVC  ]] && hard+="persistentvolumeclaims=$PVC,"
  [[ -n $hard ]] || { msg "No limits entered."; return; }
  run_change "$OC" create quota "$Q" -n "$P" --hard="${hard%,}"
}
a_project_events() { local P; form "Show Events"; ask_ns P || return; run_view "$OC" get events -n "$P" --sort-by=.lastTimestamp; }
a_project_delete() {
  local P; form "Delete a Project"
  ask P "Project to DELETE" "" y names projects || return
  confirm_typed "$P" || return
  run_change "$OC" delete project "$P" && refresh_ctx
}

#==============================================================================
#  3. WORKLOADS
#==============================================================================
m_workloads() {
  menu "Workloads (Deployments, Pods, Rollouts)" \
    "List Deployments"                         a_deploy_list \
    "List Pods"                                a_pod_list \
    "Show Deployment Details"                  a_deploy_describe \
    "Scale a Deployment"                       a_scale \
    "Restart a Deployment (rolling)"           a_restart \
    "Show Rollout History"                     a_rollout_history \
    "Roll Back a Deployment"                   a_rollout_undo \
    "Change Container Image"                   a_set_image \
    "Set CPU / Memory Requests and Limits"     a_set_resources \
    "Configure Autoscaling (HPA)"              a_autoscale \
    "Edit Deployment YAML"                     a_deploy_edit \
    "View Pod Logs"                            a_logs \
    "Open Remote Shell in a Pod"               a_rsh \
    "Delete (recycle) a Pod"                   a_pod_delete \
    "Deploy an Application from an Image"      a_new_app
}
a_deploy_list() { local N; form "List Deployments"; ask_ns N || return; run_view "$OC" get deploy -n "$N" -o wide; }
a_pod_list()    { local N; form "List Pods"; ask_ns N || return; run_view "$OC" get pods -n "$N" -o wide; }
ask_deploy()    { ask "$1" "Deployment" "" y names deploy "$2"; }
ask_pod()       { ask "$1" "Pod" "" y names pods "$2"; }
a_deploy_describe() { local N D; form "Show Deployment Details"; ask_ns N || return; ask_deploy D "$N" || return; run_view "$OC" describe deploy "$D" -n "$N"; }
a_scale() {
  local N D REP cur
  form "Scale a Deployment"
  ask_ns N || return; ask_deploy D "$N" || return
  cur=$("$OC" get deploy "$D" -n "$N" -o jsonpath='{.spec.replicas}' 2>/dev/null)
  ask_num REP "Number of replicas" "${cur:-1}" || return
  run_change "$OC" scale "deploy/$D" --replicas="$REP" -n "$N"
}
a_restart() { local N D; form "Restart a Deployment"; ask_ns N || return; ask_deploy D "$N" || return; run_change "$OC" rollout restart "deploy/$D" -n "$N"; }
a_rollout_history() { local N D; form "Rollout History"; ask_ns N || return; ask_deploy D "$N" || return; run_view "$OC" rollout history "deploy/$D" -n "$N"; }
a_rollout_undo() {
  local N D REV
  form "Roll Back a Deployment"
  ask_ns N || return; ask_deploy D "$N" || return
  ask REV "Revision (blank = previous)" "" n || return
  backup_obj deploy "$D" "$N"
  if [[ -n $REV ]]; then run_change "$OC" rollout undo "deploy/$D" --to-revision="$REV" -n "$N"
  else run_change "$OC" rollout undo "deploy/$D" -n "$N"; fi
}
a_set_image() {
  local N D C IMG cur
  form "Change Container Image"
  ask_ns N || return; ask_deploy D "$N" || return
  ask C "Container" "$(deploy_containers "$D" "$N" 2>/dev/null | head -1)" y deploy_containers "$D" "$N" || return
  cur=$("$OC" get deploy "$D" -n "$N" -o jsonpath="{.spec.template.spec.containers[?(@.name==\"$C\")].image}" 2>/dev/null)
  ask IMG "New image" "$cur" y || return
  [[ $IMG == "$cur" ]] && { msg "Image unchanged."; return; }
  backup_obj deploy "$D" "$N"
  run_change "$OC" set image "deploy/$D" "$C=$IMG" -n "$N"
}
a_set_resources() {
  local N D C RC RM LC LM
  form "Set CPU / Memory Requests and Limits"
  ask_ns N || return; ask_deploy D "$N" || return
  ask C  "Container"                 "$(deploy_containers "$D" "$N" 2>/dev/null | head -1)" y deploy_containers "$D" "$N" || return
  ask RC "CPU request (e.g. 250m)"    "" n || return
  ask RM "Memory request (e.g. 256Mi)" "" n || return
  ask LC "CPU limit (e.g. 1)"         "" n || return
  ask LM "Memory limit (e.g. 512Mi)"  "" n || return
  local req="" lim=""
  [[ -n $RC ]] && req="cpu=$RC";  [[ -n $RM ]] && req="${req:+$req,}memory=$RM"
  [[ -n $LC ]] && lim="cpu=$LC";  [[ -n $LM ]] && lim="${lim:+$lim,}memory=$LM"
  [[ -n $req || -n $lim ]] || { msg "Nothing entered."; return; }
  local -a args=(set resources "deploy/$D" -c "$C" -n "$N")
  [[ -n $req ]] && args+=("--requests=$req")
  [[ -n $lim ]] && args+=("--limits=$lim")
  backup_obj deploy "$D" "$N"
  run_change "$OC" "${args[@]}"
}
a_autoscale() {
  local N D MIN MAX CPU
  form "Configure Autoscaling (HPA)"
  ask_ns N || return; ask_deploy D "$N" || return
  ask_num MIN "Minimum replicas" 1 || return
  ask_num MAX "Maximum replicas" 3 || return
  ask_num CPU "Target CPU utilization %" 80 || return
  run_change "$OC" autoscale "deploy/$D" --min="$MIN" --max="$MAX" --cpu-percent="$CPU" -n "$N"
}
a_deploy_edit() { local N D; form "Edit Deployment YAML"; ask_ns N || return; ask_deploy D "$N" || return; edit_obj deploy "$D" "$N"; }
a_logs() {
  local N P C TAIL PREV FOL
  form "View Pod Logs"
  ask_ns N || return; ask_pod P "$N" || return
  ask C    "Container (blank = default)" "" n pod_containers "$P" "$N" || return
  ask TAIL "Lines to show"               "200" y || return
  ask PREV "Previous (crashed) container? (yes/no)" "no" y choices yes no || return
  ask FOL  "Follow live (Ctrl-C to stop)? (yes/no)" "no" y choices yes no || return
  local -a args=(logs "$P" -n "$N" --tail="$TAIL")
  [[ -n $C ]] && args+=(-c "$C")
  [[ $PREV == yes ]] && args+=(--previous)
  if [[ $FOL == yes ]]; then run_tty view "$OC" "${args[@]}" -f; else run_view "$OC" "${args[@]}"; fi
}
a_rsh() { local N P; form "Open Remote Shell"; ask_ns N || return; ask_pod P "$N" || return; run_tty view "$OC" rsh -n "$N" "$P"; }
a_pod_delete() { local N P; form "Delete (recycle) a Pod"; ask_ns N || return; ask_pod P "$N" || return; run_change "$OC" delete pod "$P" -n "$N"; }
a_new_app() {
  local N NAME IMG
  form "Deploy an Application from an Image"
  ask_ns N || return
  ask IMG  "Container image (e.g. quay.io/org/app:tag)" "" y || return
  ask NAME "Application name" "" y || return
  run_change "$OC" new-app --image="$IMG" --name="$NAME" -n "$N"
}

#==============================================================================
#  4. APPLICATION CONFIGURATION
#==============================================================================
m_config() {
  menu "Application Configuration (ConfigMaps, Secrets, Env)" \
    "List ConfigMaps"                               a_cm_list \
    "Show a ConfigMap"                              a_cm_show \
    "Create a ConfigMap from Key=Value Pairs"       a_cm_create_lit \
    "Create a ConfigMap from a File"                a_cm_create_file \
    "Edit a ConfigMap"                              a_cm_edit \
    "Delete a ConfigMap"                            a_cm_delete \
    "List Secrets"                                  a_sec_list \
    "Show a Secret (decoded)"                       a_sec_show \
    "Create a Generic Secret from Key=Value Pairs"  a_sec_create \
    "Edit a Secret"                                 a_sec_edit \
    "Show Environment Variables of a Deployment"    a_env_list \
    "Set / Update Environment Variables"            a_env_set \
    "Remove an Environment Variable"                a_env_unset \
    "Load Env Vars from a ConfigMap or Secret"      a_env_from \
    "Mount a ConfigMap or Secret as a Volume"       a_mount_cfg
}
a_cm_list()  { local N; form "List ConfigMaps"; ask_ns N || return; run_view "$OC" get configmaps -n "$N"; }
a_cm_show()  { local N C; form "Show a ConfigMap"; ask_ns N || return; ask C "ConfigMap" "" y names configmap "$N" || return; run_view "$OC" get configmap "$C" -n "$N" -o yaml; }
a_cm_create_lit() {
  local N C; form "Create a ConfigMap from Key=Value Pairs"
  ask_ns N || return; ask C "ConfigMap name" "" y || return
  read_kv_list || { pause; return; }
  local -a args=(create configmap "$C" -n "$N"); local kv
  for kv in "${KV_LIST[@]}"; do args+=("--from-literal=$kv"); done
  run_change "$OC" "${args[@]}"
}
a_cm_create_file() {
  local N C F K; form "Create a ConfigMap from a File"
  ask_ns N || return; ask C "ConfigMap name" "" y || return
  ask F "File or directory path (Tab completes)" "" y || return
  [[ -e $F ]] || { msg "Path not found: $F"; return; }
  ask K "Key name (blank = file name)" "" n || return
  run_change "$OC" create configmap "$C" -n "$N" --from-file="${K:+$K=}$F"
}
a_cm_edit()   { local N C; form "Edit a ConfigMap"; ask_ns N || return; ask C "ConfigMap" "" y names configmap "$N" || return; edit_obj configmap "$C" "$N"; }
a_cm_delete() { local N C; form "Delete a ConfigMap"; ask_ns N || return; ask C "ConfigMap" "" y names configmap "$N" || return; backup_obj configmap "$C" "$N"; run_change "$OC" delete configmap "$C" -n "$N"; }
a_sec_list()  { local N; form "List Secrets"; ask_ns N || return; run_view "$OC" get secrets -n "$N"; }
a_sec_show() {
  local N S; form "Show a Secret (decoded)"
  ask_ns N || return; ask S "Secret" "" y names secret "$N" || return
  echo; echo "  ${YEL}Secret values will be displayed in clear text on screen.${R}"
  confirm "Show anyway?" || return
  run_view "$OC" extract "secret/$S" -n "$N" --to=-
}
a_sec_create() {
  local N S; form "Create a Generic Secret"
  ask_ns N || return; ask S "Secret name" "" y || return
  read_kv_list || { pause; return; }
  local -a args=(create secret generic "$S" -n "$N"); local kv
  for kv in "${KV_LIST[@]}"; do args+=("--from-literal=$kv"); done
  run_change "$OC" "${args[@]}"
}
a_sec_edit() { local N S; form "Edit a Secret"; ask_ns N || return; ask S "Secret" "" y names secret "$N" || return; echo "  Note: values under data: are base64; use stringData: for plain text."; sleep 2; edit_obj secret "$S" "$N"; }
a_env_list() { local N D; form "Show Environment Variables"; ask_ns N || return; ask_deploy D "$N" || return; run_view "$OC" set env "deploy/$D" -n "$N" --list; }
a_env_set() {
  local N D; form "Set / Update Environment Variables"
  ask_ns N || return; ask_deploy D "$N" || return
  read_kv_list "NAME=VALUE" || { pause; return; }
  backup_obj deploy "$D" "$N"
  CONFIRM_NOTE="This triggers a new rollout of deploy/$D."
  run_change "$OC" set env "deploy/$D" -n "$N" "${KV_LIST[@]}"
}
a_env_unset() {
  local N D K; form "Remove an Environment Variable"
  ask_ns N || return; ask_deploy D "$N" || return
  ask K "Variable name" "" y f_env_names "$D" "$N" || return
  backup_obj deploy "$D" "$N"
  run_change "$OC" set env "deploy/$D" -n "$N" "$K-"
}
f_env_names() { "$OC" set env "deploy/$1" -n "$2" --list 2>/dev/null | grep -v '^#' | cut -d= -f1; }
a_env_from() {
  local N D T SRC PFX; form "Load Env Vars from a ConfigMap or Secret"
  ask_ns N || return; ask_deploy D "$N" || return
  ask T   "Source type" "configmap" y choices configmap secret || return
  ask SRC "Source name" "" y names "$T" "$N" || return
  ask PFX "Variable prefix (optional)" "" n || return
  backup_obj deploy "$D" "$N"
  local -a args=(set env "deploy/$D" -n "$N" --from="$T/$SRC")
  [[ -n $PFX ]] && args+=("--prefix=$PFX")
  run_change "$OC" "${args[@]}"
}
a_mount_cfg() {
  local N D T SRC MP V; form "Mount a ConfigMap or Secret as a Volume"
  ask_ns N || return; ask_deploy D "$N" || return
  ask T   "Source type" "configmap" y choices configmap secret || return
  ask SRC "Source name" "" y names "$T" "$N" || return
  ask MP  "Mount path in container" "/etc/$SRC" y || return
  ask V   "Volume name" "$SRC-vol" y || return
  backup_obj deploy "$D" "$N"
  if [[ $T == configmap ]]; then
    run_change "$OC" set volume "deploy/$D" -n "$N" --add --name="$V" --type=configmap --configmap-name="$SRC" --mount-path="$MP"
  else
    run_change "$OC" set volume "deploy/$D" -n "$N" --add --name="$V" --type=secret --secret-name="$SRC" --mount-path="$MP"
  fi
}

#==============================================================================
#  5. NETWORKING
#==============================================================================
m_network() {
  menu "Networking (Services, Routes, NetworkPolicies)" \
    "List Services"                              a_svc_list \
    "List Routes"                                a_route_list \
    "Show Route Details"                         a_route_describe \
    "Expose a Service as an HTTP Route"          a_route_expose \
    "Create a Secure (edge TLS) Route"           a_route_edge \
    "Delete a Route"                             a_route_delete \
    "List NetworkPolicies"                       a_np_list \
    "Apply a NetworkPolicy Template"             a_np_template \
    "Delete a NetworkPolicy"                     a_np_delete \
    "Port-Forward to a Pod"                      a_port_forward
}
a_svc_list()   { local N; form "List Services"; ask_ns N || return; run_view "$OC" get svc -n "$N" -o wide; }
a_route_list() { local N; form "List Routes"; ask_ns N || return; run_view "$OC" get routes -n "$N"; }
a_route_describe() { local N RT; form "Show Route Details"; ask_ns N || return; ask RT "Route" "" y names route "$N" || return; run_view "$OC" describe route "$RT" -n "$N"; }
a_route_expose() {
  local N S H RN; form "Expose a Service as an HTTP Route"
  ask_ns N || return; ask S "Service" "" y names svc "$N" || return
  ask RN "Route name"                  "$S" y || return
  ask H  "Hostname (blank = generated)" "" n || return
  local -a args=(expose "svc/$S" -n "$N" --name="$RN")
  [[ -n $H ]] && args+=("--hostname=$H")
  run_change "$OC" "${args[@]}"
}
a_route_edge() {
  local N S RN H P; form "Create a Secure (edge TLS) Route"
  ask_ns N || return; ask S "Service" "" y names svc "$N" || return
  ask RN "Route name" "$S-tls" y || return
  ask H  "Hostname (blank = generated)" "" n || return
  ask P  "Target port name/number (blank = default)" "" n || return
  local -a args=(create route edge "$RN" --service="$S" -n "$N" --insecure-policy=Redirect)
  [[ -n $H ]] && args+=("--hostname=$H")
  [[ -n $P ]] && args+=("--port=$P")
  run_change "$OC" "${args[@]}"
}
a_route_delete() { local N RT; form "Delete a Route"; ask_ns N || return; ask RT "Route" "" y names route "$N" || return; backup_obj route "$RT" "$N"; run_change "$OC" delete route "$RT" -n "$N"; }
a_np_list()   { local N; form "List NetworkPolicies"; ask_ns N || return; run_view "$OC" get networkpolicy -n "$N"; }
a_np_delete() { local N NP; form "Delete a NetworkPolicy"; ask_ns N || return; ask NP "NetworkPolicy" "" y names networkpolicy "$N" || return; backup_obj networkpolicy "$NP" "$N"; run_change "$OC" delete networkpolicy "$NP" -n "$N"; }
a_np_template() {
  local N T f; form "Apply a NetworkPolicy Template"
  ask_ns N || return
  echo "    deny-all              : block all ingress to every pod in the project"
  echo "    allow-same-namespace  : allow traffic between pods in this project"
  echo "    allow-from-ingress    : allow traffic from the OpenShift router (Routes)"
  echo "    allow-from-monitoring : allow traffic from cluster monitoring"
  ask T "Template" "allow-same-namespace" y choices deny-all allow-same-namespace allow-from-ingress allow-from-monitoring || return
  f=$(tmp_yaml)
  case $T in
    deny-all) cat >"$f" <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-by-default
spec:
  podSelector: {}
  ingress: []
EOF
    ;;
    allow-same-namespace) cat >"$f" <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-same-namespace
spec:
  podSelector: {}
  ingress:
  - from:
    - podSelector: {}
EOF
    ;;
    allow-from-ingress) cat >"$f" <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-from-openshift-ingress
spec:
  podSelector: {}
  policyTypes: [Ingress]
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          policy-group.network.openshift.io/ingress: ""
EOF
    ;;
    allow-from-monitoring) cat >"$f" <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-from-openshift-monitoring
spec:
  podSelector: {}
  policyTypes: [Ingress]
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          network.openshift.io/policy-group: monitoring
EOF
    ;;
    *) rm -f "$f"; msg "Unknown template '$T'."; return ;;
  esac
  CONFIRM_FILE=$f
  run_change "$OC" apply -n "$N" -f "$f"
  rm -f "$f"
}
a_port_forward() {
  local N P PORTS; form "Port-Forward to a Pod"
  ask_ns N || return; ask_pod P "$N" || return
  ask PORTS "LOCAL:REMOTE port (e.g. 8080:80)" "8080:8080" y || return
  echo "  Press Ctrl-C to stop forwarding."
  run_tty view "$OC" port-forward -n "$N" "pod/$P" "$PORTS"
}

#==============================================================================
#  6. STORAGE
#==============================================================================
m_storage() {
  menu "Storage (PVCs, PVs, StorageClasses)" \
    "List Persistent Volume Claims"              a_pvc_list \
    "List Persistent Volumes"                    a_pv_list \
    "List Storage Classes"                       a_sc_list \
    "Create a Persistent Volume Claim"           a_pvc_create \
    "Expand a Persistent Volume Claim"           a_pvc_expand \
    "Add a PVC Volume to a Deployment"           a_pvc_mount \
    "Set the Default Storage Class"              a_sc_default \
    "Delete a Persistent Volume Claim"           a_pvc_delete
}
a_pvc_list() { local N; form "List PVCs"; ask_ns N || return; run_view "$OC" get pvc -n "$N"; }
a_pv_list()  { run_view "$OC" get pv; }
a_sc_list()  { run_view "$OC" get storageclass; }
a_pvc_create() {
  local N PVC SIZE SC MODE VM f; form "Create a Persistent Volume Claim"
  ask_ns N || return
  ask PVC  "PVC name" "" y || return
  ask SIZE "Size (e.g. 10Gi)" "1Gi" y || return
  ask SC   "Storage class" "$(default_sc)" y names storageclass || return
  ask MODE "Access mode" "ReadWriteOnce" y choices ReadWriteOnce ReadWriteMany ReadOnlyMany ReadWriteOncePod || return
  ask VM   "Volume mode" "Filesystem" y choices Filesystem Block || return
  f=$(tmp_yaml)
  cat >"$f" <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $PVC
spec:
  accessModes: [$MODE]
  volumeMode: $VM
  storageClassName: $SC
  resources:
    requests:
      storage: $SIZE
EOF
  CONFIRM_FILE=$f
  run_change "$OC" apply -n "$N" -f "$f"
  rm -f "$f"
}
a_pvc_expand() {
  local N PVC cur NEW; form "Expand a Persistent Volume Claim"
  ask_ns N || return; ask PVC "PVC" "" y names pvc "$N" || return
  cur=$("$OC" get pvc "$PVC" -n "$N" -o jsonpath='{.spec.resources.requests.storage}' 2>/dev/null)
  ask NEW "New size (current: ${cur:-?})" "$cur" y || return
  backup_obj pvc "$PVC" "$N"
  CONFIRM_NOTE="The storage class must have allowVolumeExpansion: true. PVCs cannot shrink."
  run_change "$OC" patch pvc "$PVC" -n "$N" --type=merge -p "{\"spec\":{\"resources\":{\"requests\":{\"storage\":\"$NEW\"}}}}"
}
a_pvc_mount() {
  local N D PVC MP V; form "Add a PVC Volume to a Deployment"
  ask_ns N || return; ask_deploy D "$N" || return
  ask PVC "PVC" "" y names pvc "$N" || return
  ask MP  "Mount path in container" "/data" y || return
  ask V   "Volume name" "$PVC-vol" y || return
  backup_obj deploy "$D" "$N"
  run_change "$OC" set volume "deploy/$D" -n "$N" --add --name="$V" --type=pvc --claim-name="$PVC" --mount-path="$MP"
}
a_sc_default() {
  local SC old; form "Set the Default Storage Class"
  old=$(default_sc)
  ask SC "Storage class to make default (current: ${old:-none})" "$old" y names storageclass || return
  [[ $SC == "$old" ]] && { msg "$SC is already the default."; return; }
  CONFIRM_NOTE="Marks '$SC' as default${old:+ and clears the default flag on '$old'}."
  run_change f_sc_default "$SC" "$old"
}
f_sc_default() {
  local key='storageclass.kubernetes.io/is-default-class'
  if [[ -n $2 ]]; then backup_obj storageclass "$2"; "$OC" annotate storageclass "$2" "$key=false" --overwrite || return; fi
  backup_obj storageclass "$1"
  "$OC" annotate storageclass "$1" "$key=true" --overwrite
}
a_pvc_delete() {
  local N PVC; form "Delete a PVC"
  ask_ns N || return; ask PVC "PVC" "" y names pvc "$N" || return
  confirm_typed "$PVC" || return
  backup_obj pvc "$PVC" "$N"
  CONFIRM_NOTE="Data may be permanently lost depending on the PV reclaim policy."
  run_change "$OC" delete pvc "$PVC" -n "$N"
}

#==============================================================================
#  7. SECURITY & USERS
#==============================================================================
m_security() {
  menu "Security & Users (RBAC, Groups, SCC, HTPasswd)" \
    "List Users / Identities"                    a_users \
    "List Groups"                                a_groups \
    "List Role Bindings in a Project"            a_rolebindings \
    "Who Can Perform an Action?"                 a_who_can \
    "Grant a Project Role to a User"             a_role_add \
    "Grant a Project Role to a Group"            a_role_add_group \
    "Remove a Project Role from a User"          a_role_remove \
    "Grant a Cluster Role to a User"             a_crole_add \
    "Remove a Cluster Role from a User"          a_crole_remove \
    "Create a Group"                             a_group_new \
    "Add Users to a Group"                       a_group_add \
    "List Service Accounts"                      a_sa_list \
    "Create a Service Account"                   a_sa_create \
    "List Security Context Constraints (SCC)"    a_scc_list \
    "Grant an SCC to a Service Account"          a_scc_add \
    "Show Identity Providers (OAuth)"            a_oauth_show \
    "Add / Change HTPasswd User Password"        a_htpasswd_set \
    "Remove an HTPasswd User"                    a_htpasswd_del
}
a_users()  { run_view f_users; }
f_users()  { "$OC" get users; echo; "$OC" get identities; }
a_groups() { run_view "$OC" get groups; }
a_rolebindings() { local N; form "List Role Bindings"; ask_ns N || return; run_view "$OC" get rolebindings -n "$N" -o wide; }
a_who_can() {
  local N V RES; form "Who Can Perform an Action?"
  ask V   "Verb"     "delete" y choices get list watch create update patch delete || return
  ask RES "Resource" "pods" y || return
  ask_ns N || return
  run_view "$OC" adm policy who-can "$V" "$RES" -n "$N"
}
ask_role()  { ask "$1" "Role" "edit" y choices admin edit view basic-user; }
ask_crole() { ask "$1" "Cluster role" "cluster-reader" y choices cluster-admin cluster-reader self-provisioner sudoer; }
ask_user()  { ask "$1" "User" "" y names users; }
a_role_add()    { local N RL U; form "Grant a Project Role to a User"; ask_ns N || return; ask_role RL || return; ask_user U || return; run_change "$OC" adm policy add-role-to-user "$RL" "$U" -n "$N"; }
a_role_add_group() { local N RL G; form "Grant a Project Role to a Group"; ask_ns N || return; ask_role RL || return; ask G "Group" "" y names groups || return; run_change "$OC" adm policy add-role-to-group "$RL" "$G" -n "$N"; }
a_role_remove() { local N RL U; form "Remove a Project Role from a User"; ask_ns N || return; ask_role RL || return; ask_user U || return; run_change "$OC" adm policy remove-role-from-user "$RL" "$U" -n "$N"; }
a_crole_add()   { local RL U; form "Grant a Cluster Role to a User"; ask_crole RL || return; ask_user U || return; run_change "$OC" adm policy add-cluster-role-to-user "$RL" "$U"; }
a_crole_remove(){ local RL U; form "Remove a Cluster Role from a User"; ask_crole RL || return; ask_user U || return; run_change "$OC" adm policy remove-cluster-role-from-user "$RL" "$U"; }
a_group_new() {
  local G US; form "Create a Group"
  ask G  "Group name" "" y || return
  ask US "Users (space separated, optional)" "" n || return
  local -a users=(); read -ra users <<<"$US"
  run_change "$OC" adm groups new "$G" "${users[@]}"
}
a_group_add() {
  local G US; form "Add Users to a Group"
  ask G  "Group" "" y names groups || return
  ask US "Users (space separated)" "" y || return
  local -a users=(); read -ra users <<<"$US"
  run_change "$OC" adm groups add-users "$G" "${users[@]}"
}
a_sa_list()   { local N; form "List Service Accounts"; ask_ns N || return; run_view "$OC" get serviceaccounts -n "$N"; }
a_sa_create() { local N SA; form "Create a Service Account"; ask_ns N || return; ask SA "Service account name" "" y || return; run_change "$OC" create serviceaccount "$SA" -n "$N"; }
a_scc_list()  { run_view "$OC" get scc; }
a_scc_add() {
  local N SCC SA; form "Grant an SCC to a Service Account"
  ask SCC "SCC" "anyuid" y names scc || return
  ask_ns N || return
  ask SA  "Service account" "default" y names serviceaccount "$N" || return
  CONFIRM_NOTE="Granting privileged/anyuid SCCs weakens pod security - grant the least privilege needed."
  run_change "$OC" adm policy add-scc-to-user "$SCC" -z "$SA" -n "$N"
}
a_oauth_show() { run_view "$OC" get oauth cluster -o yaml; }
htpasswd_secret() { "$OC" get oauth cluster -o jsonpath='{.spec.identityProviders[?(@.type=="HTPasswd")].htpasswd.fileData.name}' 2>/dev/null | awk '{print $1}'; }
htpasswd_users()  { "$OC" extract "secret/$(htpasswd_secret)" -n openshift-config --keys=htpasswd --to=- 2>/dev/null | cut -d: -f1; }
a_htpasswd_set() {
  local SEC U PW PW2 d; form "Add / Change HTPasswd User Password"
  command -v htpasswd >/dev/null 2>&1 || { msg "'htpasswd' is not installed (RHEL/Fedora: httpd-tools, Debian/Ubuntu: apache2-utils)."; return; }
  SEC=$(htpasswd_secret)
  [[ -n $SEC ]] || { msg "No HTPasswd identity provider found in oauth/cluster."; return; }
  echo "  HTPasswd secret: openshift-config/$SEC"; echo
  ask U "User name" "" y htpasswd_users || return
  read -rsp "  * Password: " PW; echo
  read -rsp "  * Password again: " PW2; echo
  [[ -n $PW && $PW == "$PW2" ]] || { msg "Passwords empty or do not match."; return; }
  d=$(mktemp -d "${TMPDIR:-/tmp}/ocsmit-ht.XXXXXX"); chmod 700 "$d"
  "$OC" extract "secret/$SEC" -n openshift-config --keys=htpasswd --to="$d" --confirm >/dev/null 2>&1 \
    || { rm -rf "$d"; msg "Could not read secret openshift-config/$SEC - nothing changed."; return; }
  printf '%s\n' "$PW" | htpasswd -iB "$d/htpasswd" "$U" || { rm -rf "$d"; msg "htpasswd failed."; return; }
  PW=""; PW2=""
  backup_obj secret "$SEC" openshift-config
  CONFIRM_NOTE="The oauth-openshift pods restart automatically; allow 1-2 minutes before logging in."
  run_change "$OC" set data "secret/$SEC" -n openshift-config --from-file=htpasswd="$d/htpasswd"
  rm -rf "$d"
}
a_htpasswd_del() {
  local SEC U d; form "Remove an HTPasswd User"
  command -v htpasswd >/dev/null 2>&1 || { msg "'htpasswd' is not installed."; return; }
  SEC=$(htpasswd_secret); [[ -n $SEC ]] || { msg "No HTPasswd identity provider found."; return; }
  ask U "User to remove" "" y htpasswd_users || return
  [[ $U == "$CTX_USER" ]] && { msg "Refusing to remove the user you are logged in as."; return; }
  confirm_typed "$U" || return
  d=$(mktemp -d "${TMPDIR:-/tmp}/ocsmit-ht.XXXXXX"); chmod 700 "$d"
  "$OC" extract "secret/$SEC" -n openshift-config --keys=htpasswd --to="$d" --confirm >/dev/null 2>&1 || { rm -rf "$d"; msg "Could not read secret."; return; }
  htpasswd -D "$d/htpasswd" "$U"
  backup_obj secret "$SEC" openshift-config
  CONFIRM_NOTE="Also deletes the user/$U object and its identities."
  run_change f_htpasswd_del "$SEC" "$d/htpasswd" "$U"
  rm -rf "$d"
}
f_htpasswd_del() {
  "$OC" set data "secret/$1" -n openshift-config --from-file=htpasswd="$2" || return
  local id; for id in $("$OC" get user "$3" -o jsonpath='{.identities[*]}' 2>/dev/null); do "$OC" delete identity "$id"; done
  "$OC" delete user "$3" --ignore-not-found
}

#==============================================================================
#  8. NODES & MACHINE CONFIG
#==============================================================================
m_nodes() {
  menu "Nodes & Machine Config" \
    "List Nodes"                                 a_nodes \
    "List Nodes with Labels"                     a_nodes_labels \
    "Show Node Details"                          a_node_describe \
    "Node Resource Usage (top)"                  a_top_nodes \
    "View Node Service Logs (kubelet, crio)"     a_node_logs \
    "Cordon a Node (stop scheduling)"            a_cordon \
    "Uncordon a Node (resume scheduling)"        a_uncordon \
    "Drain a Node (evacuate pods)"               a_drain \
    "Add / Change / Remove a Node Label"         a_node_label \
    "Add / Remove a Node Taint"                  a_node_taint \
    "Open a Debug Shell on a Node"               a_node_debug \
    "List Machine Config Pools"                  a_mcp \
    "List Machine Configs"                       a_mc
}
ask_node()        { ask "$1" "Node" "$(names nodes 2>/dev/null | head -1)" y names nodes; }
a_nodes()         { run_view "$OC" get nodes -o wide; }
a_nodes_labels()  { run_view "$OC" get nodes --show-labels; }
a_top_nodes()     { run_view "$OC" adm top nodes; }
a_node_describe() { local ND; form "Show Node Details"; ask_node ND || return; run_view "$OC" describe node "$ND"; }
a_node_logs() {
  local ND U T; form "View Node Service Logs"
  ask_node ND || return
  ask U "Unit" "kubelet" y choices kubelet crio NetworkManager ovs-vswitchd || return
  ask T "Lines" "200" y || return
  run_view "$OC" adm node-logs "$ND" -u "$U" --tail="$T"
}
a_cordon()   { local ND; form "Cordon a Node"; ask_node ND || return; run_change "$OC" adm cordon "$ND"; }
a_uncordon() { local ND; form "Uncordon a Node"; ask_node ND || return; run_change "$OC" adm uncordon "$ND"; }
a_drain() {
  local ND TO cnt; form "Drain a Node"
  ask_node ND || return
  ask TO "Timeout" "300s" y || return
  cnt=$(names nodes 2>/dev/null | wc -l | tr -d ' ')
  if [[ $cnt == 1 ]]; then
    CONFIRM_NOTE="${RED}WARNING: this is a single-node cluster (e.g. OpenShift Local/CRC). Draining it evicts every workload.${R}"
  fi
  run_change "$OC" adm drain "$ND" --ignore-daemonsets --delete-emptydir-data --force --timeout="$TO"
}
a_node_label() {
  local ND L; form "Add / Change / Remove a Node Label"
  ask_node ND || return
  echo "    Use key=value to set, or key- to remove (e.g. node-role.kubernetes.io/infra=)"
  ask L "Label" "" y || return
  run_change "$OC" label node "$ND" "$L" --overwrite
}
a_node_taint() {
  local ND T; form "Add / Remove a Node Taint"
  ask_node ND || return
  echo "    Use key=value:NoSchedule|PreferNoSchedule|NoExecute to add, key- to remove"
  ask T "Taint" "" y || return
  run_change "$OC" adm taint nodes "$ND" "$T" --overwrite
}
a_node_debug() { local ND; form "Open a Debug Shell on a Node"; ask_node ND || return; echo "  Tip: run 'chroot /host' once inside."; run_tty view "$OC" debug "node/$ND"; }
a_mcp() { run_view "$OC" get machineconfigpool; }
a_mc()  { run_view "$OC" get machineconfig; }

#==============================================================================
#  9. CLUSTER CONFIGURATION
#==============================================================================
CFG_KINDS="apiserver authentication build console dns featuregate image infrastructure ingress network oauth project proxy scheduler"
m_clustercfg() {
  menu "Cluster Configuration (Operators, Ingress, Registry, Updates)" \
    "List Cluster Operators"                         a_co \
    "Show Update Status and Available Versions"      a_upgrade_status \
    "Change the Update Channel"                      a_upgrade_channel \
    "View a Cluster Config Resource (config.openshift.io)" a_cfg_view \
    "Edit a Cluster Config Resource"                 a_cfg_edit \
    "Show Ingress Controllers"                       a_ingress_show \
    "Change Ingress Controller Replicas"             a_ingress_replicas \
    "Show Image Registry Configuration"              a_registry_show \
    "Expose the Internal Image Registry Route"       a_registry_route \
    "List Installed Operators (CSVs)"                a_csv \
    "List Operator Subscriptions"                    a_subs \
    "List OperatorHub Catalog Sources"               a_catalogs
}
a_upgrade_status() { run_view "$OC" adm upgrade; }
a_upgrade_channel() {
  local cur CH; form "Change the Update Channel"
  cur=$("$OC" get clusterversion version -o jsonpath='{.spec.channel}' 2>/dev/null)
  ask CH "Channel (e.g. stable-4.18)" "$cur" y || return
  backup_obj clusterversion version
  run_change "$OC" adm upgrade channel "$CH"
}
ask_cfg_kind() { local -a k; read -ra k <<<"$CFG_KINDS"; ask "$1" "Config resource" "ingress" y choices "${k[@]}"; }
a_cfg_view() { local K; form "View a Cluster Config Resource"; ask_cfg_kind K || return; run_view "$OC" get "$K.config.openshift.io" cluster -o yaml; }
a_cfg_edit() {
  local K; form "Edit a Cluster Config Resource"
  ask_cfg_kind K || return
  echo "  ${YEL}Cluster-wide change. Some edits (proxy, image, apiserver) roll out to every node.${R}"
  confirm "Open editor?" || return
  edit_obj "$K.config.openshift.io" cluster
}
a_ingress_show() { run_view "$OC" get ingresscontroller -n openshift-ingress-operator -o wide; }
a_ingress_replicas() {
  local IC cur REP; form "Change Ingress Controller Replicas"
  ask IC "Ingress controller" "default" y names ingresscontroller openshift-ingress-operator || return
  cur=$("$OC" get ingresscontroller "$IC" -n openshift-ingress-operator -o jsonpath='{.spec.replicas}' 2>/dev/null)
  ask_num REP "Replicas" "${cur:-2}" || return
  backup_obj ingresscontroller "$IC" openshift-ingress-operator
  run_change "$OC" patch ingresscontroller "$IC" -n openshift-ingress-operator --type=merge -p "{\"spec\":{\"replicas\":$REP}}"
}
a_registry_show()  { run_view "$OC" get configs.imageregistry.operator.openshift.io cluster -o yaml; }
a_registry_route() {
  backup_obj configs.imageregistry.operator.openshift.io cluster
  run_change "$OC" patch configs.imageregistry.operator.openshift.io/cluster --type=merge -p '{"spec":{"defaultRoute":true}}'
}
a_csv()      { run_view "$OC" get csv -A; }
a_subs()     { run_view "$OC" get subscriptions.operators.coreos.com -A; }
a_catalogs() { run_view "$OC" get catalogsource -n openshift-marketplace; }

#==============================================================================
#  10. VIRTUALIZATION & MIGRATION (OpenShift Virtualization + MTV/Forklift)
#==============================================================================
m_virt() {
  menu "Virtualization & VM Migration (CNV / MTV)" \
    "List Virtual Machines (all projects)"       a_vm_list \
    "List Running VM Instances"                  a_vmi_list \
    "Show VM Details"                            a_vm_describe \
    "Start a VM"                                 a_vm_start \
    "Stop a VM"                                  a_vm_stop \
    "Restart a VM"                               a_vm_restart \
    "Live-Migrate a VM to Another Node"          a_vm_migrate \
    "Open VM Serial Console"                     a_vm_console \
    "Edit VM YAML"                               a_vm_edit \
    "List DataVolumes"                           a_dv_list \
    "List Network Attachment Definitions"        a_nad_list \
    "List Node Network Configuration (NMState)"  a_nncp_list \
    "MTV: List Providers (vSphere, oVirt, ...)"  a_mtv_providers \
    "MTV: List Migration Plans"                  a_mtv_plans \
    "MTV: Show Migration Plan Details"           a_mtv_plan_describe \
    "MTV: Start a Migration Plan"                a_mtv_start \
    "MTV: List Migrations (runs)"                a_mtv_migrations
}
have_virtctl() { command -v virtctl >/dev/null 2>&1; }
ask_vm() { ask_ns "$1" || return 1; ask "$2" "Virtual machine" "" y names vm "${!1}"; }
a_vm_list()  { run_view "$OC" get vm -A; }
a_vmi_list() { run_view "$OC" get vmi -A -o wide; }
a_vm_describe() { local N VM; form "Show VM Details"; ask_vm N VM || return; run_view "$OC" describe vm "$VM" -n "$N"; }
a_vm_start() {
  local N VM; form "Start a VM"; ask_vm N VM || return
  if have_virtctl; then run_change virtctl start "$VM" -n "$N"
  else run_change "$OC" patch vm "$VM" -n "$N" --type=merge -p '{"spec":{"runStrategy":"Always"}}'; fi
}
a_vm_stop() {
  local N VM; form "Stop a VM"; ask_vm N VM || return
  if have_virtctl; then run_change virtctl stop "$VM" -n "$N"
  else run_change "$OC" patch vm "$VM" -n "$N" --type=merge -p '{"spec":{"runStrategy":"Halted"}}'; fi
}
a_vm_restart() {
  local N VM; form "Restart a VM"; ask_vm N VM || return
  if have_virtctl; then run_change virtctl restart "$VM" -n "$N"
  else CONFIRM_NOTE="virtctl not found: deleting the VMI; the VM controller recreates it (runStrategy Always)."; run_change "$OC" delete vmi "$VM" -n "$N"; fi
}
a_vm_migrate() {
  local N VM f; form "Live-Migrate a VM"; ask_vm N VM || return
  if have_virtctl; then run_change virtctl migrate "$VM" -n "$N"; return; fi
  f=$(tmp_yaml)
  cat >"$f" <<EOF
apiVersion: kubevirt.io/v1
kind: VirtualMachineInstanceMigration
metadata:
  generateName: $VM-migration-
spec:
  vmiName: $VM
EOF
  CONFIRM_FILE=$f
  run_change "$OC" create -n "$N" -f "$f"
  rm -f "$f"
}
a_vm_console() {
  local N VM; form "Open VM Serial Console"; ask_vm N VM || return
  have_virtctl || { msg "virtctl is required for the console." "Download it from the web console: ? > Command line tools."; return; }
  echo "  Press Ctrl-] to exit the console."
  run_tty view virtctl console "$VM" -n "$N"
}
a_vm_edit()   { local N VM; form "Edit VM YAML"; ask_vm N VM || return; edit_obj vm "$VM" "$N"; }
a_dv_list()   { run_view "$OC" get datavolumes -A; }
a_nad_list()  { run_view "$OC" get network-attachment-definitions -A; }
a_nncp_list() { run_view f_nncp; }
f_nncp()      { "$OC" get nncp; echo; "$OC" get nnce; }
MTV_NS=${MTV_NS:-openshift-mtv}
a_mtv_providers()  { run_view "$OC" get providers.forklift.konveyor.io -A; }
a_mtv_plans()      { run_view "$OC" get plans.forklift.konveyor.io -A; }
a_mtv_migrations() { run_view "$OC" get migrations.forklift.konveyor.io -A; }
ask_plan() {
  ask "$1" "Plan namespace" "$MTV_NS" y names projects || return 1
  ask "$2" "Migration plan" "" y names plans.forklift.konveyor.io "${!1}"
}
a_mtv_plan_describe() { local PN PL; form "Show Migration Plan Details"; ask_plan PN PL || return; run_view "$OC" describe plans.forklift.konveyor.io "$PL" -n "$PN"; }
a_mtv_start() {
  local PN PL f; form "Start a Migration Plan"
  ask_plan PN PL || return
  f=$(tmp_yaml)
  cat >"$f" <<EOF
apiVersion: forklift.konveyor.io/v1beta1
kind: Migration
metadata:
  generateName: $PL-
  namespace: $PN
spec:
  plan:
    name: $PL
    namespace: $PN
EOF
  CONFIRM_FILE=$f
  CONFIRM_NOTE="Source VMs may be powered off during cold migration. Check the plan is Ready first."
  run_change "$OC" create -f "$f"
  rm -f "$f"
}

#==============================================================================
#  11. SETTINGS, LOGS, BACKUPS
#==============================================================================
m_settings() {
  menu "ocsmit Settings, Logs & Backups" \
    "Toggle Dry-Run (preview only) Mode"         a_toggle_dryrun \
    "Toggle Automatic YAML Backups"              a_toggle_backup \
    "Show Command Log (ocsmit.log)"              a_show_log \
    "Show Change Script (ocsmit.script)"         a_show_script \
    "List Backups"                               a_backups_list \
    "Restore an Object from a Backup"            a_backup_restore \
    "List kubeconfig Contexts"                   a_ctx_list \
    "Switch kubeconfig Context"                  a_ctx_use \
    "Log In to a Cluster"                        a_login
}
a_toggle_dryrun() { [[ $DRYRUN == yes ]] && DRYRUN=no || DRYRUN=yes; msg "Dry-run mode is now: $DRYRUN"; }
a_toggle_backup() { [[ $AUTO_BACKUP == yes ]] && AUTO_BACKUP=no || AUTO_BACKUP=yes; msg "Automatic backups are now: $AUTO_BACKUP"; }
a_show_log()      { header "ocsmit.log"; [[ -s $LOG_FILE ]] && page_file "$LOG_FILE" || echo "  (empty)"; pause; }
a_show_script()   { header "ocsmit.script"; [[ -s $SCRIPT_FILE ]] && page_file "$SCRIPT_FILE" || echo "  (empty)"; pause; }
a_backups_list()  { header "Backups in $BACKUP_DIR"; ls -lt "$BACKUP_DIR" 2>/dev/null; pause; }
a_backup_restore() {
  local F f; form "Restore an Object from a Backup"
  ask F "Backup file" "$(ls_backups | head -1)" y ls_backups || return
  [[ -f $BACKUP_DIR/$F ]] || { msg "Not found: $F"; return; }
  f=$(tmp_yaml)
  # strip server-managed fields so the object can be re-applied
  sed -e '/^  resourceVersion:/d' -e '/^  uid:/d' -e '/^  creationTimestamp:/d' \
      -e '/^  generation:/d' -e '/^  selfLink:/d' -e '/^status:/,$d' "$BACKUP_DIR/$F" >"$f"
  CONFIRM_FILE=$f
  run_change "$OC" apply -f "$f"
  rm -f "$f"
}
a_ctx_list() { run_view "$OC" config get-contexts; }
a_ctx_use()  { local C; form "Switch kubeconfig Context"; ask C "Context" "" y ls_contexts || return; run_view "$OC" config use-context "$C"; refresh_ctx; }
a_login() {
  local S U; form "Log In to a Cluster"
  local def=$CTX_SERVER; [[ $def == http* ]] || def="https://api.crc.testing:6443"
  ask S "API server URL" "$def" y || return
  ask U "User name" "kubeadmin" y || return
  run_tty view "$OC" login "$S" -u "$U"
  refresh_ctx
}

a_help() {
  header "ocsmit Help"
  cat <<'EOF'
  MENUS            number = select    b = back    q = exit
                   / = fastpath (e.g. /scale)   r = refresh login info   l = log
  ENTRY FIELDS     Enter = accept the [default]   ? = list choices (like F4)
                   ! = cancel the dialog          Tab = filename completion
  CHANGES          Every change shows the exact oc command and asks ARE YOU SURE.
                   Objects are saved as YAML in ~/.ocsmit/backups before changes.
                   Successful changes are appended to ~/.ocsmit/ocsmit.script.

  FASTPATHS (also usable as:  ocsmit.sh <fastpath>)
    health cluster  proj  workload deploy  scale  restart  image  logs  rsh
    config cm secret env  net route netpol  storage pvc  security rbac user
    htpasswd  nodes node drain  clustercfg operators upgrade  virt vm mtv
    settings  login
EOF
  pause
}

#------------------------------------------------------------------------------
#  Fastpaths (smitty <fastpath>)
#------------------------------------------------------------------------------
fastpath() {
  case $1 in
    main|top)                m_main ;;
    health|cluster)          m_cluster ;;
    proj|project|projects)   m_projects ;;
    workload|workloads|deploy) m_workloads ;;
    scale)                   a_scale ;;
    restart)                 a_restart ;;
    image)                   a_set_image ;;
    logs|log)                a_logs ;;
    rsh)                     a_rsh ;;
    config|cm|secret)        m_config ;;
    env)                     a_env_set ;;
    net|network|route)       m_network ;;
    netpol)                  a_np_template ;;
    storage|pvc)             m_storage ;;
    security|rbac|user|users) m_security ;;
    htpasswd)                a_htpasswd_set ;;
    nodes|node)              m_nodes ;;
    drain)                   a_drain ;;
    clustercfg|operators|co) m_clustercfg ;;
    upgrade)                 a_upgrade_status ;;
    virt|vm|vms|mtv)         m_virt ;;
    settings|log-show)       m_settings ;;
    login)                   a_login ;;
    *) return 1 ;;
  esac
  return 0
}

usage() { sed -n '2,/^#====*$/p' "$0" | sed -e 's/^#//' -e '/^====/d'; }

#------------------------------------------------------------------------------
#  Start-up
#------------------------------------------------------------------------------
main() {
  local opt
  while getopts ":dBhV" opt; do
    case $opt in
      d) DRYRUN=yes ;;
      B) AUTO_BACKUP=no ;;
      h) usage; exit 0 ;;
      V) echo "ocsmit $VERSION"; exit 0 ;;
      *) usage; exit 2 ;;
    esac
  done
  shift $((OPTIND - 1))

  command -v "$OC" >/dev/null 2>&1 || { echo "ocsmit: '$OC' not found in PATH. Install the OpenShift CLI first." >&2; exit 1; }
  mkdir -p "$OCSMIT_HOME" "$BACKUP_DIR" && chmod 700 "$OCSMIT_HOME"
  trap 'echo; quit' INT

  refresh_ctx
  if ! "$OC" whoami >/dev/null 2>&1; then
    echo "You are not logged in to an OpenShift cluster."
    if confirm "Log in now?"; then a_login; fi
  fi
  trap - INT

  if [[ -n ${1:-} ]]; then
    fastpath "$1" || { echo "ocsmit: unknown fastpath '$1' (use -h for the list)" >&2; exit 2; }
    [[ $1 == main || $1 == top ]] || quit
  fi
  m_main
  quit
}

main "$@"
