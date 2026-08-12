#!/usr/bin/env bash
# Network / server-ingestion benchmark for every system that ships its own
# server: Forgejo (HTTP push, full forge path), Lore (loreserver push), Claw
# (gRPC sync daemon, unauth + auth + 16-agent concurrent), and Soft Serve
# (Git-over-SSH host).
#
# Each system ingests a fresh linear history into a fresh server-side target.
# Claw's importer rejects packed Git objects, so its source is exploded to loose
# objects first (see build_git_source / build_loose_source).
set -euo pipefail

BENCH_ROOT=${BENCH_ROOT:-/tmp/vcs-agent-bench}
RUN_ROOT="$BENCH_ROOT/runs/followup-net-$(date +%Y%m%d-%H%M%S)"
SYSTEMS=${SYSTEMS:-forgejo,lore-server,claw-grpc,claw-concurrent,soft-serve}
# Optional overrides: git/claw/soft-serve/forgejo histories default to 5,000,
# Lore to 1,000, per the recorded run. Pass N to shrink all of them for a smoke
# test.
N=${1:-}
REPS=${2:-3}
RESULTS="$RUN_ROOT/results.csv"

CLAW="$BENCH_ROOT/tools/claw/claw-x86_64-unknown-linux-gnu/claw"
LORE="$BENCH_ROOT/tools/lore/lore"
LORESERVER="$BENCH_ROOT/tools/lore/loreserver"
SOFT="$BENCH_ROOT/tools/soft-serve/soft-serve_0.12.2_Linux_x86_64/soft"
FORGEJO="$BENCH_ROOT/tools/bin/forgejo"
FORGEJO_INI="$(cd "$(dirname "$0")" && pwd)/forgejo.ini"
LORE_GRPC=${LORE_GRPC:-127.0.0.1:41337}
LORE_HTTP=${LORE_HTTP:-127.0.0.1:41339}

mkdir -p "$RUN_ROOT"
printf 'system,phase,rep,commits,elapsed_ns,commits_per_sec,verified_count\n' > "$RESULTS"
now_ns() { date +%s%N; }
enabled() { [[ ",$SYSTEMS," == *",$1,"* ]]; }

record_result() {
  local system=$1 phase=$2 rep=$3 commits=$4 elapsed_ns=$5 verified=$6 rate
  rate=$(awk -v n="$commits" -v ns="$elapsed_ns" 'BEGIN { printf "%.3f", n * 1000000000 / ns }')
  printf '%s,%s,%s,%s,%s,%s,%s\n' "$system" "$phase" "$rep" "$commits" "$elapsed_ns" "$rate" "$verified" | tee -a "$RESULTS"
}

git_stream() {
  perl -e '
    $n = shift;
    print "feature done\n";
    for ($i = 1; $i <= $n; $i++) {
      $body = sprintf("%08d\n", $i);
      print "commit refs/heads/main\nmark :$i\nauthor Agent <agent\@local> $i +0000\ncommitter Agent <agent\@local> $i +0000\ndata 1\nx\n";
      print "from :" . ($i - 1) . "\n" if $i > 1;
      print "M 100644 inline file.txt\ndata " . length($body) . "\n$body";
    }
    print "done\n";
  ' "$1"
}

# Packed bare source of $1 commits.
build_git_source() {
  local n=$1 src="$RUN_ROOT/git-source.git"
  [[ -d "$src" ]] && { printf '%s\n' "$src"; return; }
  git init --bare -q "$src"
  git_stream "$n" | git -C "$src" fast-import --quiet
  test "$(git -C "$src" rev-list --count main)" -eq "$n"
  printf '%s\n' "$src"
}

# Loose-object bare source (Claw's importer cannot read packs).
build_loose_source() {
  local n=$1 packed loose head
  packed=$(build_git_source "$n")
  loose="$RUN_ROOT/git-loose-source.git"
  [[ -d "$loose" ]] && { printf '%s\n' "$loose"; return; }
  git init --bare -q "$loose"
  git -C "$packed" pack-objects --stdout --all | git -C "$loose" unpack-objects -r >/dev/null
  head=$(git -C "$packed" rev-parse main)
  git -C "$loose" update-ref refs/heads/main "$head"
  test "$(git -C "$loose" rev-list --count main)" -eq "$n"
  printf '%s\n' "$loose"
}

# --- Forgejo: push an N-commit history into fresh private repos over HTTP,
#     through the full forge path (auth, hooks, SQLite) ---
bench_forgejo() {
  local n=${1:-5000} reps=${2:-3} src rep name start end count target
  src=$(build_git_source "$n")
  local froot="$BENCH_ROOT/forgejo" port=30077 base="http://127.0.0.1:30077"
  if test -e "$froot"; then find "$froot" -depth -delete; fi
  mkdir -p "$froot/data" "$froot/repos" "$froot/log" "$froot/custom"
  "$FORGEJO" --work-path "$froot" --custom-path "$froot/custom" --config "$FORGEJO_INI" migrate >/dev/null 2>&1
  "$FORGEJO" --work-path "$froot" --custom-path "$froot/custom" --config "$FORGEJO_INI" \
    admin user create --username agent --password 'BenchPass1!' --email agent@local --admin --must-change-password=false >/dev/null 2>&1
  ( "$FORGEJO" --work-path "$froot" --custom-path "$froot/custom" --config "$FORGEJO_INI" web ) >"$RUN_ROOT/forgejo-web.log" 2>&1 &
  local wpid=$!
  trap 'kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null || true' RETURN
  for _ in $(seq 1 50); do curl -fsS "$base/api/v1/version" >/dev/null 2>&1 && break; sleep 0.2; done
  for ((rep=1; rep<=reps; rep++)); do
    name="bench$rep"
    curl -fsS -u 'agent:BenchPass1!' -H 'Content-Type: application/json' -d "{\"name\":\"$name\",\"private\":true}" "$base/api/v1/user/repos" >/dev/null
    start=$(now_ns)
    git -C "$src" push -q "http://agent:BenchPass1!@127.0.0.1:$port/agent/$name.git" main:main
    end=$(now_ns)
    target="$froot/repos/agent/$name.git"
    count=$(git -C "$target" rev-list --count main); test "$count" -eq "$n"
    git -C "$target" fsck --no-progress >/dev/null
    record_result forgejo http-push "$rep" "$n" "$((end - start))" "$count"
  done
  kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null || true; trap - RETURN
}

# --- Lore: create a 1,000-revision repo locally, then time the server push ---
bench_lore_server() {
  local n=${1:-1000} reps=${2:-3} rep repo name start end count verify
  mkdir -p "$RUN_ROOT/lore-tmp"
  ( exec env TMPDIR="$RUN_ROOT/lore-tmp" RUST_LOG=warn "$LORESERVER" ) >"$RUN_ROOT/loreserver.log" 2>&1 &
  local pid=$!
  trap 'kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true' RETURN
  for _ in $(seq 1 50); do
    curl -fsS "http://$LORE_HTTP/health_check" >/dev/null 2>&1 && break; sleep 0.2
  done
  for ((rep=1; rep<=reps; rep++)); do
    repo="$RUN_ROOT/lore-bulk-r$rep"; mkdir "$repo"; cd "$repo"
    name="lore-bulk-r$rep-$(basename "$repo")"
    "$LORE" repository create "lore://$LORE_GRPC/$name" >/dev/null
    for ((i=1; i<=n; i++)); do
      printf '%016d\n' "$i" > tracked.txt
      "$LORE" stage tracked.txt >/dev/null
      "$LORE" commit "c$i" >/dev/null
    done
    test "$("$LORE" history --oneline 5000 | wc -l)" -eq "$n"
    start=$(now_ns)
    "$LORE" push >/dev/null
    end=$(now_ns)
    verify="$RUN_ROOT/lore-verify-r$rep"
    "$LORE" clone "lore://$LORE_GRPC/$name" "$verify" >/dev/null
    count=$("$LORE" --repository "$verify" history --oneline 5000 | wc -l)
    test "$count" -eq "$n"
    record_result lore server-push "$rep" "$n" "$((end - start))" "$count"
  done
}

# --- Claw: git-import a loose source, then time the gRPC daemon push ---
bench_claw_grpc() {
  local n=${1:-5000} reps=${2:-3} loose rep client server start end count port health
  loose=$(build_loose_source "$n")
  for ((rep=1; rep<=reps; rep++)); do
    port=$((50100 + rep)); health=$((50110 + rep))
    client="$RUN_ROOT/claw-client-r$rep"; mkdir "$client"; cd "$client"
    "$CLAW" init >/dev/null
    "$CLAW" git-import --git-dir "$loose" --git-ref refs/heads/main --ref-name heads/main >/dev/null
    test "$("$CLAW" log --limit 10000 --json | jq length)" -eq "$n"
    server="$RUN_ROOT/claw-server-r$rep"; mkdir "$server"; cd "$server"
    "$CLAW" init >/dev/null
    "$CLAW" daemon --listen "127.0.0.1:$port" --health-listen "127.0.0.1:$health" >"$server/daemon.log" 2>&1 &
    local dpid=$!
    sleep 0.5
    cd "$client"
    "$CLAW" remote add origin "http://127.0.0.1:$port" >/dev/null
    start=$(now_ns)
    "$CLAW" sync push --remote origin --ref-name heads/main >/dev/null
    end=$(now_ns)
    count=$(cd "$server" && "$CLAW" log --limit 10000 --json | jq length)
    test "$count" -eq "$n"
    kill "$dpid" 2>/dev/null; wait "$dpid" 2>/dev/null || true
    record_result claw server-push "$rep" "$n" "$((end - start))" "$count"
  done
}

# --- Claw: 16 agents each push 20 revisions on their own branch, concurrently,
#     through one authenticated daemon (measures contention) ---
bench_claw_concurrent() {
  local agents=${1:-16} per=${2:-20} reps=${3:-3} rep base client server start end count refs total port health
  total=$((agents * per + 1))
  local auth_home="$RUN_ROOT/claw-auth-home"; mkdir -p "$auth_home"
  HOME="$auth_home" "$CLAW" auth token set bench-secret --profile bench >/dev/null
  for ((rep=1; rep<=reps; rep++)); do
    port=$((50130 + rep)); health=$((50140 + rep))
    base="$RUN_ROOT/cc-r$rep/base"; mkdir -p "$base"; cd "$base"
    HOME="$auth_home" "$CLAW" init >/dev/null
    printf '%016d\n' 0 > tracked.txt
    HOME="$auth_home" "$CLAW" snapshot -m initial >/dev/null
    for ((a=1; a<=agents; a++)); do
      client="$RUN_ROOT/cc-r$rep/client-$a"
      cp -a "$base" "$client"; cd "$client"
      HOME="$auth_home" "$CLAW" branch create "agent-$a" >/dev/null
      HOME="$auth_home" "$CLAW" checkout "agent-$a" >/dev/null
      for ((i=1; i<=per; i++)); do
        printf '%08d-%08d\n' "$a" "$i" > tracked.txt
        HOME="$auth_home" "$CLAW" snapshot -m "agent-$a-c$i" >/dev/null
      done
      HOME="$auth_home" "$CLAW" remote add origin "http://127.0.0.1:$port" --token-profile bench >/dev/null
    done
    server="$RUN_ROOT/cc-r$rep/server"; mkdir "$server"; cd "$server"
    HOME="$auth_home" "$CLAW" init >/dev/null
    HOME="$auth_home" "$CLAW" daemon --listen "127.0.0.1:$port" --health-listen "127.0.0.1:$health" \
      --auth-token bench-secret >"$server/daemon.log" 2>&1 &
    local dpid=$!
    trap 'kill "$dpid" 2>/dev/null; wait "$dpid" 2>/dev/null || true' RETURN
    sleep 0.5
    start=$(now_ns)
    local pids=""
    for ((a=1; a<=agents; a++)); do
      ( cd "$RUN_ROOT/cc-r$rep/client-$a"
        HOME="$auth_home" "$CLAW" sync push --remote origin --ref-name "heads/agent-$a" >/dev/null ) &
      pids="$pids $!"
    done
    for p in $pids; do wait "$p"; done
    end=$(now_ns)
    count=$(cd "$server" && HOME="$auth_home" "$CLAW" log --all --limit 10000 --json | jq length)
    refs=$(find "$server/.claw/refs/heads" -type f | wc -l)
    test "$refs" -eq "$agents"
    test "$count" -eq "$total"
    kill "$dpid" 2>/dev/null; wait "$dpid" 2>/dev/null || true
    trap - RETURN
    record_result claw concurrent-auth "$rep" "$total" "$((end - start))" "$count"
  done
}

# --- Soft Serve: push a 5,000-commit Git history over authenticated SSH ---
bench_soft_serve() {
  local n=${1:-5000} reps=${2:-3} src rep start end count verify
  src=$(build_git_source "$n")
  local sroot="$RUN_ROOT/soft"; mkdir -p "$sroot"
  ssh-keygen -q -t ed25519 -N '' -f "$sroot/id_ed25519"
  ( exec env SOFT_SERVE_DATA_PATH="$sroot/data" \
      SOFT_SERVE_INITIAL_ADMIN_KEYS="$(tr -d '\n' < "$sroot/id_ed25519.pub")" \
      SOFT_SERVE_DEFAULT_REPO=bench1 "$SOFT" serve ) >"$sroot/soft.log" 2>&1 &
  local pid=$!
  trap 'kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true' RETURN
  local sshopt="-i $sroot/id_ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
  for _ in $(seq 1 30); do
    ssh $sshopt -p 23231 localhost repo list >/dev/null 2>&1 && break; sleep 0.2
  done
  for ((rep=1; rep<=reps; rep++)); do
    ssh $sshopt -p 23231 localhost repo create "bench$rep" >/dev/null 2>&1 || true
  done
  export GIT_SSH_COMMAND="ssh $sshopt"
  for ((rep=1; rep<=reps; rep++)); do
    start=$(now_ns)
    git -C "$src" push -q "ssh://localhost:23231/bench$rep.git" main:main
    end=$(now_ns)
    verify="$RUN_ROOT/soft-verify-r$rep.git"
    git clone -q --bare "ssh://localhost:23231/bench$rep.git" "$verify"
    count=$(git -C "$verify" rev-list --count main)
    test "$count" -eq "$n"
    git -C "$verify" fsck --no-progress >/dev/null
    record_result soft-serve ssh-push "$rep" "$n" "$((end - start))" "$count"
  done
}

if enabled forgejo;         then bench_forgejo "${N:-5000}" "$REPS"; fi
if enabled lore-server;     then bench_lore_server "${N:-1000}" "$REPS"; fi
if enabled claw-grpc;       then bench_claw_grpc "${N:-5000}" "$REPS"; fi
if enabled claw-concurrent; then bench_claw_concurrent 16 20 "$REPS"; fi
if enabled soft-serve;      then bench_soft_serve "${N:-5000}" "$REPS"; fi

printf 'results=%s\n' "$RESULTS"
