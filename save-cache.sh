#!/bin/bash

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$BASE_DIR/shared.sh"

load_cache_config

COMMIT_MSG="save test cache"

help() {
  cat << EOF
Usage: $0 [OPTIONS]

Save test cache to the GitHub repository.

OPTIONS:
  -h, --help          Show this help message and exit.
  -m, --message MSG   Use custom commit message when saving the cache (Default: '$COMMIT_MSG').

EOF
}

while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help)
      help
      exit 0
      ;;
    -m|--message)
      if [[ -n $2 && $2 != -* ]]; then
        COMMIT_MSG="$2"
        shift
      else
        error "--message requires a non-empty argument." >&2
        help
        exit 1
      fi
      ;;
    *)
      error "Unknown option: $1" >&2
      help
      exit 1
      ;;
  esac
  shift
done

pushd "$CACHE_DIR" > /dev/null || error_exit "Failed to enter directory."

if ! git remote get-url origin >/dev/null 2>&1; then
  error_exit "Remote 'origin' is not set in the cache directory: $CACHE_DIR"
fi
if [[ "$(git rev-parse --abbrev-ref HEAD)" != "main" ]]; then
  error_exit "Not on 'main' branch in cache directory: $CACHE_DIR"
fi

# Unshallow if this is a shallow clone (e.g. from load-cache.sh --depth 1)
# to ensure pull/rebase operations work reliably.
if [[ -f "$(git rev-parse --git-dir)/shallow" ]]; then
  echo "Unshallowing the repository before saving..."
  git fetch --unshallow
else
  git fetch --all
fi
git add .

if ! git diff-index --quiet HEAD --; then
  echo "Saving test cache..."
  if ! git commit -m "$COMMIT_MSG"; then
    error_exit "Failed to commit changes."
  fi
  if ! git pull origin main; then # Assuming pull.rebase is set to true
      error_exit "Failed to pull latest changes from the cache repository. You might need to resolve conflicts manually in: $CACHE_DIR"
  fi
  if git push origin main; then
    success_exit "Cache saved successfully."
  else
    error_exit "Failed to push changes to the cache repository."
  fi
else
  if [[ "$(git rev-parse main)" == "$(git rev-parse origin/main)" ]]; then
    success_exit "No changes in the cache directory."
  else
    echo "Saving test cache..."
    if ! git rebase origin/main; then
      error_exit "Failed to rebase onto the latest changes in the cache repository. You might need to resolve conflicts manually in: $CACHE_DIR"
    fi
    if ! git push origin main; then
      error_exit "Failed to push changes to the cache repository. You might need to resolve conflicts manually in: $CACHE_DIR"
    else
      success_exit "Cache saved successfully."
    fi
  fi
fi
