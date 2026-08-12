#!/usr/bin/env bash
set -euo pipefail

BENCH_ROOT=${BENCH_ROOT:-/tmp/vcs-agent-bench}
RUN_ROOT="$BENCH_ROOT/runs/cli-$(date +%Y%m%d-%H%M%S)"
N=${1:-100}
REPS=${2:-1}
SYSTEMS=${SYSTEMS:-git-default,git-durable,jj,mercurial,sapling,fossil,pijul,perforce,claw,twigg,lore-default,lore-durable,oxen}
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
OXEN_CONFIG="$RUN_ROOT/oxen-config"
LORE_GRPC=${LORE_GRPC:-127.0.0.1:41337}
LORE_HTTP=${LORE_HTTP:-127.0.0.1:41339}

mkdir -p "$RUN_ROOT"
printf 'system,rep,commits,elapsed_ns,commits_per_sec,verified_count,store_kib\n' > "$RESULTS"

now_ns() {
  date +%s%N
}

store_kib() {
  du -sk "$1" | awk '{print $1}'
}

record_result() {
  local system=$1 rep=$2 commits=$3 elapsed_ns=$4 verified=$5 size=$6
  local rate
  rate=$(awk -v n="$commits" -v ns="$elapsed_ns" 'BEGIN { printf "%.3f", n * 1000000000 / ns }')
  printf '%s,%s,%s,%s,%s,%s,%s\n' "$system" "$rep" "$commits" "$elapsed_ns" "$rate" "$verified" "$size" | tee -a "$RESULTS"
}

enabled() {
  [[ ",$SYSTEMS," == *",$1,"* ]]
}

bench_git() {
  local rep=$1 mode=$2
  local repo="$RUN_ROOT/git-$mode-$rep" start end count size
  mkdir "$repo"
  cd "$repo"
  "$GIT" init -q
  "$GIT" config user.name Agent
  "$GIT" config user.email agent@local
  if [[ "$mode" == durable ]]; then
    "$GIT" config core.fsync all
    "$GIT" config core.fsyncMethod fsync
  fi
  printf '%08d\n' 0 > file.txt
  "$GIT" add file.txt
  "$GIT" commit -qm init
  start=$(now_ns)
  for ((i=1; i<=N; i++)); do
    printf '%08d\n' "$i" > file.txt
    "$GIT" commit -qam "c$i"
  done
  end=$(now_ns)
  count=$("$GIT" rev-list --count HEAD)
  test "$count" -eq $((N + 1))
  "$GIT" fsck --no-progress >/dev/null
  size=$(store_kib .git)
  record_result "git-$mode-cli" "$rep" "$N" "$((end - start))" "$count" "$size"
}

bench_jj() {
  local rep=$1
  local repo="$RUN_ROOT/jj-$rep" start end count size
  mkdir "$repo"
  cd "$repo"
  XDG_CONFIG_HOME="$RUN_ROOT/xdg" "$JJ" --config user.name=Agent --config user.email=agent@local git init >/dev/null
  XDG_CONFIG_HOME="$RUN_ROOT/xdg" "$JJ" config set --repo user.name Agent
  XDG_CONFIG_HOME="$RUN_ROOT/xdg" "$JJ" config set --repo user.email agent@local
  XDG_CONFIG_HOME="$RUN_ROOT/xdg" "$JJ" metaedit --update-author >/dev/null 2>&1 || true
  printf '%08d\n' 0 > file.txt
  XDG_CONFIG_HOME="$RUN_ROOT/xdg" "$JJ" commit -m init >/dev/null 2>&1
  start=$(now_ns)
  for ((i=1; i<=N; i++)); do
    printf '%08d\n' "$i" > file.txt
    XDG_CONFIG_HOME="$RUN_ROOT/xdg" "$JJ" commit -m "c$i" >/dev/null 2>&1
  done
  end=$(now_ns)
  count=$(XDG_CONFIG_HOME="$RUN_ROOT/xdg" "$JJ" log --no-graph -r 'ancestors(@) & ~root() & ~empty()' -T 'commit_id ++ "\n"' | wc -l)
  test "$count" -eq $((N + 1))
  "$GIT" -C .git fsck --no-progress >/dev/null
  size=$(store_kib .jj)
  record_result jj-cli "$rep" "$N" "$((end - start))" "$count" "$size"
}

bench_hg() {
  local rep=$1
  local repo="$RUN_ROOT/hg-$rep" start end count size
  mkdir "$repo"
  cd "$repo"
  "$HG" init
  printf '%08d\n' 0 > file.txt
  "$HG" add file.txt
  HGUSER='Agent <agent@local>' "$HG" commit -qm init
  start=$(now_ns)
  for ((i=1; i<=N; i++)); do
    printf '%08d\n' "$i" > file.txt
    HGUSER='Agent <agent@local>' "$HG" commit -qm "c$i"
  done
  end=$(now_ns)
  count=$("$HG" log -T '{rev}\n' | wc -l)
  test "$count" -eq $((N + 1))
  "$HG" verify -q
  size=$(store_kib .hg)
  record_result mercurial-cli "$rep" "$N" "$((end - start))" "$count" "$size"
}

bench_sl() {
  local rep=$1
  local repo="$RUN_ROOT/sl-$rep" start end count size
  mkdir "$repo"
  cd "$repo"
  "$SL" init >/dev/null
  "$SL" config --local ui.username 'Agent <agent@local>' >/dev/null
  printf '%08d\n' 0 > file.txt
  "$SL" add file.txt
  "$SL" commit -qm init
  start=$(now_ns)
  for ((i=1; i<=N; i++)); do
    printf '%08d\n' "$i" > file.txt
    "$SL" commit -qm "c$i"
  done
  end=$(now_ns)
  count=$("$SL" log -T '{rev}\n' | wc -l)
  test "$count" -eq $((N + 1))
  "$SL" verify >/dev/null
  size=$(store_kib .sl)
  record_result sapling-cli "$rep" "$N" "$((end - start))" "$count" "$size"
}

bench_fossil() {
  local rep=$1
  local store="$RUN_ROOT/fossil-$rep.fossil" repo="$RUN_ROOT/fossil-wc-$rep" start end count size
  USER=agent LOGNAME=agent "$FOSSIL" init -A agent "$store" >/dev/null
  mkdir "$repo"
  cd "$repo"
  USER=agent LOGNAME=agent "$FOSSIL" open "$store" >/dev/null
  printf '%08d\n' 0 > file.txt
  USER=agent LOGNAME=agent "$FOSSIL" add file.txt >/dev/null
  USER=agent LOGNAME=agent "$FOSSIL" commit --hash -m init --nosync --no-verify --no-warnings >/dev/null
  start=$(now_ns)
  for ((i=1; i<=N; i++)); do
    printf '%08d\n' "$i" > file.txt
    USER=agent LOGNAME=agent "$FOSSIL" commit --hash -m "c$i" --nosync --no-verify --no-warnings >/dev/null
  done
  end=$(now_ns)
  count=$(USER=agent LOGNAME=agent "$FOSSIL" sql -R "$store" "select count(*) from event where type='ci'")
  test "$count" -eq $((N + 2))
  test "$(USER=agent LOGNAME=agent "$FOSSIL" sql -R "$store" 'pragma integrity_check')" = "'ok'"
  size=$(store_kib "$store")
  record_result fossil-cli "$rep" "$N" "$((end - start))" "$count" "$size"
}

bench_pijul() {
  local rep=$1
  local repo="$RUN_ROOT/pijul-$rep" start end count size
  mkdir "$repo"
  cd "$repo"
  "$PIJUL" init >/dev/null
  printf '%08d\n' 0 > file.txt
  "$PIJUL" add file.txt >/dev/null
  "$PIJUL" record -a -m init --identity bench >/dev/null
  start=$(now_ns)
  for ((i=1; i<=N; i++)); do
    printf '%08d\n' "$i" > file.txt
    "$PIJUL" record -a -m "c$i" --identity bench >/dev/null
  done
  end=$(now_ns)
  count=$("$PIJUL" log --output-format json | jq 'length')
  test "$count" -eq $((N + 2))
  "$PIJUL" debug --sanakirja-only >/dev/null
  size=$(store_kib .pijul)
  record_result pijul-cli "$rep" "$N" "$((end - start))" "$count" "$size"
}

bench_perforce() {
  local rep=$1
  local client="bench$rep-$(basename "$RUN_ROOT")" repo="$RUN_ROOT/p4-wc-$rep" start end count size
  mkdir "$repo"
  export P4PORT=${P4PORT:-127.0.0.1:16677}
  export P4USER=${P4USER:-agent}
  export P4CLIENT="$client"
  export P4TICKETS=${P4TICKETS:-$BENCH_ROOT/runs/p4tickets}
  printf 'Client: %s\nOwner: agent\nRoot: %s\nOptions: noallwrite noclobber nocompress unlocked nomodtime normdir\nLineEnd: local\nView:\n\t//depot/%s/... //%s/...\n' "$client" "$repo" "$client" "$client" | "$P4" client -i >/dev/null
  cd "$repo"
  printf '%08d\n' 0 > file.txt
  "$P4" add file.txt >/dev/null
  "$P4" submit -d init >/dev/null
  start=$(now_ns)
  for ((i=1; i<=N; i++)); do
    "$P4" edit file.txt >/dev/null
    printf '%08d\n' "$i" > file.txt
    "$P4" submit -d "c$i" >/dev/null
  done
  end=$(now_ns)
  count=$("$P4" changes -s submitted "//depot/$client/..." | wc -l)
  test "$count" -eq $((N + 1))
  "$P4" verify -q "//depot/$client/..."
  size=$(store_kib "$repo")
  record_result perforce-server-cli "$rep" "$N" "$((end - start))" "$count" "$size"
}

# --- Newer / smaller systems (same one-file sequential workload) ---

bench_claw() {
  local rep=$1
  local repo="$RUN_ROOT/claw-$rep" start end count size
  mkdir "$repo"; cd "$repo"
  "$CLAW" init >/dev/null
  printf '%08d\n' 0 > file.txt
  "$CLAW" snapshot -m init >/dev/null
  start=$(now_ns)
  for ((i=1; i<=N; i++)); do
    printf '%08d\n' "$i" > file.txt
    "$CLAW" snapshot -m "c$i" >/dev/null
  done
  end=$(now_ns)
  count=$("$CLAW" log --limit 10000 --json | jq length)
  test "$count" -eq $((N + 1))
  "$CLAW" admin preflight >/dev/null
  size=$(store_kib .claw)
  record_result claw-cli "$rep" "$N" "$((end - start))" "$count" "$size"
}

bench_twigg() {
  local rep=$1
  local repo="$RUN_ROOT/twigg-$rep" start end size
  mkdir "$repo"; cd "$repo"
  "$TW" init >/dev/null
  printf '%08d\n' 0 > file.txt
  "$TW" commit init >/dev/null
  start=$(now_ns)
  for ((i=1; i<=N; i++)); do
    printf '%08d\n' "$i" > file.txt
    "$TW" commit "c$i" >/dev/null
  done
  end=$(now_ns)
  # Twigg's graph log is not reliably line-countable; trust the commit loop.
  size=$(store_kib .twigg 2>/dev/null || echo 0)
  record_result twigg-cli "$rep" "$N" "$((end - start))" "$N" "$size"
}

# mode: default (deferred store flush) | durable (--sync-data forces a flush)
bench_lore() {
  local mode=$1 rep=$2
  local repo="$RUN_ROOT/lore-$mode-$rep" name start end count size flag=""
  [[ "$mode" == durable ]] && flag="--sync-data"
  mkdir "$repo"; cd "$repo"
  name="lore-$mode-r$rep-$(basename "$repo")"
  "$LORE" repository create "lore://$LORE_GRPC/$name" >/dev/null
  printf '%08d\n' 0 > file.txt
  "$LORE" $flag stage file.txt >/dev/null
  "$LORE" $flag commit init >/dev/null
  start=$(now_ns)
  for ((i=1; i<=N; i++)); do
    printf '%08d\n' "$i" > file.txt
    "$LORE" $flag stage file.txt >/dev/null
    "$LORE" $flag commit "c$i" >/dev/null
  done
  end=$(now_ns)
  count=$("$LORE" history --oneline 5000 | wc -l)
  test "$count" -eq $((N + 1))
  size=$(store_kib .lore 2>/dev/null || echo 0)
  record_result "lore-$mode-cli" "$rep" "$N" "$((end - start))" "$count" "$size"
}

bench_oxen() {
  local rep=$1
  local repo="$RUN_ROOT/oxen-$rep" start end count size
  mkdir "$repo"; cd "$repo"
  "$OXEN" --config-dir "$OXEN_CONFIG" init >/dev/null 2>&1
  printf '%08d\n' 0 > file.txt
  "$OXEN" --config-dir "$OXEN_CONFIG" add file.txt >/dev/null
  "$OXEN" --config-dir "$OXEN_CONFIG" commit -m init >/dev/null
  start=$(now_ns)
  for ((i=1; i<=N; i++)); do
    printf '%08d\n' "$i" > file.txt
    "$OXEN" --config-dir "$OXEN_CONFIG" add file.txt >/dev/null
    "$OXEN" --config-dir "$OXEN_CONFIG" commit -m "c$i" >/dev/null
  done
  end=$(now_ns)
  count=$("$OXEN" --config-dir "$OXEN_CONFIG" log -n 1000 | grep -c '^commit ')
  test "$count" -eq $((N + 1))
  size=$(store_kib .oxen)
  record_result oxen-cli "$rep" "$N" "$((end - start))" "$count" "$size"
}

export SSH_AUTH_SOCK="$BENCH_ROOT/ssh-agent.sock"
export HOME="$BENCH_ROOT/pijul-home"
export XDG_CONFIG_HOME="$BENCH_ROOT/pijul-config"

# Lore needs its local server up even for local commits (repository create/push).
LORE_PID=""
if enabled lore-default || enabled lore-durable; then
  mkdir -p "$RUN_ROOT/lore-tmp"
  ( exec env TMPDIR="$RUN_ROOT/lore-tmp" RUST_LOG=warn "$LORESERVER" ) >"$RUN_ROOT/loreserver.log" 2>&1 &
  LORE_PID=$!
  trap '[[ -n "$LORE_PID" ]] && kill "$LORE_PID" 2>/dev/null; wait "$LORE_PID" 2>/dev/null || true' EXIT
  for _ in $(seq 1 50); do curl -fsS "http://$LORE_HTTP/health_check" >/dev/null 2>&1 && break; sleep 0.2; done
fi
if enabled oxen; then
  mkdir -p "$OXEN_CONFIG"
  "$OXEN" --config-dir "$OXEN_CONFIG" config --name Agent --email agent@local >/dev/null 2>&1 || true
fi

if enabled git-default; then for ((rep=1; rep<=REPS; rep++)); do bench_git "$rep" default; done; fi
if enabled git-durable; then for ((rep=1; rep<=REPS; rep++)); do bench_git "$rep" durable; done; fi
if enabled jj; then for ((rep=1; rep<=REPS; rep++)); do bench_jj "$rep"; done; fi
if enabled mercurial; then for ((rep=1; rep<=REPS; rep++)); do bench_hg "$rep"; done; fi
if enabled sapling; then for ((rep=1; rep<=REPS; rep++)); do bench_sl "$rep"; done; fi
if enabled fossil; then for ((rep=1; rep<=REPS; rep++)); do bench_fossil "$rep"; done; fi
if enabled pijul; then for ((rep=1; rep<=REPS; rep++)); do bench_pijul "$rep"; done; fi
if enabled perforce; then for ((rep=1; rep<=REPS; rep++)); do bench_perforce "$rep"; done; fi
if enabled claw; then for ((rep=1; rep<=REPS; rep++)); do bench_claw "$rep"; done; fi
if enabled twigg; then for ((rep=1; rep<=REPS; rep++)); do bench_twigg "$rep"; done; fi
if enabled lore-default; then for ((rep=1; rep<=REPS; rep++)); do bench_lore default "$rep"; done; fi
if enabled lore-durable; then for ((rep=1; rep<=REPS; rep++)); do bench_lore durable "$rep"; done; fi
if enabled oxen; then for ((rep=1; rep<=REPS; rep++)); do bench_oxen "$rep"; done; fi

printf 'results=%s\n' "$RESULTS"
