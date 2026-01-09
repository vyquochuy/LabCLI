#!/bin/bash

# Script kiểm thử đầy đủ các yêu cầu bắt buộc của đồ án
set -e

# ==========================================
# CẤU HÌNH MÔI TRƯỜNG CHẠY (Run Environment)
# ==========================================
# Tạo ID duy nhất cho lần chạy này dựa trên ngày giờ
RUN_ID="run_$(date +%Y%m%d_%H%M%S)"
HISTORY_DIR="test_history"
RUN_DIR="$HISTORY_DIR/$RUN_ID"

# Định nghĩa các đường dẫn trong thư mục riêng biệt
LOG_FILE="$RUN_DIR/test.log"
DATA_DIR="$RUN_DIR/dataset"
RESTORE_DIR="$RUN_DIR/restored_data"

# Đường dẫn tạm thời cho store (CLI thường ghi vào ./store tại thư mục gốc)
# dùng ./store để chạy, nhưng cuối cùng sẽ di chuyển nó vào RUN_DIR
TEMP_STORE_DIR="store"

mkdir -p "$DATA_DIR"
mkdir -p "$RESTORE_DIR"

# ==========================================
# CẤU HÌNH LOGGING
# ==========================================
# Chuyển hướng output vào file log bên trong thư mục run
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=========================================="
echo "TEST RUN ID: $RUN_ID"
echo "Artifacts location: $RUN_DIR"
echo "=========================================="
echo ""

# ==========================================
# CLEANUP & PREPARATION
# ==========================================
# Xóa store cũ ở root để đảm bảo test clean (nhưng store của các run trước đã được cất đi nên an toàn)
rm -rf "$TEMP_STORE_DIR"
# Không cần rm dataset hay restored_data vì ta đang dùng thư mục mới hoàn toàn

echo "=== Setup: Creating test data in $DATA_DIR ==="
echo ""

# Tạo cấu trúc thư mục phức tạp (Dùng biến $DATA_DIR thay vì cứng 'dataset')
mkdir -p "$DATA_DIR/dir1/subdir1"
mkdir -p "$DATA_DIR/dir2/subdir2/deepdir"
echo "File in root" > "$DATA_DIR/root.txt"
echo "File in dir1" > "$DATA_DIR/dir1/file1.txt"
echo "File in subdir1" > "$DATA_DIR/dir1/subdir1/file_sub1.txt"
echo "File in dir2" > "$DATA_DIR/dir2/file2.txt"
echo "Deep file" > "$DATA_DIR/dir2/subdir2/deepdir/deep.txt"

# Tạo file binary
dd if=/dev/urandom of="$DATA_DIR/binary.dat" bs=1K count=100 2>/dev/null
dd if=/dev/urandom of="$DATA_DIR/dir1/large.dat" bs=1M count=2 2>/dev/null

echo "Test data structure created:"
tree "$DATA_DIR" 2>/dev/null || find "$DATA_DIR" -type f

echo ""
echo "=========================================="
echo "Requirement 1: Delete source files,"
echo "               restore & verify tree"
echo "=========================================="
echo ""

# Backup toàn bộ dataset
# Lưu ý: trỏ vào $DATA_DIR
python src/cli.py backup "$DATA_DIR" --label "full-backup"
SNAP1=$(ls -t "$TEMP_STORE_DIR" | grep -v ".log" | head -1)
echo "✓ Backup completed: $SNAP1"
echo ""

# Xóa files từ source ($DATA_DIR)
echo "Deleting files from source..."
rm -f "$DATA_DIR/dir1/file1.txt"
rm -rf "$DATA_DIR/dir2/subdir2"
echo "Files deleted from source."
echo ""

# Restore từ snapshot vào $RESTORE_DIR
echo "Restoring from snapshot..."
python src/cli.py restore "$SNAP1" "$RESTORE_DIR"
echo ""

# So sánh cấu trúc
echo "Comparing directory trees..."
echo "Files in original backup (chunks):"
find "$TEMP_STORE_DIR/$SNAP1" -name "*.chunk" | wc -l | xargs echo "  Total chunks:"

echo ""
echo "Checking restored files exist:"
if [ -f "$RESTORE_DIR/dir1/file1.txt" ]; then
    echo "  ✓ restored_data/dir1/file1.txt exists"
else
    echo "  ✗ restored_data/dir1/file1.txt MISSING"
    exit 1
fi

if [ -f "$RESTORE_DIR/dir2/subdir2/deepdir/deep.txt" ]; then
    echo "  ✓ restored_data/dir2/subdir2/deepdir/deep.txt exists"
else
    echo "  ✗ restored_data/dir2/subdir2/deepdir/deep.txt MISSING"
    exit 1
fi

echo ""
echo "Comparing content of deleted files:"
if [ "$(cat "$RESTORE_DIR/dir1/file1.txt")" = "File in dir1" ]; then
    echo "  ✓ Content matches: dir1/file1.txt"
else
    echo "  ✗ Content mismatch"
    exit 1
fi

echo ""
echo "✓ Requirement 1 PASSED"
echo ""

echo "=========================================="
echo "Requirement 2: Modify 1 byte in chunk"
echo "=========================================="
echo ""

CHUNK_FILE=$(ls "$TEMP_STORE_DIR/$SNAP1/chunks" | head -1)
CHUNK_PATH="$TEMP_STORE_DIR/$SNAP1/chunks/$CHUNK_FILE"

echo "Selected chunk: $CHUNK_FILE"
# Sửa 1 byte
printf '\xFF' | dd of="$CHUNK_PATH" bs=1 count=1 conv=notrunc 2>/dev/null

echo "Running verify..."
if python src/cli.py verify "$SNAP1" 2>&1 | grep -q "Corrupted"; then
    echo "✓ Requirement 2 PASSED: Modification detected"
else
    echo "✗ Requirement 2 FAILED"
    exit 1
fi
echo ""

echo "=========================================="
echo "Requirement 3: Modify manifest"
echo "=========================================="
echo ""

# Tạo snapshot mới (clean) - Xóa store cũ đi làm lại cho sạch test case này
rm -rf "$TEMP_STORE_DIR"
# Cần tạo lại data dummy vì ở trên đã xóa bớt
mkdir -p "$DATA_DIR"
echo "Test data" > "$DATA_DIR/test.txt"

python src/cli.py backup "$DATA_DIR" --label "manifest-test"
SNAP2=$(ls -t "$TEMP_STORE_DIR" | grep -v ".log" | head -1)

MANIFEST_PATH="$TEMP_STORE_DIR/$SNAP2/manifest.json"
echo "Corrupting manifest..."
sed -i 's/"merkle_root": "\(.\)/"merkle_root": "0/' "$MANIFEST_PATH"

echo "Running verify..."
if python src/cli.py verify "$SNAP2" 2>&1 | grep -qE "mismatch|Rollback|error|fail"; then
    echo "✓ Requirement 3 PASSED: Manifest corruption detected"
else
    echo "✗ Requirement 3 FAILED"
    exit 1
fi
echo ""

echo "=========================================="
echo "Requirement 4: Rollback attack detection"
echo "=========================================="
echo ""

rm -rf "$TEMP_STORE_DIR" "$DATA_DIR"
mkdir -p "$DATA_DIR"

echo "Version 1" > "$DATA_DIR/file.txt"
python src/cli.py backup "$DATA_DIR" --label "v1"
SNAP_V1=$(ls -t "$TEMP_STORE_DIR" | grep -v ".log" | head -1)

echo "Version 2" > "$DATA_DIR/file.txt"
python src/cli.py backup "$DATA_DIR" --label "v2"
SNAP_V2=$(ls -t "$TEMP_STORE_DIR" | grep -v ".log" | head -1)

echo "Verifying OLD snapshot (V1)..."
if python src/cli.py verify "$SNAP_V1" 2>&1 | grep -q "Rollback"; then
    echo "✓ Requirement 4 PASSED: Rollback detected"
else
    echo "✗ Requirement 4 FAILED"
    exit 1
fi
echo ""

echo "=========================================="
echo "Requirement 5: Crash safety with WAL"
echo "=========================================="
echo ""

rm -rf "$DATA_DIR" "$TEMP_STORE_DIR"
mkdir -p "$DATA_DIR"
# Tạo file đủ lớn để kịp ngắt
dd if=/dev/urandom of="$DATA_DIR/huge.dat" bs=1M count=500 2>/dev/null

echo "Starting backup (will be interrupted)..."
timeout 0.5s python src/cli.py backup "$DATA_DIR" --label "interrupted" 2>/dev/null || true

echo "Checking WAL log..."
if [ -f "$TEMP_STORE_DIR/wal.log" ]; then
    if grep -q "BEGIN" "$TEMP_STORE_DIR/wal.log" && ! grep -q "COMMIT" "$TEMP_STORE_DIR/wal.log"; then
        echo "✓ WAL shows incomplete backup"
    fi
else
    echo "Note: WAL log not found (timing dependent)"
fi

echo "Checking store consistency..."
python src/cli.py backup "$DATA_DIR" --label "after-crash"
SNAP_AFTER=$(ls -t "$TEMP_STORE_DIR" | grep -v ".log" | head -1)

if python src/cli.py verify "$SNAP_AFTER" 2>&1 | grep -q "passed"; then
    echo "✓ Requirement 5 PASSED: Store remains functional"
else
    echo "✗ Requirement 5 FAILED"
    exit 1
fi
echo ""

echo "=========================================="
echo "Requirement 6: Policy enforcement"
echo "=========================================="
echo ""

# Thử chạy lệnh init (cấm với user thường)
python src/cli.py init 2>&1 | tee /tmp/policy_output.txt

if grep -q "DENY" /tmp/policy_output.txt; then
    if [ -f "$TEMP_STORE_DIR/audit.log" ] && grep -q "DENY" "$TEMP_STORE_DIR/audit.log"; then
        echo "✓ Requirement 6 PASSED: Denied and Logged"
    else
        echo "✗ DENY not found in audit log"
        exit 1
    fi
else
    echo "✗ Requirement 6 FAILED: Command not denied"
    exit 1
fi
echo ""

echo "=========================================="
echo "Requirement 7: Audit log tampering"
echo "=========================================="
echo ""

# Setup data for audit
rm -rf "$TEMP_STORE_DIR"
mkdir -p "$DATA_DIR"
echo "test" > "$DATA_DIR/test.txt"
python src/cli.py backup "$DATA_DIR" --label "audit1"
python src/cli.py backup "$DATA_DIR" --label "audit2"
python src/cli.py verify $(ls -t "$TEMP_STORE_DIR" | grep -v ".log" | head -1)

# Backup file audit gốc
cp "$TEMP_STORE_DIR/audit.log" "$TEMP_STORE_DIR/audit.log.backup"

# 7a: Sửa 1 ký tự
sed -i '2s/^./X/' "$TEMP_STORE_DIR/audit.log"
if python src/cli.py audit-verify 2>&1 | grep -q "AUDIT CORRUPTED"; then
    echo "✓ Test 7a PASSED"
else
    echo "✗ Test 7a FAILED"
    exit 1
fi

# 7b: Xóa 1 dòng
cp "$TEMP_STORE_DIR/audit.log.backup" "$TEMP_STORE_DIR/audit.log"
sed -i '2d' "$TEMP_STORE_DIR/audit.log"
if python src/cli.py audit-verify 2>&1 | grep -q "AUDIT CORRUPTED"; then
    echo "✓ Test 7b PASSED"
else
    echo "✗ Test 7b FAILED"
    exit 1
fi

echo ""
echo "=========================================="
echo "ALL REQUIREMENTS PASSED! ✓"
echo "=========================================="

# ==========================================
# FINALIZING & ARCHIVING
# ==========================================
echo ""
echo "=== Archiving test run ==="
# Di chuyển thư mục 'store' (đang nằm ở root) vào trong folder lịch sử chạy
if [ -d "$TEMP_STORE_DIR" ]; then
    mv "$TEMP_STORE_DIR" "$RUN_DIR/store"
    echo "✓ Moved 'store' to $RUN_DIR/store"
fi

echo ""
echo "Test Run Complete."
echo "Full logs and data preserved in: $RUN_DIR"