#!/usr/bin/env bats
#
# KARIMO Cleanup Test Suite (v9.10.1)
#
# Tests for .karimo/scripts/lib/cleanup.sh functions.
#
# Usage:
#   bats .karimo/tests/cleanup.bats
#
# Requirements:
#   - bats-core installed (brew install bats-core)
#   - Run from repository root
#   - gh CLI authenticated (for PR status mocking)

# ─────────────────────────────────────────────────────────────────────────────
# Setup and teardown
# ─────────────────────────────────────────────────────────────────────────────

setup() {
  # Create temporary test directory
  TEST_DIR="$(mktemp -d)"
  cd "$TEST_DIR"

  # Initialize git repo
  git init --quiet
  git config user.email "test@example.com"
  git config user.name "Test User"
  echo "Initial commit" > README.md
  git add README.md
  git commit -m "Initial commit" --quiet

  # Create KARIMO structure
  mkdir -p .karimo/prds/test-prd
  mkdir -p .karimo/.worktrees/test-prd
  mkdir -p .karimo/scripts/lib

  # Copy cleanup library
  cp "$BATS_TEST_DIRNAME/../scripts/lib/cleanup.sh" .karimo/scripts/lib/

  # Create minimal status.json
  cat > .karimo/prds/test-prd/status.json << 'EOF'
{
  "prd_slug": "test-prd",
  "tasks": {
    "1a": {
      "wave": 1,
      "status": "done",
      "pr_number": 1
    },
    "1b": {
      "wave": 1,
      "status": "running",
      "pr_number": 2
    },
    "2a": {
      "wave": 2,
      "status": "pending"
    }
  },
  "active_worktrees": []
}
EOF

  # Source cleanup library
  source .karimo/scripts/lib/cleanup.sh

  # Set common variables
  prd_slug="test-prd"
  prd_path=".karimo/prds/test-prd"
  status_file="${prd_path}/status.json"
}

teardown() {
  cd /
  rm -rf "$TEST_DIR"
}

# ─────────────────────────────────────────────────────────────────────────────
# Helper functions for tests
# ─────────────────────────────────────────────────────────────────────────────

setup_fake_worktree() {
  local prd_slug="$1"
  local task_id="$2"
  local worktree_path=".karimo/.worktrees/${prd_slug}/${task_id}"
  local branch_name="worktree/${prd_slug}-${task_id}"

  # Create branch and worktree
  git checkout -b "$branch_name" --quiet 2>/dev/null || git checkout "$branch_name" --quiet
  git checkout main --quiet
  mkdir -p "$worktree_path"
  git worktree add "$worktree_path" "$branch_name" --quiet
}

# Mock gh pr view to return merged status
mock_gh_pr_merged() {
  export GH_PR_MERGED="true"
}

# Mock gh pr view to return open status
mock_gh_pr_open() {
  export GH_PR_OPEN="true"
}

# ─────────────────────────────────────────────────────────────────────────────
# Test: cleanup_task_worktree
# ─────────────────────────────────────────────────────────────────────────────

@test "cleanup_task_worktree removes worktree directory" {
  setup_fake_worktree "test-prd" "1a"

  # Verify worktree exists
  [ -d ".karimo/.worktrees/test-prd/1a" ]

  # Clean up
  run cleanup_task_worktree "test-prd" "1a"

  # Verify worktree removed
  [ ! -d ".karimo/.worktrees/test-prd/1a" ]
}

@test "cleanup_task_worktree deletes local branch" {
  setup_fake_worktree "test-prd" "1a"

  # Verify branch exists
  git show-ref --verify --quiet "refs/heads/worktree/test-prd-1a"

  # Clean up
  run cleanup_task_worktree "test-prd" "1a"

  # Verify branch deleted
  ! git show-ref --verify --quiet "refs/heads/worktree/test-prd-1a"
}

@test "cleanup_task_worktree removes parent dir if empty" {
  setup_fake_worktree "test-prd" "1a"

  # Clean up
  run cleanup_task_worktree "test-prd" "1a"

  # Verify parent directory removed (if it was empty)
  [ ! -d ".karimo/.worktrees/test-prd" ]
}

@test "cleanup_task_worktree is idempotent" {
  setup_fake_worktree "test-prd" "1a"

  # Clean up twice
  run cleanup_task_worktree "test-prd" "1a"
  [ "$status" -eq 0 ]

  run cleanup_task_worktree "test-prd" "1a"
  [ "$status" -eq 0 ]
}

@test "cleanup_task_worktree handles non-existent worktree" {
  # No worktree exists
  run cleanup_task_worktree "test-prd" "nonexistent"

  # Should succeed without error
  [ "$status" -eq 0 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Test: cleanup_wave_tasks
# ─────────────────────────────────────────────────────────────────────────────

@test "cleanup_wave_tasks cleans done tasks" {
  setup_fake_worktree "test-prd" "1a"

  # Task 1a is marked "done" in status.json
  run cleanup_wave_tasks "1"

  # Verify worktree cleaned
  [ ! -d ".karimo/.worktrees/test-prd/1a" ]
}

@test "cleanup_wave_tasks skips running tasks" {
  setup_fake_worktree "test-prd" "1b"

  # Task 1b is marked "running" in status.json
  run cleanup_wave_tasks "1"

  # Verify worktree NOT cleaned
  [ -d ".karimo/.worktrees/test-prd/1b" ]
}

@test "cleanup_wave_tasks skips pending tasks" {
  setup_fake_worktree "test-prd" "2a"

  # Task 2a is marked "pending" in status.json
  run cleanup_wave_tasks "2"

  # Verify worktree NOT cleaned
  [ -d ".karimo/.worktrees/test-prd/2a" ]
}

@test "cleanup_wave_tasks handles empty wave" {
  # Wave 99 has no tasks
  run cleanup_wave_tasks "99"

  # Should succeed
  [ "$status" -eq 0 ]
  [[ "$output" == *"No tasks found"* ]]
}

@test "cleanup_wave_tasks requires prd_slug and status_file" {
  unset prd_slug
  unset status_file

  run cleanup_wave_tasks "1"

  # Should error
  [ "$status" -eq 1 ]
  [[ "$output" == *"prd_slug and status_file must be set"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# Test: cleanup_orphaned_worktrees
# ─────────────────────────────────────────────────────────────────────────────

@test "cleanup_orphaned_worktrees reports no orphans when none exist" {
  # No worktrees at all
  run cleanup_orphaned_worktrees "test-prd"

  [ "$status" -eq 0 ]
  [[ "$output" == *"No orphaned worktrees found"* ]]
}

# Note: Full orphan cleanup testing requires mocking gh pr view,
# which is complex. These tests verify basic behavior.

@test "cleanup_orphaned_worktrees handles missing PRD gracefully" {
  run cleanup_orphaned_worktrees "nonexistent-prd"

  [ "$status" -eq 0 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Test: cleanup_all_prd_orphans
# ─────────────────────────────────────────────────────────────────────────────

@test "cleanup_all_prd_orphans scans all PRDs" {
  # Create another PRD
  mkdir -p .karimo/prds/other-prd
  cp .karimo/prds/test-prd/status.json .karimo/prds/other-prd/

  run cleanup_all_prd_orphans

  [ "$status" -eq 0 ]
  [[ "$output" == *"test-prd"* ]]
  [[ "$output" == *"other-prd"* ]]
}

@test "cleanup_all_prd_orphans handles no PRDs" {
  rm -rf .karimo/prds/*

  run cleanup_all_prd_orphans

  [ "$status" -eq 0 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Test: cleanup_stale_branches
# ─────────────────────────────────────────────────────────────────────────────

@test "cleanup_stale_branches handles no worktree branches" {
  run cleanup_stale_branches

  [ "$status" -eq 0 ]
  [[ "$output" == *"No worktree branches found"* ]]
}

@test "cleanup_stale_branches deletes branch for deleted PRD" {
  # Create branch but no PRD
  git checkout -b "worktree/deleted-prd-1a" --quiet
  git checkout main --quiet

  # PRD does not exist
  [ ! -d ".karimo/prds/deleted-prd" ]

  run cleanup_stale_branches

  # Branch should be deleted
  ! git show-ref --verify --quiet "refs/heads/worktree/deleted-prd-1a"
  [[ "$output" == *"Deleted branch"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# Test: Integration scenarios
# ─────────────────────────────────────────────────────────────────────────────

@test "worktree cadence: merge_wave_to_feature equivalent cleans up" {
  setup_fake_worktree "test-prd" "1a"

  # Simulate merge_wave_to_feature behavior
  cleanup_wave_tasks "1"

  [ ! -d ".karimo/.worktrees/test-prd/1a" ]
}

@test "wave cadence: cleanup after wait_for_pr_merge equivalent" {
  setup_fake_worktree "test-prd" "1a"

  # Simulate wave cadence post-merge behavior
  cleanup_wave_tasks "1"

  [ ! -d ".karimo/.worktrees/test-prd/1a" ]
}

@test "cleanup twice on same wave does not error" {
  setup_fake_worktree "test-prd" "1a"

  run cleanup_wave_tasks "1"
  [ "$status" -eq 0 ]

  run cleanup_wave_tasks "1"
  [ "$status" -eq 0 ]
}

@test "cleanup updates status.json active_worktrees" {
  setup_fake_worktree "test-prd" "1a"

  # Add to active_worktrees
  jq '.active_worktrees = [{"task_id": "1a", "path": ".karimo/.worktrees/test-prd/1a"}]' \
    "$status_file" > "${status_file}.tmp" && mv "${status_file}.tmp" "$status_file"

  # Verify it's there
  local count
  count=$(jq '.active_worktrees | length' "$status_file")
  [ "$count" -eq 1 ]

  # Clean up
  cleanup_task_worktree "test-prd" "1a"

  # Verify removed from active_worktrees
  count=$(jq '.active_worktrees | length' "$status_file")
  [ "$count" -eq 0 ]
}
