#!/bin/bash
# shared/repo-health-monitor.sh
# Monitor repository health metrics (git size, warning on large repos)

# Determine shared library directory
if [ -n "$HOOKS_DIR" ]; then
  SHARED_DIR="$HOOKS_DIR/shared"
else
  SHARED_DIR="$(dirname "$0")"
fi

source "$SHARED_DIR/logger.sh"

HOOK_NAME="repo-health"
GIT_SIZE_WARNING_MB="${GIT_SIZE_WARNING_MB:-100}"  # Warn if .git > 100MB
GIT_SIZE_CRITICAL_MB="${GIT_SIZE_CRITICAL_MB:-500}"  # Warn urgently if .git > 500MB
COMMIT_COUNT_WARNING="${COMMIT_COUNT_WARNING:-10000}"  # Warn if commit count > 10000

# Get repository size
get_repo_size() {
  local git_dir="${1:-.git}"

  if [ ! -d "$git_dir" ]; then
    echo "0"
    return 0
  fi

  # Get size in bytes
  du -sb "$git_dir" 2>/dev/null | awk '{print $1}'
}

# Convert bytes to MB
bytes_to_mb() {
  local bytes="${1:-0}"
  if [ -z "$bytes" ] || [ "$bytes" = "0" ]; then
    echo "0"
  else
    echo $(( bytes / 1048576 ))
  fi
}

# Get commit count
get_commit_count() {
  git rev-list --count HEAD 2>/dev/null || echo "0"
}

# Check if squash merge would help
suggest_squash_merge() {
  local repo_size_mb="$1"
  local commit_count="$2"

  local avg_size=$((repo_size_mb / (commit_count > 0 ? commit_count : 1)))

  # Suggest if average commit size > 1MB or total > threshold
  if [ "$avg_size" -gt 1 ] || [ "$repo_size_mb" -gt 200 ]; then
    return 0  # True: should suggest
  fi

  return 1  # False: no need to suggest
}

# Monitor .git directory size
monitor_git_size() {
  log_debug "[$HOOK_NAME] Checking repository size"

  local git_size_bytes=$(get_repo_size ".git")
  local git_size_mb=$(bytes_to_mb "$git_size_bytes")
  local commit_count=$(get_commit_count)

  log_debug "[$HOOK_NAME] Repository metrics: .git=$git_size_mb MB, commits=$commit_count"

  # Critical size warning
  if [ "$git_size_mb" -gt "$GIT_SIZE_CRITICAL_MB" ]; then
    log_warn "[$HOOK_NAME] ⚠️  CRITICAL: Repository .git directory is ${git_size_mb}MB (threshold: ${GIT_SIZE_CRITICAL_MB}MB)"
    log_warn "[$HOOK_NAME] This may cause performance issues and slow down cloning"

    if suggest_squash_merge "$git_size_mb" "$commit_count"; then
      log_warn "[$HOOK_NAME] Consider a squash merge to reduce repository size"
      log_warn "[$HOOK_NAME] See: REPO_HEALTH_GUIDE.md for details"
    fi

    return 1
  fi

  # Warning size threshold
  if [ "$git_size_mb" -gt "$GIT_SIZE_WARNING_MB" ]; then
    log_warn "[$HOOK_NAME] ℹ️  Repository .git directory is ${git_size_mb}MB (warning threshold: ${GIT_SIZE_WARNING_MB}MB)"

    if suggest_squash_merge "$git_size_mb" "$commit_count"; then
      log_warn "[$HOOK_NAME] Suggestion: Consider a squash merge to optimize repository size"
      log_warn "[$HOOK_NAME] Commands:"
      log_warn "[$HOOK_NAME]   git rebase -i --root  # Interactive rebase to squash commits"
      log_warn "[$HOOK_NAME]   git gc --aggressive   # Garbage collect and optimize"
    fi

    return 0  # Warning, not error
  fi

  # Commit count warning
  if [ "$commit_count" -gt "$COMMIT_COUNT_WARNING" ]; then
    log_debug "[$HOOK_NAME] High commit count: $commit_count (warning threshold: $COMMIT_COUNT_WARNING)"
  fi

  log_debug "[$HOOK_NAME] Repository health: normal"
  return 0
}

# Get detailed repository breakdown
get_repo_breakdown() {
  local git_dir="${1:-.git}"

  if [ ! -d "$git_dir" ]; then
    return 1
  fi

  echo "Repository health breakdown:"
  echo ""
  echo "Total .git size:"
  du -sh "$git_dir" 2>/dev/null

  echo ""
  echo "Breakdown by component:"
  echo "Objects (commits, trees, blobs):"
  du -sh "$git_dir/objects" 2>/dev/null

  echo "References (branches, tags):"
  du -sh "$git_dir/refs" 2>/dev/null

  echo "Logs:"
  du -sh "$git_dir/logs" 2>/dev/null

  echo ""
  echo "Largest files in objects:"
  find "$git_dir/objects" -type f -print0 2>/dev/null | xargs -0 du -b | sort -rn | head -5 | while read -r size file; do
    echo "  $(bytes_to_mb "$size") MB: $(basename "$file")"
  done

  echo ""
  echo "Commit statistics:"
  echo "  Total commits: $(get_commit_count)"
  echo "  Commits in last week: $(git rev-list --count --since='7 days ago' HEAD 2>/dev/null)"
  echo "  Commits in last month: $(git rev-list --count --since='30 days ago' HEAD 2>/dev/null)"
}

# Show repository optimization guide
show_repo_optimization_guide() {
  cat << 'EOF'
╔════════════════════════════════════════════════════════════════╗
║         Quality Gates: Repository Health & Optimization        ║
╚════════════════════════════════════════════════════════════════╝

REPOSITORY SIZE LIMITS:

  • Normal:   < 100 MB   ✓ No action needed
  • Warning: 100-500 MB  ⚠️  Consider optimization
  • Critical: > 500 MB   🚨 Action required

WHY REPOSITORY SIZE MATTERS:

  ✗ Large repositories:
    - Slower git clone (takes longer)
    - Slower git operations (push, pull, status)
    - Larger disk usage on developer machines
    - Increased network bandwidth
    - Difficult to archive and backup

  ✓ Optimized repositories:
    - Fast git operations
    - Small download size
    - Easy to maintain
    - Better for continuous integration

OPTIMIZATION TECHNIQUES:

1. SQUASH MERGE (Recommended for feature branches)
   When merging a feature branch with many commits:

   git checkout main
   git merge --squash feature-branch
   git commit -m "feat: add feature"
   git push origin main

   This combines all feature commits into one on main,
   keeping history clean while maintaining branch history.

2. INTERACTIVE REBASE (For local cleanup)
   For uncommitted local branches:

   git rebase -i --root
   # Mark commits to squash with 's' instead of 'pick'
   # This combines commits into one

3. GARBAGE COLLECTION (Periodic optimization)
   Compact and optimize repository:

   git gc --aggressive

   This reorganizes objects and removes unreachable commits.

4. FILTER-BRANCH (Remove large files from history)
   Remove accidentally-committed large files:

   git filter-branch --tree-filter 'rm -f <large-file>' HEAD

   WARNING: This rewrites history. Coordinate with team!

5. SHALLOW CLONE (For testing/CI)
   Clone only recent history:

   git clone --depth 1 <url>  # Only last commit
   git clone --depth 10 <url> # Last 10 commits

MONITORING & PREVENTION:

  • Check size regularly:
    du -sh .git

  • Monitor commit growth:
    git rev-list --count HEAD

  • Find large commits:
    git rev-list --all --objects | sort -k2 | tail -10

  • Find large files:
    git rev-list --all | while read commit; do
      git ls-tree -r $commit | awk '{print $3, $4}' | sort -k2
    done | uniq | sort -rn -k2 | head -20

BEST PRACTICES:

  ✓ Use squash merge for feature branches
  ✓ Run git gc --aggressive monthly
  ✓ Monitor repository size in CI/CD
  ✓ Encourage developers to clean up local branches
  ✓ Use shallow clones for CI pipelines (--depth 1)
  ✓ Archive old branches to separate repos
  ✓ Use .gitignore to prevent large files
  ✓ Consider splitting large monorepos

EMERGENCY: CRITICAL SIZE

  If .git > 500 MB:

  1. Alert team: New clones will be slow
  2. Run: git gc --aggressive
  3. Coordinate: Plan squash merge of old branches
  4. Archive: Move old branches to separate repo
  5. Communicate: New developers should use --depth 1

EOF
}

# Check if branch has too many unpushed commits
check_unpushed_commits() {
  local current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

  if [ -z "$current_branch" ] || [ "$current_branch" = "HEAD" ]; then
    return 0
  fi

  local unpushed=$(git rev-list --count @{u}..HEAD 2>/dev/null || echo "0")

  if [ "$unpushed" -gt 50 ]; then
    log_warn "[$HOOK_NAME] You have $unpushed unpushed commits on $current_branch"
    log_warn "[$HOOK_NAME] Consider pushing more frequently to avoid large accumulation"
  fi
}

# Main function: monitor repository health
monitor_repo_health() {
  log_debug "[$HOOK_NAME] Checking repository health"

  # Monitor git size
  if ! monitor_git_size; then
    log_error "[$HOOK_NAME] Repository size critical - contact repository maintainer"
  fi

  # Check unpushed commits
  check_unpushed_commits
}

# Detailed health report
show_health_report() {
  echo ""
  get_repo_breakdown
  echo ""
}
