#!/usr/bin/env bash
#
# KARIMO Cleanup Library (v9.10.1)
#
# Extracted cleanup functions for testability.
# Sourced by pm.md and doctor.md for consistent cleanup behavior.
#
# Usage:
#   source .karimo/scripts/lib/cleanup.sh
#   cleanup_task_worktree "my-prd" "1a"
#   cleanup_wave_tasks "1"
#   cleanup_orphaned_worktrees "my-prd"

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# cleanup_task_worktree
#
# Clean up a single task's worktree and branches after PR merge.
#
# Arguments:
#   $1 - prd_slug: The PRD slug
#   $2 - task_id: The task ID (e.g., "1a", "2b")
#
# Environment:
#   prd_path - Path to PRD directory (optional, derived from prd_slug if not set)
# ─────────────────────────────────────────────────────────────────────────────
cleanup_task_worktree() {
  local prd_slug="$1"
  local task_id="$2"
  local prd_path="${prd_path:-.karimo/prds/${prd_slug}}"
  local status_file="${prd_path}/status.json"

  local worktree_path=".karimo/.worktrees/${prd_slug}/${task_id}"
  local branch_name="worktree/${prd_slug}-${task_id}"

  echo "Cleaning up task ${task_id}..."

  # Remove worktree directory
  if [ -d "$worktree_path" ]; then
    if git worktree remove "$worktree_path" --force 2>/dev/null; then
      echo "  ✓ Worktree removed: $worktree_path"
    else
      # Fallback: remove directory if git worktree fails
      rm -rf "$worktree_path" 2>/dev/null
      echo "  ✓ Worktree directory removed (fallback)"
    fi
  fi

  # Prune stale references
  git worktree prune 2>/dev/null || true

  # Delete local branch
  if git show-ref --verify --quiet "refs/heads/$branch_name" 2>/dev/null; then
    git branch -D "$branch_name" 2>/dev/null && echo "  ✓ Local branch deleted: $branch_name"
  fi

  # Delete remote branch
  if git ls-remote --heads origin "$branch_name" 2>/dev/null | grep -q "$branch_name"; then
    git push origin --delete "$branch_name" 2>/dev/null && echo "  ✓ Remote branch deleted: $branch_name"
  fi

  # Untrack from active_worktrees if status.json exists
  if [ -f "$status_file" ]; then
    jq --arg tid "$task_id" \
      '.active_worktrees = ((.active_worktrees // []) | map(select(.task_id != $tid)))' \
      "$status_file" > "${status_file}.tmp" && mv "${status_file}.tmp" "$status_file"
  fi

  # Remove PRD worktree parent if empty
  rmdir ".karimo/.worktrees/${prd_slug}" 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# cleanup_wave_tasks
#
# Clean up all task worktrees for a completed wave.
# Only cleans tasks that are marked as done/merged.
#
# Arguments:
#   $1 - wave_number: The wave number to clean
#
# Environment:
#   prd_slug - PRD slug (required)
#   status_file - Path to status.json (required)
# ─────────────────────────────────────────────────────────────────────────────
cleanup_wave_tasks() {
  local wave_number="$1"

  if [ -z "${prd_slug:-}" ] || [ -z "${status_file:-}" ]; then
    echo "ERROR: prd_slug and status_file must be set" >&2
    return 1
  fi

  local wave_tasks
  wave_tasks=$(jq -r --arg wave "$wave_number" \
    '.tasks | to_entries[] | select(.value.wave == ($wave | tonumber)) | .key' \
    "$status_file" 2>/dev/null || true)

  if [ -z "$wave_tasks" ]; then
    echo "  No tasks found for wave $wave_number"
    return 0
  fi

  echo "Cleaning up wave $wave_number worktrees..."
  local cleaned_count=0

  for task_id in $wave_tasks; do
    # Only cleanup tasks that are done (PR merged)
    local task_status
    task_status=$(jq -r --arg tid "$task_id" '.tasks[$tid].status // empty' "$status_file" 2>/dev/null || true)
    if [ "$task_status" = "done" ] || [ "$task_status" = "merged" ]; then
      cleanup_task_worktree "$prd_slug" "$task_id"
      cleaned_count=$((cleaned_count + 1))
    fi
  done

  echo "  ✓ Cleaned $cleaned_count task worktrees for wave $wave_number"
}

# ─────────────────────────────────────────────────────────────────────────────
# cleanup_orphaned_worktrees
#
# Clean up orphaned worktrees from prior runs.
# Runs on PM startup to catch worktrees missed due to crashes/interruptions.
#
# Arguments:
#   $1 - prd_slug: The PRD slug
#
# Environment:
#   prd_path - Path to PRD directory (optional, derived from prd_slug if not set)
# ─────────────────────────────────────────────────────────────────────────────
cleanup_orphaned_worktrees() {
  local prd_slug="$1"
  local prd_path="${prd_path:-.karimo/prds/${prd_slug}}"
  local status_file="${prd_path}/status.json"

  echo "Checking for orphaned worktrees..."

  local cleaned_count=0

  # Walk git worktree list for this PRD
  while IFS= read -r line; do
    [[ "$line" =~ ^worktree ]] || continue
    local wt_path
    wt_path=$(echo "$line" | sed 's/^worktree //')

    # Only process worktrees for this PRD
    [[ "$wt_path" == *".karimo/.worktrees/${prd_slug}/"* ]] || continue
    [ -d "$wt_path" ] || continue

    local task_id
    task_id=$(basename "$wt_path")
    local branch_name="worktree/${prd_slug}-${task_id}"

    # Check if this task's PR is merged
    local pr_number
    pr_number=$(jq -r --arg tid "$task_id" '.tasks[$tid].pr_number // empty' "$status_file" 2>/dev/null || true)

    if [ -n "$pr_number" ]; then
      local merged_at
      merged_at=$(gh pr view "$pr_number" --json mergedAt --jq '.mergedAt' 2>/dev/null || true)
      if [ -n "$merged_at" ] && [ "$merged_at" != "null" ]; then
        echo "  Found orphan: $task_id (PR #$pr_number merged at $merged_at)"
        cleanup_task_worktree "$prd_slug" "$task_id"
        cleaned_count=$((cleaned_count + 1))
      fi
    fi
  done < <(git worktree list --porcelain 2>/dev/null || true)

  if [ "$cleaned_count" -gt 0 ]; then
    echo "  ✓ Cleaned $cleaned_count orphaned worktrees"
  else
    echo "  ✓ No orphaned worktrees found"
  fi

  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# cleanup_all_prd_orphans
#
# Clean up orphaned worktrees across ALL PRDs.
# Used by /karimo:doctor --fix.
#
# Arguments:
#   None
# ─────────────────────────────────────────────────────────────────────────────
cleanup_all_prd_orphans() {
  echo "Scanning for orphaned worktrees across all PRDs..."

  local total_cleaned=0

  for prd_dir in .karimo/prds/*/; do
    [ -d "$prd_dir" ] || continue
    local prd_slug
    prd_slug=$(basename "$prd_dir")

    local status_file="${prd_dir}status.json"
    if [ ! -f "$status_file" ]; then
      continue
    fi

    echo ""
    echo "PRD: $prd_slug"

    # Check for orphaned worktrees
    local prd_worktree_dir=".karimo/.worktrees/${prd_slug}"
    if [ ! -d "$prd_worktree_dir" ]; then
      echo "  ✓ No worktrees found"
      continue
    fi

    local prd_cleaned=0

    for wt_dir in "$prd_worktree_dir"/*; do
      [ -d "$wt_dir" ] || continue
      local task_id
      task_id=$(basename "$wt_dir")

      # Check if this task's PR is merged
      local pr_number
      pr_number=$(jq -r --arg tid "$task_id" '.tasks[$tid].pr_number // empty' "$status_file" 2>/dev/null || true)

      if [ -n "$pr_number" ]; then
        local merged_at
        merged_at=$(gh pr view "$pr_number" --json mergedAt --jq '.mergedAt' 2>/dev/null || true)
        if [ -n "$merged_at" ] && [ "$merged_at" != "null" ]; then
          echo "  ✓ Cleaned worktree: $wt_dir"
          prd_path="$prd_dir" cleanup_task_worktree "$prd_slug" "$task_id"
          prd_cleaned=$((prd_cleaned + 1))
        fi
      fi
    done

    if [ "$prd_cleaned" -eq 0 ]; then
      echo "  ✓ No orphans found"
    else
      total_cleaned=$((total_cleaned + prd_cleaned))
    fi
  done

  echo ""
  echo "Summary"
  echo "───────"
  if [ "$total_cleaned" -gt 0 ]; then
    echo "  ✓ $total_cleaned worktree(s) cleaned"
  else
    echo "  ✓ No orphaned worktrees found"
  fi

  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# cleanup_stale_branches
#
# Clean up worktree branches that have no open PR and no worktree directory.
# These are "ghost" branches left behind from incomplete cleanup.
#
# Arguments:
#   None (operates on all worktree/* branches)
# ─────────────────────────────────────────────────────────────────────────────
cleanup_stale_branches() {
  echo "Checking for stale worktree branches..."

  local branches_deleted=0

  # Get all local worktree branches
  local worktree_branches
  worktree_branches=$(git branch --list 'worktree/*' --format='%(refname:short)' 2>/dev/null || true)

  if [ -z "$worktree_branches" ]; then
    echo "  ✓ No worktree branches found"
    return 0
  fi

  for branch in $worktree_branches; do
    # Extract PRD slug and task ID from branch name (format: worktree/{prd-slug}-{task-id})
    # Task ID is always {digit}{letter}, so extract everything before final -{digit}{letter}
    local prd_slug
    prd_slug=$(echo "$branch" | sed 's|worktree/\(.*\)-[0-9][a-z]$|\1|')
    local task_id
    task_id=$(echo "$branch" | sed 's|worktree/.*-\([0-9][a-z]\)$|\1|')

    # Check if PRD folder exists
    if [ ! -d ".karimo/prds/$prd_slug" ]; then
      echo "  ✓ Deleted branch: $branch (PRD $prd_slug deleted)"
      git branch -D "$branch" 2>/dev/null || true
      git push origin --delete "$branch" 2>/dev/null || true
      branches_deleted=$((branches_deleted + 1))
      continue
    fi

    # Check if branch has open PR
    local has_open_pr
    has_open_pr=$(gh pr list --head "$branch" --state open --json number -q '.[0].number' 2>/dev/null || true)

    if [ -z "$has_open_pr" ]; then
      # No open PR - check if worktree exists
      local wt_path=".karimo/.worktrees/${prd_slug}/${task_id}"
      if [ ! -d "$wt_path" ]; then
        echo "  ✓ Deleted branch: $branch (no open PR, no worktree)"
        git branch -D "$branch" 2>/dev/null || true
        git push origin --delete "$branch" 2>/dev/null || true
        branches_deleted=$((branches_deleted + 1))
      fi
    fi
  done

  if [ "$branches_deleted" -gt 0 ]; then
    echo "  ✓ Deleted $branches_deleted stale branches"
  else
    echo "  ✓ No stale branches found"
  fi

  return 0
}
