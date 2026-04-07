#!/bin/bash

help() {
  cat << EOF
Usage: $0 [OPTIONS]

Load test cache from GitHub repository.

OPTIONS:
  -t, --token TOKEN    Provide the GitHub token if running in CI.
      --rm             Remove existing cache directory before recreating it.
  -h, --help          Show this help message and exit.

EOF
}

while [[ $# -gt 0 ]]; do
  case $1 in
    -t|--token)
      GITHUB_TOKEN="$2"
      shift 2
      ;;
    --rm)
      REMOVE_CACHE=true
      shift
      ;;
    -h|--help)
      help
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      help
      exit 1
      ;;
  esac
done

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$BASE_DIR/shared.sh"

echo "Loading test cache..."
if [ "$REMOVE_CACHE" = true ]; then
    important "Removing existing cache directory: $CACHE_DIR"
    rm -rf "$CACHE_DIR"
fi
if [ ! -d "$CACHE_DIR" ]; then
  if [ -n "$GITHUB_TOKEN" ]; then
    git clone --depth 1 "https://$GITHUB_TOKEN@github.com/Apicurio/apicurio-testing-cache.git" "$CACHE_DIR"
    pushd "$CACHE_DIR" > /dev/null || error_exit "Failed to enter directory."
    git config user.name "apicurio-ci"
    git config user.email "apicurio.ci@gmail.com"
    git config pull.rebase true
  else
    git clone --depth 1 git@github.com:Apicurio/apicurio-testing-cache.git "$CACHE_DIR"
    pushd "$CACHE_DIR" > /dev/null || error_exit "Failed to enter directory."
    git config pull.rebase true
  fi
else
  important "Cache directory already exists: $CACHE_DIR"
  important "If you want to re-clone it, use the --rm option."
  pushd "$CACHE_DIR" > /dev/null || error_exit "Failed to enter directory."
  if ! git diff-index --quiet HEAD --; then
    error_exit "There are uncommitted changes in the cache directory."
  fi
  if [[ -n $(git ls-files --others --exclude-standard) ]]; then
    warning "There are untracked files in the cache directory."
  fi
  if git pull origin main; then
    success_exit "Cache loaded successfully."
  else
    exit_error "Failed to pull the latest changes from the cache repository. You might need to resolve conflicts manually in: $CACHE_DIR"
  fi
fi
