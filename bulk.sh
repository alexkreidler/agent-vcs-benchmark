#!/usr/bin/env bash
set -euo pipefail

BENCH_ROOT=${BENCH_ROOT:-/tmp/vcs-agent-bench}
RUN_ROOT="$BENCH_ROOT/runs/bulk-$(date +%Y%m%d-%H%M%S)"
N=${1:-1000}
REPS=${2:-3}
RESULTS="$RUN_ROOT/results.csv"

JJ="$BENCH_ROOT/tools/bin/jj"
HG="$BENCH_ROOT/tools/hg-venv/bin/hg"
SL="$BENCH_ROOT/tools/sapling/sl"
FOSSIL="$BENCH_ROOT/tools/fossil/fossil"
PIJUL="$BENCH_ROOT/tools/cargo-home/bin/pijul"

mkdir -p "$RUN_ROOT"
printf 'system,phase,rep,commits,elapsed_ns,commits_per_sec,verified_count,store_kib\n' > "$RESULTS"

now_ns() { date +%s%N; }
store_kib() { du -sk "$1" | awk '{print $1}'; }

record_result() {
  local system=$1 phase=$2 rep=$3 commits=$4 elapsed_ns=$5 verified=$6 size=$7 rate
  rate=$(awk -v n="$commits" -v ns="$elapsed_ns" 'BEGIN { printf "%.3f", n * 1000000000 / ns }')
  printf '%s,%s,%s,%s,%s,%s,%s,%s\n' "$system" "$phase" "$rep" "$commits" "$elapsed_ns" "$rate" "$verified" "$size" | tee -a "$RESULTS"
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
  ' "$N"
}

bench_rep() {
  local rep=$1
  local base="$RUN_ROOT/rep-$rep" start end count size source target work
  mkdir -p "$base"

  source="$base/git-source.git"
  git init --bare -q "$source"
  start=$(now_ns)
  git_stream | git -C "$source" fast-import --quiet
  end=$(now_ns)
  count=$(git -C "$source" rev-list --count main)
  test "$count" -eq "$N"
  git -C "$source" fsck --no-progress >/dev/null
  size=$(store_kib "$source")
  record_result git fast-import "$rep" "$N" "$((end - start))" "$count" "$size"

  target="$base/git-target-default.git"
  git init --bare -q "$target"
  start=$(now_ns)
  git -C "$source" push -q "$target" main:main
  end=$(now_ns)
  count=$(git -C "$target" rev-list --count main)
  test "$count" -eq "$N"
  git -C "$target" fsck --no-progress >/dev/null
  size=$(store_kib "$target")
  record_result git receive-pack "$rep" "$N" "$((end - start))" "$count" "$size"

  target="$base/git-target-durable.git"
  git init --bare -q "$target"
  git -C "$target" config core.fsync all
  git -C "$target" config core.fsyncMethod fsync
  start=$(now_ns)
  git -C "$source" push -q "$target" main:main
  end=$(now_ns)
  count=$(git -C "$target" rev-list --count main)
  test "$count" -eq "$N"
  git -C "$target" fsck --no-progress >/dev/null
  size=$(store_kib "$target")
  record_result git receive-pack-fsync "$rep" "$N" "$((end - start))" "$count" "$size"

  work="$base/jj"
  mkdir "$work"
  start=$(now_ns)
  XDG_CONFIG_HOME="$base/xdg" "$JJ" --config user.name=Agent --config user.email=agent@local git init --git-repo "$source" "$work" >/dev/null 2>&1
  end=$(now_ns)
  count=$(XDG_CONFIG_HOME="$base/xdg" "$JJ" -R "$work" log --no-graph -r 'all() & ~root() & ~empty()' -T 'commit_id ++ "\n"' | wc -l)
  test "$count" -eq "$N"
  size=$(store_kib "$work/.jj")
  record_result jj git-import "$rep" "$N" "$((end - start))" "$count" "$size"

  target="$base/fossil-source.fossil"
  USER=agent LOGNAME=agent "$FOSSIL" init -A agent "$target" >/dev/null
  USER=agent LOGNAME=agent "$FOSSIL" clone "file://$target" "$base/fossil-target.fossil" >/dev/null
  start=$(now_ns)
  git -C "$source" fast-export --all | USER=agent LOGNAME=agent "$FOSSIL" import --git --incremental "$target" >/dev/null
  end=$(now_ns)
  count=$(USER=agent LOGNAME=agent "$FOSSIL" sql -R "$target" "select count(*) from event where type='ci'")
  test "$count" -eq $((N + 2))
  size=$(store_kib "$target")
  record_result fossil git-import "$rep" "$N" "$((end - start))" "$count" "$size"
  work="$base/fossil-wc"
  mkdir "$work"
  cd "$work"
  USER=agent LOGNAME=agent "$FOSSIL" open "$target" >/dev/null
  start=$(now_ns)
  USER=agent LOGNAME=agent "$FOSSIL" push "file://$base/fossil-target.fossil" >/dev/null
  end=$(now_ns)
  count=$(USER=agent LOGNAME=agent "$FOSSIL" sql -R "$base/fossil-target.fossil" "select count(*) from event where type='ci'")
  test "$count" -eq $((N + 2))
  size=$(store_kib "$base/fossil-target.fossil")
  record_result fossil sync "$rep" "$N" "$((end - start))" "$count" "$size"

  if [[ ${SKIP_PIJUL:-0} != 1 ]]; then
    work="$base/git-worktree"
    git clone -q -b main "$source" "$work"
    target="$base/pijul-source"
    start=$(now_ns)
    "$PIJUL" git "$work" "$target" >/dev/null 2>&1
    end=$(now_ns)
    count=$(cd "$target" && "$PIJUL" log --output-format json | jq length)
    test "$count" -eq "$N"
    size=$(store_kib "$target/.pijul")
    record_result pijul git-import "$rep" "$N" "$((end - start))" "$count" "$size"
    work="$base/pijul-target"
    "$PIJUL" init "$work" >/dev/null
    start=$(now_ns)
    (cd "$target" && "$PIJUL" push -a --to-channel main "$work" >/dev/null)
    end=$(now_ns)
    count=$(cd "$work" && "$PIJUL" log --output-format json | jq length)
    test "$count" -eq "$N"
    size=$(store_kib "$work/.pijul")
    record_result pijul push "$rep" "$N" "$((end - start))" "$count" "$size"
  fi

  source="$base/hg-source"
  mkdir "$source"
  "$HG" init "$source"
  start=$(now_ns)
  (cd "$source" && "$HG" debugbuilddag -o "+$N")
  end=$(now_ns)
  count=$("$HG" -R "$source" log -T '{rev}\n' | wc -l)
  test "$count" -eq "$N"
  "$HG" -R "$source" verify -q
  size=$(store_kib "$source/.hg")
  record_result mercurial debugbuilddag "$rep" "$N" "$((end - start))" "$count" "$size"
  target="$base/hg-target"
  "$HG" init "$target"
  start=$(now_ns)
  "$HG" -R "$source" push -q "$target"
  end=$(now_ns)
  count=$("$HG" -R "$target" log -T '{rev}\n' | wc -l)
  test "$count" -eq "$N"
  "$HG" -R "$target" verify -q
  size=$(store_kib "$target/.hg")
  record_result mercurial push "$rep" "$N" "$((end - start))" "$count" "$size"

  source="$base/sl-source"
  mkdir "$source"
  (cd "$source" && "$SL" --config init.prefer-git=false init)
  "$SL" -R "$source" config --local ui.username 'Agent <agent@local>' >/dev/null
  start=$(now_ns)
  (cd "$source" && "$SL" debugbuilddag -o "+$N")
  end=$(now_ns)
  count=$("$SL" -R "$source" log --hidden -r 'all()' -T '{rev}\n' | wc -l)
  test "$count" -eq "$N"
  size=$(store_kib "$source/.sl")
  record_result sapling debugbuilddag "$rep" "$N" "$((end - start))" "$count" "$size"
  target="$base/sl-target"
  mkdir "$target"
  (cd "$target" && "$SL" --config init.prefer-git=false init)
  "$SL" -R "$target" config --local ui.username 'Agent <agent@local>' >/dev/null
  (cd "$source" && "$SL" --hidden bookmark -f -r tip bench >/dev/null)
  start=$(now_ns)
  (cd "$source" && "$SL" --hidden push --to bench --create -r bench "$target" >/dev/null)
  end=$(now_ns)
  count=$("$SL" -R "$target" log --hidden -r 'all()' -T '{rev}\n' | wc -l)
  test "$count" -eq "$N"
  size=$(store_kib "$target/.sl")
  record_result sapling push "$rep" "$N" "$((end - start))" "$count" "$size"
}

export SSH_AUTH_SOCK="$BENCH_ROOT/ssh-agent.sock"
export HOME="$BENCH_ROOT/pijul-home"
export XDG_CONFIG_HOME="$BENCH_ROOT/pijul-config"

for ((rep=1; rep<=REPS; rep++)); do bench_rep "$rep"; done
printf 'results=%s\n' "$RESULTS"
