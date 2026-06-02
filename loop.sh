#!/bin/bash
# Usage: ./loop.sh [plan] [max_iterations]
# Examples:
#   ./loop.sh              # Build mode, unlimited iterations
#   ./loop.sh 20           # Build mode, max 20 iterations
#   ./loop.sh plan         # Plan mode, unlimited iterations
#   ./loop.sh plan 5       # Plan mode, max 5 iterations

# Parse arguments
if [ "$1" = "plan" ]; then
  # Plan mode
  MODE="plan"
  PROMPT_FILE="PROMPT_plan.md"
  MAX_ITERATIONS=${2:-0}
elif [[ "$1" =~ ^[0-9]+$ ]]; then
  # Build mode with max iterations
  MODE="build"
  PROMPT_FILE="PROMPT_build.md"
  MAX_ITERATIONS=$1
else
  # Build mode, unlimited (no arguments or invalid input)
  MODE="build"
  PROMPT_FILE="PROMPT_build.md"
  MAX_ITERATIONS=0
fi

ITERATION=0
CURRENT_BRANCH=$(git branch --show-current)

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Mode:   $MODE"
echo "Prompt: $PROMPT_FILE"
echo "Branch: $CURRENT_BRANCH"
[ $MAX_ITERATIONS -gt 0 ] && echo "Max:    $MAX_ITERATIONS iterations"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Verify prompt file exists
if [ ! -f "$PROMPT_FILE" ]; then
  echo "Error: $PROMPT_FILE not found"
  exit 1
fi

# Enable plan mode if needed
if [ "$MODE" = "plan" ]; then
  export OPENCODE_EXPERIMENTAL_PLAN_MODE=1
fi

while true; do
  if [ $MAX_ITERATIONS -gt 0 ] && [ $ITERATION -ge $MAX_ITERATIONS ]; then
    echo "Reached max iterations: $MAX_ITERATIONS"
    break
  fi

  # Read prompt content and run with opencode
  # --format json: Structured output for logging/monitoring
  # -m: Model to use (opencode/big-pickle)
  # --log-level DEBUG: Detailed execution logging
  PROMPT_CONTENT=$(cat "$PROMPT_FILE")
  opencode run "$PROMPT_CONTENT" \
    -m opencode/big-pickle \
    --log-level DEBUG

  # Push changes after each iteration
  git push origin "$CURRENT_BRANCH" || {
    echo "Failed to push. Creating remote branch..."
    git push -u origin "$CURRENT_BRANCH"
  }

  ITERATION=$((ITERATION + 1))
  echo -e "\n\n======================== LOOP $ITERATION ========================\n"
done
