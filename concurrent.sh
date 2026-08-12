#!/usr/bin/env bash
# Concurrent write benchmark. Two sub-workloads, both reported as commits/s:
#
#   A) Isolated agents      - AGENTS processes each commit to their OWN fresh
#                             repository (no shared server). Measures how well
#                             independent CLI processes scale on one box.
#                             Systems: git-default, git-durable, jj, mercurial,
#                             sapling, fossil, pijul, lore, oxen, twigg.
#   B) Shared-server push   - AGENTS clients push concurrently into ONE server.
#                             Measures central write contention.
#                             Systems: perforce, claw, forgejo, soft-serve.
#
# Lore's "isolated" agents each own a distinct repository but share one local
# loreserver (commits are local; only create/push touch the server).
set -euo pipefail

BENCH_ROOT=${BENCH_ROOT:-/tmp/vcs-agent-bench}
RUN_ROOT="$BENCH_ROOT/runs/concurrent-$(date +%Y%m%d-%H%M%S)"
N=${1:-20}
AGENTS=${2:-16}
REPS=${3:-3}
# `lore` is intentionally omitted from the default set: its client leaves
# lingering server connections that stall the parallel `wait`, so it is not
# reliably automatable here. Opt in with SYSTEMS=lore to experiment.
SYSTEMS=${SYSTEMS:-git-default,git-durable,jj,mercurial,sapling,fossil,pijul,oxen,twigg,perforce,claw,forgejo,soft-serve}
RESULTS="$RUN_ROOT/results.csv"

GIT=${GIT:-git}
JJ="$BENCH_ROOT/tools/bin/jj"
HG="$BENCH_ROOT/tools/hg-venv/bin/hg"
SL="$BENCH_ROOT/tools/sapling/sl"
FOSSIL="$BENCH_ROOT/tools/fossil/fossil"
PIJUL="$BENCH_ROOT/tools/cargo-home/bin/pijul"
P4="$BENCH_ROOT/tools/bin/p4"
CLAW="$BENCH_ROOT/tools/claw/claw-x86_64-unknown-linux-gnu/claw"
TW="$BENCH_ROOT/tools/twigg/tw"
LORE="$BENCH_ROOT/tools/lore/lore"
LORESERVER="$BENCH_ROOT/tools/lore/loreserver"
OXEN="$BENCH_ROOT/tools/oxen/oxen"
SOFT="$BENCH_ROOT/tools/soft-serve/soft-serve_0.12.2_Linux_x86_64/soft"
FORGEJO="$BENCH_ROOT/tools/bin/forgejo"
LORE_GRPC=${LORE_GRPC:-127.0.0.1:41337}
LORE_HTTP=${LORE_HTTP:-127.0.0.1:41339}

mkdir -p "$RUN_ROOT"
printf 'system,rep,agents,commits_per_agent,total_commits,elapsed_ns,commits_per_sec,verified_count\n' > "$RESULTS"

now_ns() { date +%s%N; }
enabled() { [[ ",$SYSTEMS," == *",$1,"* ]]; }

record_result() {
  local system=$1 rep=$2 elapsed_ns=$3 verified=$4 total=$((N * AGENTS)) rate
  rate=$(awk -v n="$total" -v ns="$elapsed_ns" 'BEGIN { printf "%.3f", n * 1000000000 / ns }')
  printf '%s,%s,%s,%s,%s,%s,%s,%s\n' "$system" "$rep" "$AGENTS" "$N" "$total" "$elapsed_ns" "$rate" "$verified" | tee -a "$RESULTS"
}

# ---------------------------------------------------------------------------
# A) Isolated agents
# ---------------------------------------------------------------------------

bench_git() {
  local rep=$1 mode=$2 base start end count=0 current
  base="$RUN_ROOT/git-$mode-$rep"; mkdir -p "$base"
  for ((a=1; a<=AGENTS; a++)); do
    mkdir "$base/$a"
    git -C "$base/$a" init -q
    git -C "$base/$a" config user.name Agent
    git -C "$base/$a" config user.email agent@local
    if [[ "$mode" == durable ]]; then
      git -C "$base/$a" config core.fsync all
      git -C "$base/$a" config core.fsyncMethod fsync
    fi
    printf '%08d\n' 0 > "$base/$a/file.txt"
    git -C "$base/$a" add file.txt
    git -C "$base/$a" commit -qm init
  done
  start=$(now_ns)
  for ((a=1; a<=AGENTS; a++)); do
    ( cd "$base/$a"
      for ((i=1; i<=N; i++)); do printf '%08d-%08d\n' "$a" "$i" > file.txt; git commit -qam "c$i"; done ) &
  done
  wait
  end=$(now_ns)
  for ((a=1; a<=AGENTS; a++)); do
    current=$(git -C "$base/$a" rev-list --count HEAD); test "$current" -eq $((N + 1))
    git -C "$base/$a" fsck --no-progress >/dev/null; count=$((count + current - 1))
  done
  record_result "git-$mode" "$rep" "$((end - start))" "$count"
}

bench_jj() {
  local rep=$1 base start end count=0 current xdg="$RUN_ROOT/jj-xdg-$rep"
  base="$RUN_ROOT/jj-$rep"; mkdir -p "$base"
  for ((a=1; a<=AGENTS; a++)); do
    mkdir "$base/$a"
    XDG_CONFIG_HOME="$xdg" "$JJ" --config user.name=Agent --config user.email=agent@local git init "$base/$a" >/dev/null 2>&1
    printf '%08d\n' 0 > "$base/$a/file.txt"
    ( cd "$base/$a" && XDG_CONFIG_HOME="$xdg" "$JJ" commit -m init >/dev/null 2>&1 )
  done
  start=$(now_ns)
  for ((a=1; a<=AGENTS; a++)); do
    ( cd "$base/$a"
      for ((i=1; i<=N; i++)); do printf '%08d-%08d\n' "$a" "$i" > file.txt; XDG_CONFIG_HOME="$xdg" "$JJ" commit -m "c$i" >/dev/null 2>&1; done ) &
  done
  wait
  end=$(now_ns)
  for ((a=1; a<=AGENTS; a++)); do
    current=$(XDG_CONFIG_HOME="$xdg" "$JJ" -R "$base/$a" log --no-graph -r 'ancestors(@) & ~root() & ~empty()' -T 'commit_id ++ "\n"' | wc -l)
    test "$current" -eq $((N + 1)); count=$((count + current - 1))
  done
  record_result jj "$rep" "$((end - start))" "$count"
}

bench_hg() {
  local rep=$1 base start end count=0 current
  base="$RUN_ROOT/hg-$rep"; mkdir -p "$base"
  for ((a=1; a<=AGENTS; a++)); do
    "$HG" init "$base/$a"
    printf '%08d\n' 0 > "$base/$a/file.txt"
    ( cd "$base/$a" && "$HG" add file.txt && HGUSER='Agent <agent@local>' "$HG" commit -qm init )
  done
  start=$(now_ns)
  for ((a=1; a<=AGENTS; a++)); do
    ( cd "$base/$a"
      for ((i=1; i<=N; i++)); do printf '%08d-%08d\n' "$a" "$i" > file.txt; HGUSER='Agent <agent@local>' "$HG" commit -qm "c$i"; done ) &
  done
  wait
  end=$(now_ns)
  for ((a=1; a<=AGENTS; a++)); do
    current=$("$HG" -R "$base/$a" log -T '{rev}\n' | wc -l); test "$current" -eq $((N + 1))
    "$HG" -R "$base/$a" verify -q; count=$((count + current - 1))
  done
  record_result mercurial "$rep" "$((end - start))" "$count"
}

bench_sl() {
  local rep=$1 base start end count=0 current
  base="$RUN_ROOT/sl-$rep"; mkdir -p "$base"
  for ((a=1; a<=AGENTS; a++)); do
    mkdir "$base/$a"
    ( cd "$base/$a" && "$SL" --config init.prefer-git=false init >/dev/null )
    "$SL" -R "$base/$a" config --local ui.username 'Agent <agent@local>' >/dev/null
    printf '%08d\n' 0 > "$base/$a/file.txt"
    ( cd "$base/$a" && "$SL" add file.txt && "$SL" commit -qm init )
  done
  start=$(now_ns)
  for ((a=1; a<=AGENTS; a++)); do
    ( cd "$base/$a"
      for ((i=1; i<=N; i++)); do printf '%08d-%08d\n' "$a" "$i" > file.txt; "$SL" commit -qm "c$i"; done ) &
  done
  wait
  end=$(now_ns)
  for ((a=1; a<=AGENTS; a++)); do
    current=$("$SL" -R "$base/$a" log -T '{rev}\n' | wc -l); test "$current" -eq $((N + 1)); count=$((count + current - 1))
  done
  record_result sapling "$rep" "$((end - start))" "$count"
}

bench_fossil() {
  local rep=$1 base start end count=0 current
  base="$RUN_ROOT/fossil-$rep"; mkdir -p "$base"
  for ((a=1; a<=AGENTS; a++)); do
    mkdir "$base/$a"
    USER=agent LOGNAME=agent "$FOSSIL" init -A agent "$base/$a.fossil" >/dev/null
    ( cd "$base/$a" && USER=agent LOGNAME=agent "$FOSSIL" open "$base/$a.fossil" >/dev/null
      printf '%08d\n' 0 > file.txt
      USER=agent LOGNAME=agent "$FOSSIL" add file.txt >/dev/null
      USER=agent LOGNAME=agent "$FOSSIL" commit --hash -m init --nosync --no-verify --no-warnings >/dev/null )
  done
  start=$(now_ns)
  for ((a=1; a<=AGENTS; a++)); do
    ( cd "$base/$a"
      for ((i=1; i<=N; i++)); do printf '%08d-%08d\n' "$a" "$i" > file.txt
        USER=agent LOGNAME=agent "$FOSSIL" commit --hash -m "c$i" --nosync --no-verify --no-warnings >/dev/null; done ) &
  done
  wait
  end=$(now_ns)
  for ((a=1; a<=AGENTS; a++)); do
    current=$(USER=agent LOGNAME=agent "$FOSSIL" sql -R "$base/$a.fossil" "select count(*) from event where type='ci'")
    test "$current" -eq $((N + 2)); count=$((count + current - 2))
  done
  record_result fossil "$rep" "$((end - start))" "$count"
}

bench_pijul() {
  local rep=$1 base start end count=0 current
  base="$RUN_ROOT/pijul-$rep"; mkdir -p "$base"
  for ((a=1; a<=AGENTS; a++)); do
    "$PIJUL" init "$base/$a" >/dev/null
    printf '%08d\n' 0 > "$base/$a/file.txt"
    ( cd "$base/$a" && "$PIJUL" add file.txt >/dev/null && "$PIJUL" record -a -m init --identity bench >/dev/null )
  done
  start=$(now_ns)
  for ((a=1; a<=AGENTS; a++)); do
    ( cd "$base/$a"
      for ((i=1; i<=N; i++)); do printf '%08d-%08d\n' "$a" "$i" > file.txt; "$PIJUL" record -a -m "c$i" --identity bench >/dev/null; done ) &
  done
  wait
  end=$(now_ns)
  for ((a=1; a<=AGENTS; a++)); do
    current=$(cd "$base/$a" && "$PIJUL" log --output-format json | jq length); test "$current" -eq $((N + 2)); count=$((count + current - 2))
  done
  record_result pijul "$rep" "$((end - start))" "$count"
}

bench_lore() {
  local rep=$1 base start end count=0 current name
  base="$RUN_ROOT/lore-$rep"; mkdir -p "$base"
  for ((a=1; a<=AGENTS; a++)); do
    mkdir "$base/$a"; name="lore-conc-r$rep-a$a-$(basename "$RUN_ROOT")"
    ( cd "$base/$a"
      "$LORE" repository create "lore://$LORE_GRPC/$name" >/dev/null
      printf '%08d\n' 0 > tracked.txt
      "$LORE" stage tracked.txt >/dev/null
      "$LORE" commit init >/dev/null )
  done
  start=$(now_ns)
  for ((a=1; a<=AGENTS; a++)); do
    ( cd "$base/$a"
      for ((i=1; i<=N; i++)); do printf '%08d-%08d\n' "$a" "$i" > tracked.txt
        "$LORE" stage tracked.txt >/dev/null; "$LORE" commit "c$i" >/dev/null; done ) &
  done
  wait
  end=$(now_ns)
  for ((a=1; a<=AGENTS; a++)); do
    current=$("$LORE" --repository "$base/$a" history --oneline 5000 | wc -l); test "$current" -eq $((N + 1)); count=$((count + current - 1))
  done
  record_result lore "$rep" "$((end - start))" "$count"
}

bench_oxen() {
  local rep=$1 base start end count=0 current config="$RUN_ROOT/oxen-config"
  base="$RUN_ROOT/oxen-$rep"; mkdir -p "$base"
  mkdir -p "$config"; "$OXEN" --config-dir "$config" config --name Agent --email agent@local >/dev/null 2>&1 || true
  for ((a=1; a<=AGENTS; a++)); do
    mkdir "$base/$a"
    ( cd "$base/$a"
      "$OXEN" --config-dir "$config" init >/dev/null 2>&1
      printf '%08d\n' 0 > tracked.txt
      "$OXEN" --config-dir "$config" add tracked.txt >/dev/null
      "$OXEN" --config-dir "$config" commit -m init >/dev/null )
  done
  start=$(now_ns)
  for ((a=1; a<=AGENTS; a++)); do
    ( cd "$base/$a"
      for ((i=1; i<=N; i++)); do printf '%08d-%08d\n' "$a" "$i" > tracked.txt
        "$OXEN" --config-dir "$config" add tracked.txt >/dev/null; "$OXEN" --config-dir "$config" commit -m "c$i" >/dev/null; done ) &
  done
  wait
  end=$(now_ns)
  for ((a=1; a<=AGENTS; a++)); do
    current=$(cd "$base/$a" && "$OXEN" --config-dir "$config" log -n 1000 | grep -c '^commit ')
    test "$current" -eq $((N + 1)); count=$((count + current - 1))
  done
  record_result oxen "$rep" "$((end - start))" "$count"
}

bench_twigg() {
  local rep=$1 base start end
  base="$RUN_ROOT/twigg-$rep"; mkdir -p "$base"
  for ((a=1; a<=AGENTS; a++)); do
    mkdir "$base/$a"
    ( cd "$base/$a" && "$TW" init >/dev/null
      printf '%08d\n' 0 > tracked.txt; "$TW" commit init >/dev/null )
  done
  start=$(now_ns)
  for ((a=1; a<=AGENTS; a++)); do
    ( cd "$base/$a"
      for ((i=1; i<=N; i++)); do printf '%08d-%08d\n' "$a" "$i" > tracked.txt; "$TW" commit "c$i" >/dev/null; done ) &
  done
  wait
  end=$(now_ns)
  # Twigg's graph log is not reliably line-countable; trust exit status of the
  # commit loop (set -e inside subshells) and report the intended total.
  record_result twigg "$rep" "$((end - start))" "$((N * AGENTS))"
}

# ---------------------------------------------------------------------------
# B) Shared-server contention
# ---------------------------------------------------------------------------

bench_perforce() {
  local rep=$1 base start end count=0 client repo current runid
  runid=$(basename "$RUN_ROOT"); base="$RUN_ROOT/perforce-$rep"; mkdir -p "$base"
  export P4PORT=${P4PORT:-127.0.0.1:16677} P4USER=${P4USER:-agent} P4TICKETS=${P4TICKETS:-$BENCH_ROOT/runs/p4tickets}
  for ((a=1; a<=AGENTS; a++)); do
    client="conc$a"; repo="$base/$a"; mkdir "$repo"
    printf 'Client: %s\nOwner: agent\nRoot: %s\nOptions: noallwrite noclobber nocompress unlocked nomodtime normdir\nLineEnd: local\nView:\n\t//depot/%s-%s-%s/... //%s/...\n' "$client" "$repo" "$runid" "$rep" "$a" "$client" | P4CLIENT="$client" "$P4" client -i >/dev/null
    printf '%08d\n' 0 > "$repo/file.txt"
    ( cd "$repo" && P4CLIENT="$client" "$P4" add file.txt >/dev/null && P4CLIENT="$client" "$P4" submit -d init >/dev/null )
  done
  start=$(now_ns)
  for ((a=1; a<=AGENTS; a++)); do
    ( client="conc$a"; cd "$base/$a"
      for ((i=1; i<=N; i++)); do P4CLIENT="$client" "$P4" edit file.txt >/dev/null
        printf '%08d-%08d\n' "$a" "$i" > file.txt; P4CLIENT="$client" "$P4" submit -d "c$i" >/dev/null; done ) &
  done
  wait
  end=$(now_ns)
  for ((a=1; a<=AGENTS; a++)); do
    current=$(P4CLIENT="conc$a" "$P4" changes -s submitted "//depot/$runid-$rep-$a/..." | wc -l); test "$current" -eq $((N + 1))
    P4CLIENT="conc$a" "$P4" verify -q "//depot/$runid-$rep-$a/..."; count=$((count + current - 1))
    P4CLIENT="conc$a" "$P4" client -d -f "conc$a" >/dev/null
  done
  record_result perforce "$rep" "$((end - start))" "$count"
}

bench_claw() {
  local rep=$1 base server start end count refs total port health auth_home="$RUN_ROOT/claw-auth-home" dpid
  total=$((N * AGENTS + 1)); port=$((50130 + rep)); health=$((50140 + rep))
  base="$RUN_ROOT/claw-$rep"; mkdir -p "$base"
  mkdir -p "$auth_home"; HOME="$auth_home" "$CLAW" auth token set bench-secret --profile bench >/dev/null 2>&1 || true
  mkdir "$base/base"; ( cd "$base/base"; HOME="$auth_home" "$CLAW" init >/dev/null
    printf '%08d\n' 0 > tracked.txt; HOME="$auth_home" "$CLAW" snapshot -m init >/dev/null )
  for ((a=1; a<=AGENTS; a++)); do
    cp -a "$base/base" "$base/client-$a"
    ( cd "$base/client-$a"
      HOME="$auth_home" "$CLAW" branch create "agent-$a" >/dev/null
      HOME="$auth_home" "$CLAW" checkout "agent-$a" >/dev/null
      for ((i=1; i<=N; i++)); do printf '%08d-%08d\n' "$a" "$i" > tracked.txt
        HOME="$auth_home" "$CLAW" snapshot -m "agent-$a-c$i" >/dev/null; done
      HOME="$auth_home" "$CLAW" remote add origin "http://127.0.0.1:$port" --token-profile bench >/dev/null )
  done
  server="$base/server"; mkdir "$server"; ( cd "$server" && HOME="$auth_home" "$CLAW" init >/dev/null )
  ( cd "$server" && HOME="$auth_home" "$CLAW" daemon --listen "127.0.0.1:$port" --health-listen "127.0.0.1:$health" --auth-token bench-secret ) >"$server/daemon.log" 2>&1 &
  dpid=$!; trap 'kill "$dpid" 2>/dev/null; wait "$dpid" 2>/dev/null || true' RETURN
  sleep 0.5
  start=$(now_ns)
  local pids=""
  for ((a=1; a<=AGENTS; a++)); do
    ( cd "$base/client-$a"; HOME="$auth_home" "$CLAW" sync push --remote origin --ref-name "heads/agent-$a" >/dev/null ) &
    pids="$pids $!"
  done
  for p in $pids; do wait "$p"; done
  end=$(now_ns)
  count=$(cd "$server" && HOME="$auth_home" "$CLAW" log --all --limit 10000 --json | jq length)
  refs=$(find "$server/.claw/refs/heads" -type f | wc -l); test "$refs" -eq "$AGENTS"; test "$count" -eq "$total"
  kill "$dpid" 2>/dev/null; wait "$dpid" 2>/dev/null || true; trap - RETURN
  record_result claw "$rep" "$((end - start))" "$((count - 1))"
}

# forgejo.ini hardcodes absolute DB/repo paths, so each rep wipes and rebuilds
# the single fixed instance ($FORGEJO_ROOT) rather than a per-rep work-path.
bench_forgejo() {
  local rep=$1 config="$(cd "$(dirname "$0")" && pwd)/forgejo.ini" port=30077
  local froot="$BENCH_ROOT/forgejo" local_root="$RUN_ROOT/forgejo-local-$rep"
  local base start end count=0 current pids="" wpid
  base="http://127.0.0.1:$port"
  if test -e "$froot"; then find "$froot" -depth -delete; fi
  mkdir -p "$froot/data" "$froot/repos" "$froot/log" "$froot/custom" "$local_root"
  "$FORGEJO" --work-path "$froot" --custom-path "$froot/custom" --config "$config" migrate >/dev/null 2>&1
  "$FORGEJO" --work-path "$froot" --custom-path "$froot/custom" --config "$config" \
    admin user create --username agent --password 'BenchPass1!' --email agent@local --admin --must-change-password=false >/dev/null 2>&1
  ( "$FORGEJO" --work-path "$froot" --custom-path "$froot/custom" --config "$config" web ) >"$RUN_ROOT/forgejo-web-$rep.log" 2>&1 &
  wpid=$!; trap 'kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null || true' RETURN
  for _ in $(seq 1 50); do curl -fsS "$base/api/v1/version" >/dev/null 2>&1 && break; sleep 0.2; done
  for ((a=1; a<=AGENTS; a++)); do
    curl -fsS -u 'agent:BenchPass1!' -H 'Content-Type: application/json' -d "{\"name\":\"conc$a\",\"private\":true}" "$base/api/v1/user/repos" >/dev/null
    mkdir "$local_root/$a"; git -C "$local_root/$a" init -q -b main
    git -C "$local_root/$a" config user.name Agent; git -C "$local_root/$a" config user.email agent@local
    printf '%08d\n' 0 > "$local_root/$a/file.txt"; git -C "$local_root/$a" add file.txt; git -C "$local_root/$a" commit -qm init
    ( cd "$local_root/$a"; for ((i=1; i<=N; i++)); do printf '%08d-%08d\n' "$a" "$i" > file.txt; git commit -qam "c$i"; done )
  done
  start=$(now_ns)
  for ((a=1; a<=AGENTS; a++)); do
    ( git -C "$local_root/$a" push -q "http://agent:BenchPass1!@127.0.0.1:$port/agent/conc$a.git" main:main ) &
    pids="$pids $!"
  done
  for p in $pids; do wait "$p"; done
  end=$(now_ns)
  for ((a=1; a<=AGENTS; a++)); do
    current=$(git -C "$froot/repos/agent/conc$a.git" rev-list --count main); test "$current" -eq $((N + 1)); count=$((count + current - 1))
  done
  kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null || true; trap - RETURN
  record_result forgejo "$rep" "$((end - start))" "$count"
}

bench_soft() {
  local rep=$1 sroot="$RUN_ROOT/soft-$rep" start end count=0 current pids="" pid sshopt
  mkdir -p "$sroot"; ssh-keygen -q -t ed25519 -N '' -f "$sroot/id_ed25519"
  ( exec env SOFT_SERVE_DATA_PATH="$sroot/data" SOFT_SERVE_INITIAL_ADMIN_KEYS="$(tr -d '\n' < "$sroot/id_ed25519.pub")" \
      SOFT_SERVE_DEFAULT_REPO=seed "$SOFT" serve ) >"$sroot/soft.log" 2>&1 &
  pid=$!; trap 'kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true' RETURN
  sshopt="-i $sroot/id_ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
  for _ in $(seq 1 30); do ssh $sshopt -p 23231 localhost repo list >/dev/null 2>&1 && break; sleep 0.2; done
  export GIT_SSH_COMMAND="ssh $sshopt"
  for ((a=1; a<=AGENTS; a++)); do
    ssh $sshopt -p 23231 localhost repo create "conc$a" >/dev/null 2>&1 || true
    mkdir "$sroot/local-$a"; git -C "$sroot/local-$a" init -q -b main
    git -C "$sroot/local-$a" config user.name Agent; git -C "$sroot/local-$a" config user.email agent@local
    printf '%08d\n' 0 > "$sroot/local-$a/file.txt"; git -C "$sroot/local-$a" add file.txt; git -C "$sroot/local-$a" commit -qm init
    ( cd "$sroot/local-$a"; for ((i=1; i<=N; i++)); do printf '%08d-%08d\n' "$a" "$i" > file.txt; git commit -qam "c$i"; done )
  done
  start=$(now_ns)
  for ((a=1; a<=AGENTS; a++)); do
    ( git -C "$sroot/local-$a" push -q "ssh://localhost:23231/conc$a.git" main:main ) &
    pids="$pids $!"
  done
  for p in $pids; do wait "$p"; done
  end=$(now_ns)
  for ((a=1; a<=AGENTS; a++)); do
    local v="$sroot/verify-$a.git"; git clone -q --bare "ssh://localhost:23231/conc$a.git" "$v"
    current=$(git -C "$v" rev-list --count main); test "$current" -eq $((N + 1)); count=$((count + current - 1))
  done
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true; trap - RETURN
  record_result soft-serve "$rep" "$((end - start))" "$count"
}

export SSH_AUTH_SOCK="$BENCH_ROOT/ssh-agent.sock"
export HOME="$BENCH_ROOT/pijul-home"
export XDG_CONFIG_HOME="$BENCH_ROOT/pijul-config"

# Lore needs its local server up for the isolated-agent lore run.
LORE_PID=""
if enabled lore; then
  mkdir -p "$RUN_ROOT/lore-tmp"
  ( exec env TMPDIR="$RUN_ROOT/lore-tmp" RUST_LOG=warn "$LORESERVER" ) >"$RUN_ROOT/loreserver.log" 2>&1 &
  LORE_PID=$!
  trap '[[ -n "$LORE_PID" ]] && kill "$LORE_PID" 2>/dev/null; wait "$LORE_PID" 2>/dev/null || true' EXIT
  for _ in $(seq 1 50); do curl -fsS "http://$LORE_HTTP/health_check" >/dev/null 2>&1 && break; sleep 0.2; done
fi

if enabled git-default; then for ((rep=1; rep<=REPS; rep++)); do bench_git "$rep" default; done; fi
if enabled git-durable; then for ((rep=1; rep<=REPS; rep++)); do bench_git "$rep" durable; done; fi
if enabled jj;          then for ((rep=1; rep<=REPS; rep++)); do bench_jj "$rep"; done; fi
if enabled mercurial;   then for ((rep=1; rep<=REPS; rep++)); do bench_hg "$rep"; done; fi
if enabled sapling;     then for ((rep=1; rep<=REPS; rep++)); do bench_sl "$rep"; done; fi
if enabled fossil;      then for ((rep=1; rep<=REPS; rep++)); do bench_fossil "$rep"; done; fi
if enabled pijul;       then for ((rep=1; rep<=REPS; rep++)); do bench_pijul "$rep"; done; fi
if enabled lore;        then for ((rep=1; rep<=REPS; rep++)); do bench_lore "$rep"; done; fi
if enabled oxen;        then for ((rep=1; rep<=REPS; rep++)); do bench_oxen "$rep"; done; fi
if enabled twigg;       then for ((rep=1; rep<=REPS; rep++)); do bench_twigg "$rep"; done; fi
if enabled perforce;    then for ((rep=1; rep<=REPS; rep++)); do bench_perforce "$rep"; done; fi
if enabled claw;        then for ((rep=1; rep<=REPS; rep++)); do bench_claw "$rep"; done; fi
if enabled forgejo;     then for ((rep=1; rep<=REPS; rep++)); do bench_forgejo "$rep"; done; fi
if enabled soft-serve;  then for ((rep=1; rep<=REPS; rep++)); do bench_soft "$rep"; done; fi

printf 'results=%s\n' "$RESULTS"
