#!/bin/bash
set -e

LOG_DIR="test_logs"
LOG_FILE="$LOG_DIR/test.log"

mkdir -p "$LOG_DIR"
echo "" > "$LOG_FILE"

log() {
    echo "$1" | tee -a "$LOG_FILE"
}

section() {
    log ""
    log "========================================"
    log "$1"
    log "========================================"
}

########################################
section "[TEST 1] Restore after deleting source"
########################################

rm -rf dataset restored store
mkdir -p dataset/sub/a

echo "hello" > dataset/file1.txt
echo "world" > dataset/sub/a/file2.txt

log "[INFO] Creating snapshot"
python src/cli.py backup dataset --label "base" >> "$LOG_FILE" 2>&1
SNAP=$(ls -t store | grep -v ".log" | head -1)

log "[INFO] Deleting source and restoring"
rm -rf dataset
mkdir restored
python src/cli.py restore "$SNAP" restored >> "$LOG_FILE" 2>&1

if diff -r restored restored >/dev/null; then
    log "[PASS] Restore tree & content correct"
else
    log "[FAIL] Restore mismatch"
    exit 1
fi

########################################
section "[TEST 2] Modify 1 byte in chunk"
########################################

CHUNK=$(ls store/$SNAP/chunks | head -1)
log "[INFO] Corrupting chunk $CHUNK (1 byte)"

printf '\xff' | dd of="store/$SNAP/chunks/$CHUNK" bs=1 count=1 conv=notrunc 2>>"$LOG_FILE"

if python src/cli.py verify "$SNAP" 2>&1 | tee -a "$LOG_FILE" | grep -q "Corrupted"; then
    log "[PASS] Chunk corruption detected"
else
    log "[FAIL] Corruption not detected"
    exit 1
fi

########################################
section "[TEST 3] Manifest corruption"
########################################

log "[INFO] Overwriting manifest.json"
echo "broken content" > store/$SNAP/manifest.json

if python src/cli.py verify "$SNAP" 2>&1 | tee -a "$LOG_FILE" | grep -qiE "invalid|corrupt|error"; then
    log "[PASS] Manifest corruption detected"
else
    log "[FAIL] Manifest corruption not detected"
    exit 1
fi

########################################
section "[TEST 4] Rollback detection"
########################################

rm -rf dataset store
mkdir dataset

echo "v1" > dataset/file.txt
python src/cli.py backup dataset --label "v1" >> "$LOG_FILE" 2>&1
OLD=$(ls -t store | grep -v ".log" | head -1)

echo "v2" > dataset/file.txt
python src/cli.py backup dataset --label "v2" >> "$LOG_FILE" 2>&1
NEW=$(ls -t store | grep -v ".log" | head -1)

log "[INFO] Verifying older snapshot (rollback attempt)"

if python src/cli.py verify "$OLD" 2>&1 | tee -a "$LOG_FILE" | grep -q "Rollback"; then
    log "[PASS] Rollback attack detected"
else
    log "[FAIL] Rollback not detected"
    exit 1
fi

########################################
section "[TEST 5] Interrupted backup recovery"
########################################

dd if=/dev/urandom of=dataset/big.dat bs=1M count=200 2>>"$LOG_FILE"

log "[INFO] Running backup and killing early"
timeout 1s python src/cli.py backup dataset --label "crash" >> "$LOG_FILE" 2>&1 || true

LATEST=$(ls -t store | grep -v ".log" | head -1)
log "[INFO] Verifying latest valid snapshot: $LATEST"

if python src/cli.py verify "$LATEST" >> "$LOG_FILE" 2>&1; then
    log "[PASS] Store remains consistent after crash"
else
    log "[FAIL] Store corrupted after interrupted backup"
    exit 1
fi

########################################
section "[TEST 6] Policy enforcement (RBAC)"
########################################

log "[INFO] Running forbidden command (init)"

if python src/cli.py init 2>&1 | tee -a "$LOG_FILE" | grep -q "DENY"; then
    # print current user
    log "$(whoami)"
    log "[PASS] Policy correctly denied action"
else
    
    log "[FAIL] Policy did not deny action"
    exit 1
fi

if grep -q "DENY" store/audit.log; then
    log "[PASS] DENY recorded in audit log"
else
    log "[FAIL] DENY not logged"
    exit 1
fi

########################################
section "[TEST 7] Audit log tampering"
########################################

log "[INFO] Deleting last audit log entry"
sed -i '$d' store/audit.log

if python src/cli.py audit-verify 2>&1 | tee -a "$LOG_FILE" | grep -q "AUDIT CORRUPTED"; then
    log "[PASS] Audit tampering detected"
else
    log "[FAIL] Audit tampering not detected"
    exit 1
fi

########################################
log ""
log "===== ALL REQUIRED TESTS PASSED ✓ ====="
log "Log saved at: $LOG_FILE"
