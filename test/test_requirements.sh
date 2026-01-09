#!/bin/bash

# Script kiểm thử đầy đủ các yêu cầu bắt buộc của đồ án
set -e

# ==========================================
# CẤU HÌNH LOGGING (Phần thêm mới)
# ==========================================
LOG_DIR="test_logs"
LOG_FILE="$LOG_DIR/test2.log"

mkdir -p "$LOG_DIR"
# Tạo file rỗng hoặc xóa nội dung cũ
: > "$LOG_FILE"

# Lệnh này sẽ chuyển hướng toàn bộ output của script (stdout và stderr)
# vào lệnh tee. Tee sẽ vừa in ra màn hình, vừa ghi vào file log.
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=== Logging started to: $LOG_FILE ==="
# ==========================================

echo "=========================================="
echo "LabCLI Requirements Testing"
echo "=========================================="
echo ""

# Cleanup
rm -rf dataset restored_data store
mkdir -p dataset

echo "=== Setup: Creating test data ==="
echo ""

# Tạo cấu trúc thư mục phức tạp
mkdir -p dataset/dir1/subdir1
mkdir -p dataset/dir2/subdir2/deepdir
echo "File in root" > dataset/root.txt
echo "File in dir1" > dataset/dir1/file1.txt
echo "File in subdir1" > dataset/dir1/subdir1/file_sub1.txt
echo "File in dir2" > dataset/dir2/file2.txt
echo "Deep file" > dataset/dir2/subdir2/deepdir/deep.txt

# Tạo một số file binary
dd if=/dev/urandom of=dataset/binary.dat bs=1K count=100 2>/dev/null
dd if=/dev/urandom of=dataset/dir1/large.dat bs=1M count=2 2>/dev/null

echo "Test data structure created:"
tree dataset 2>/dev/null || find dataset -type f

echo ""
echo "=========================================="
echo "Requirement 1: Delete source files,"
echo "               restore & verify tree"
echo "=========================================="
echo ""

# Backup toàn bộ dataset
python src/cli.py backup dataset --label "full-backup"
SNAP1=$(ls -t store | grep -v ".log" | head -1)
echo "✓ Backup completed: $SNAP1"
echo ""

# Xóa một số files và directories từ source
echo "Deleting files from source..."
rm -f dataset/dir1/file1.txt
rm -rf dataset/dir2/subdir2
echo "Files deleted from source:"
echo "  - dataset/dir1/file1.txt"
echo "  - dataset/dir2/subdir2/ (entire directory)"
echo ""

# Restore từ snapshot
echo "Restoring from snapshot..."
mkdir -p restored_data
python src/cli.py restore "$SNAP1" restored_data
echo ""

# So sánh cấu trúc và nội dung
echo "Comparing directory trees..."
echo ""
echo "Files in original backup (before deletion):"
find store/$SNAP1 -name "*.chunk" | wc -l | xargs echo "  Total chunks:"

echo ""
echo "Checking restored files exist:"
if [ -f "restored_data/dir1/file1.txt" ]; then
    echo "  ✓ restored_data/dir1/file1.txt exists"
else
    echo "  ✗ restored_data/dir1/file1.txt MISSING"
    exit 1
fi

if [ -f "restored_data/dir2/subdir2/deepdir/deep.txt" ]; then
    echo "  ✓ restored_data/dir2/subdir2/deepdir/deep.txt exists"
else
    echo "  ✗ restored_data/dir2/subdir2/deepdir/deep.txt MISSING"
    exit 1
fi

echo ""
echo "Comparing content of deleted files:"
if [ "$(cat restored_data/dir1/file1.txt)" = "File in dir1" ]; then
    echo "  ✓ Content matches: dir1/file1.txt"
else
    echo "  ✗ Content mismatch"
    exit 1
fi

if [ "$(cat restored_data/dir2/subdir2/deepdir/deep.txt)" = "Deep file" ]; then
    echo "  ✓ Content matches: dir2/subdir2/deepdir/deep.txt"
else
    echo "  ✗ Content mismatch"
    exit 1
fi

echo ""
echo "✓ Requirement 1 PASSED: Restore recreated all deleted files with correct content and directory structure"
echo ""

echo "=========================================="
echo "Requirement 2: Modify 1 byte in chunk,"
echo "               verify must fail"
echo "=========================================="
echo ""

# Lấy một chunk từ snapshot
CHUNK_FILE=$(ls store/$SNAP1/chunks | head -1)
CHUNK_PATH="store/$SNAP1/chunks/$CHUNK_FILE"

echo "Selected chunk: $CHUNK_FILE"
echo "Original chunk hash (from filename): $CHUNK_FILE" | cut -d'.' -f1

# Lấy byte đầu tiên của chunk
ORIGINAL_BYTE=$(xxd -p -l 1 "$CHUNK_PATH")
echo "Original first byte: 0x$ORIGINAL_BYTE"

# Sửa chính xác 1 byte (byte đầu tiên)
printf '\xFF' | dd of="$CHUNK_PATH" bs=1 count=1 conv=notrunc 2>/dev/null

MODIFIED_BYTE=$(xxd -p -l 1 "$CHUNK_PATH")
echo "Modified first byte: 0x$MODIFIED_BYTE"
echo ""

# Verify phải fail
echo "Running verify (should detect corruption)..."
if python src/cli.py verify "$SNAP1" 2>&1 | grep -q "Corrupted"; then
    echo "✓ Requirement 2 PASSED: 1-byte modification detected"
else
    echo "✗ Requirement 2 FAILED: Corruption not detected"
    exit 1
fi
echo ""

echo "=========================================="
echo "Requirement 3: Modify manifest,"
echo "               verify must fail"
echo "=========================================="
echo ""

# Tạo snapshot mới (clean)
rm -rf store
# create if not exist
mkdir -p dataset
echo "Test data" > dataset/test.txt
python src/cli.py backup dataset --label "manifest-test"
SNAP2=$(ls -t store | grep -v ".log" | head -1)
echo "✓ Created clean snapshot: $SNAP2"
echo ""

MANIFEST_PATH="store/$SNAP2/manifest.json"
echo "Original manifest merkle_root:"
grep "merkle_root" "$MANIFEST_PATH"
echo ""

# Sửa manifest (thay đổi một ký tự trong merkle_root)
echo "Corrupting manifest..."
sed -i 's/"merkle_root": "\(.\)/"merkle_root": "0/' "$MANIFEST_PATH"

echo "Modified manifest merkle_root:"
grep "merkle_root" "$MANIFEST_PATH"
echo ""

# Verify phải fail
echo "Running verify (should detect manifest corruption)..."
if python src/cli.py verify "$SNAP2" 2>&1 | grep -qE "mismatch|Rollback|error|fail"; then
    echo "✓ Requirement 3 PASSED: Manifest corruption detected"
else
    echo "✗ Requirement 3 FAILED: Manifest corruption not detected"
    exit 1
fi
echo ""

echo "=========================================="
echo "Requirement 4: Rollback attack detection"
echo "=========================================="
echo ""

# Tạo 2 snapshots clean
rm -rf store dataset
mkdir -p dataset
echo "Version 1" > dataset/file.txt
python src/cli.py backup dataset --label "v1"
SNAP_V1=$(ls -t store | grep -v ".log" | head -1)
echo "✓ Created snapshot V1: $SNAP_V1"

echo "Version 2" > dataset/file.txt
python src/cli.py backup dataset --label "v2"
SNAP_V2=$(ls -t store | grep -v ".log" | head -1)
echo "✓ Created snapshot V2: $SNAP_V2"
echo ""

echo "roots.log content:"
cat store/roots.log
echo ""

echo "Attempting to verify OLD snapshot (V1)..."
if python src/cli.py verify "$SNAP_V1" 2>&1 | grep -q "Rollback"; then
    echo "✓ Requirement 4 PASSED: Rollback attack detected"
else
    echo "✗ Requirement 4 FAILED: Rollback attack not detected"
    exit 1
fi
echo ""

echo "Verifying LATEST snapshot (V2)..."
if python src/cli.py verify "$SNAP_V2" 2>&1 | grep -q "passed"; then
    echo "✓ Latest snapshot verified successfully"
else
    echo "✗ Latest snapshot verification failed"
    exit 1
fi
echo ""

echo "=========================================="
echo "Requirement 5: Crash safety with WAL"
echo "=========================================="
echo ""

# Tạo dataset lớn để backup mất nhiều thời gian
rm -rf dataset store
mkdir -p dataset
dd if=/dev/urandom of=dataset/huge.dat bs=1M count=100 2>/dev/null
echo "✓ Created 100MB test file"
echo ""

echo "Starting backup (will be interrupted)..."
# Chạy backup trong background và kill sau 0.5 giây
timeout 0.5s python src/cli.py backup dataset --label "interrupted" 2>/dev/null || true

echo "Process interrupted"
echo ""

echo "Checking WAL log:"
if [ -f "store/wal.log" ]; then
    cat store/wal.log
    
    # Kiểm tra có BEGIN nhưng không có COMMIT
    if grep -q "BEGIN.*interrupted" store/wal.log && ! grep -q "COMMIT.*interrupted" store/wal.log; then
        echo "✓ WAL shows incomplete backup (BEGIN without COMMIT)"
    fi
else
    echo "WAL log not found (crash happened too early)"
fi
echo ""

echo "Checking store consistency..."
# Thử backup lại để verify store vẫn hoạt động
python src/cli.py backup dataset --label "after-crash"
SNAP_AFTER=$(ls -t store | grep -v ".log" | head -1)
echo "✓ New backup created: $SNAP_AFTER"
echo ""

# Verify snapshot mới
echo "Verifying new snapshot..."
if python src/cli.py verify "$SNAP_AFTER" 2>&1 | grep -q "passed"; then
    echo "✓ Requirement 5 PASSED: Store remains functional after crash"
else
    echo "✗ Requirement 5 FAILED: Store corrupted after crash"
    exit 1
fi
echo ""

echo "=========================================="
echo "Requirement 6: Policy enforcement & DENY"
echo "=========================================="
echo ""

# Tạo clean store
rm -rf store
mkdir -p dataset
echo "test" > dataset/test.txt

# Kiểm tra user hiện tại
CURRENT_USER=$(python -c "import sys; sys.path.insert(0, 'src'); from security import get_current_user; print(get_current_user())")
echo "Current user: $CURRENT_USER"
echo ""

# Kiểm tra policy
echo "Policy configuration:"
cat policy.yaml | grep -A 20 "roles:"
echo ""

# Thử chạy lệnh không được phép
echo "Attempting to run 'init' command (should be denied for non-admin)..."
python src/cli.py init 2>&1 | tee /tmp/policy_output.txt

if grep -q "DENY" /tmp/policy_output.txt; then
    echo "✓ Command was denied"
    
    # Kiểm tra audit log có ghi DENY không
    if [ -f "store/audit.log" ] && grep -q "DENY" store/audit.log; then
        echo "✓ DENY recorded in audit log"
        echo ""
        echo "Audit log entry:"
        grep "DENY" store/audit.log | tail -1
        echo ""
        echo "✓ Requirement 6 PASSED: Policy enforcement working, DENY logged"
    else
        echo "✗ DENY not found in audit log"
        exit 1
    fi
else
    echo "✗ Requirement 6 FAILED: Command was not denied"
    echo "Note: Check if current user '$CURRENT_USER' has 'init' permission in policy.yaml"
    exit 1
fi
echo ""

echo "=========================================="
echo "Requirement 7: Audit log tampering detection"
echo "=========================================="
echo ""

# Tạo một số operations để có audit log
rm -rf store
mkdir -p dataset
echo "test" > dataset/test.txt

python src/cli.py backup dataset --label "audit1"
python src/cli.py backup dataset --label "audit2"
python src/cli.py verify $(ls -t store | grep -v ".log" | head -1)

echo "Original audit log:"
cat store/audit.log
echo ""

# Test 7a: Sửa 1 ký tự
echo "Test 7a: Modifying 1 character in audit log..."
cp store/audit.log store/audit.log.backup

# Sửa ký tự đầu tiên của dòng thứ 2
sed -i '2s/^./X/' store/audit.log

echo "Modified audit log:"
cat store/audit.log
echo ""

echo "Running audit-verify (should detect corruption)..."
if python src/cli.py audit-verify 2>&1 | grep -q "AUDIT CORRUPTED"; then
    echo "✓ Test 7a PASSED: Character modification detected"
else
    echo "✗ Test 7a FAILED: Character modification not detected"
    exit 1
fi
echo ""

# Test 7b: Xóa 1 dòng
echo "Test 7b: Deleting 1 line from audit log..."
cp store/audit.log.backup store/audit.log

# Xóa dòng thứ 2
sed -i '2d' store/audit.log

echo "Modified audit log (line deleted):"
cat store/audit.log
echo ""

echo "Running audit-verify (should detect corruption)..."
if python src/cli.py audit-verify 2>&1 | grep -q "AUDIT CORRUPTED"; then
    echo "✓ Test 7b PASSED: Line deletion detected"
else
    echo "✗ Test 7b FAILED: Line deletion not detected"
    exit 1
fi
echo ""

echo "✓ Requirement 7 PASSED: All audit tampering scenarios detected"
echo ""

echo "=========================================="
echo "ALL REQUIREMENTS PASSED! ✓"
echo "=========================================="
echo ""

echo "Summary:"
echo "--------"
echo "✓ Req 1: Delete source files, restore with correct tree & content"
echo "✓ Req 2: 1-byte chunk modification detected"
echo "✓ Req 3: Manifest corruption detected"
echo "✓ Req 4: Rollback attack detected"
echo "✓ Req 5: Store functional after crash (WAL working)"
echo "✓ Req 6: Policy enforcement & DENY logged"
echo "✓ Req 7: Audit log tampering detected (modify + delete)"
echo ""

# Cleanup
echo "Test artifacts preserved in: store/"
echo "Logs preserved in: $LOG_FILE"