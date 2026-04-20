#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/scripts/gate" "$TMP_DIR/scripts/worker" "$TMP_DIR/.multi-agent" "$TMP_DIR/.github/workflows"

cp "$ROOT_DIR/scripts/asf" "$TMP_DIR/scripts/asf"
cp "$ROOT_DIR/scripts/gate/asf-doctor.sh" "$TMP_DIR/scripts/gate/asf-doctor.sh"

cat > "$TMP_DIR/scripts/asf-workflow.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "workflow:$*"
EOF

cat > "$TMP_DIR/scripts/gate/workflow.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "gate-workflow:$*"
EOF

cat > "$TMP_DIR/scripts/gate/command-dispatch.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "dispatch:$*"
EOF

cat > "$TMP_DIR/scripts/gate/command-validate.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "validate:$*"
EOF

cat > "$TMP_DIR/scripts/worker/workers-start.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "workers-start:$*"
EOF

cat > "$TMP_DIR/scripts/worker/workers-stop.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "workers-stop:$*"
EOF

cat > "$TMP_DIR/scripts/worker/delegate-issue-implementation.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "delegate:$*"
EOF

cat > "$TMP_DIR/.agent-swarm-framework.config.json" <<'EOF'
{}
EOF

cat > "$TMP_DIR/.agent-swarm-framework.manifest.json" <<'EOF'
{}
EOF

cat > "$TMP_DIR/.multi-agent/engine-routing.json" <<'EOF'
{}
EOF

cat > "$TMP_DIR/.github/workflows/multi-agent-planner-implementer.yml" <<'EOF'
name: test
EOF

chmod +x \
  "$TMP_DIR/scripts/asf" \
  "$TMP_DIR/scripts/gate/asf-doctor.sh" \
  "$TMP_DIR/scripts/asf-workflow.sh" \
  "$TMP_DIR/scripts/gate/workflow.sh" \
  "$TMP_DIR/scripts/gate/command-dispatch.sh" \
  "$TMP_DIR/scripts/gate/command-validate.sh" \
  "$TMP_DIR/scripts/worker/workers-start.sh" \
  "$TMP_DIR/scripts/worker/workers-stop.sh" \
  "$TMP_DIR/scripts/worker/delegate-issue-implementation.sh"

cd "$TMP_DIR"

bash scripts/asf --help | rg -q "doctor"
bash scripts/asf doctor
bash scripts/asf preflight | rg -q "workflow:preflight"
bash scripts/asf workers-start --interval 10 | rg -q "workers-start:--interval 10"
bash scripts/asf workers-stop | rg -q "workers-stop:"
bash scripts/asf delegate-implementation --issue-number 1 --task-command "echo hi" | rg -q "delegate:--issue-number 1 --task-command echo hi"

echo "[ok] asf-cli-doctor test passed"
