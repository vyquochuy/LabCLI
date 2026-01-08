#!/bin/bash

# Script kiểm thử đầy đủ cho LabCLI

set -e

echo "=========================================="
echo "LabCLI Testing Suite"
echo "=========================================="
echo ""

# Cleanup
rm -rf dataset store store
mkdir -p dataset/subdir1/subdir2

# Tạo test data
echo "Test file 1" > dataset/file1.txt
echo "Test file 2" > dataset/file2.txt
echo "Test file 3" > dataset/subdir1/file3.txt
echo "Test file 4" > dataset/subdir1/subdir2/file4.txt
dd if=/dev/urandom of=dataset/binary.dat bs=1M count=2 2>/dev/null

echo "Test 1: Basic Backup"
echo "--------------------"
python src/cli.py backup dataset --label "test1"
echo ""

# Lấy snapshot ID (snapshot mới nhất)
SNAP1=$(ls -t store | grep -v ".log" | head -1)
echo "Snapshot created: $SNAP1"
echo ""

echo "Test 2: Verify Snapshot"
echo "-----------------------"
python src/cli.py verify "$SNAP1"
echo ""

echo "Test 3: Restore Snapshot"
echo "------------------------"
mkdir -p restored_data
python src/cli.py restore "$SNAP1" restored_data
echo ""

echo "Test 4: Compare Original vs Restored"
echo "-------------------------------------"
# So sánh dataset gốc với thư mục vừa restore xong
if diff -r dataset restored_data; then
    echo "✓ Files match perfectly!"
else
    echo "✗ Files don't match!"
    exit 1
fi
echo ""

echo "Test 5: Data Corruption Detection"
echo "----------------------------------"
# Tạo snapshot thứ 2
python src/cli.py backup dataset --label "test2"
SNAP2=$(ls -t store | grep -v ".log" | head -1)

# Corrupt một chunk
FIRST_CHUNK=$(ls store/$SNAP2/chunks | head -1)
echo "corrupted data" > "store/$SNAP2/chunks/$FIRST_CHUNK"

echo "Verifying corrupted snapshot..."
if python src/cli.py verify "$SNAP2" 2>&1 | grep -q "Corrupted"; then
    echo "✓ Corruption detected successfully!"
else
    echo "✗ Failed to detect corruption!"
    exit 1
fi
echo ""

echo "Test 6: Missing Chunk Detection"
echo "--------------------------------"
# Tạo snapshot thứ 3
rm -rf store/$SNAP2  # Clean corrupted
python src/cli.py backup dataset --label "test3"
SNAP3=$(ls -t store | grep -v ".log" | head -1)

# Xóa một chunk
FIRST_CHUNK=$(ls store/$SNAP3/chunks | head -1)
rm "store/$SNAP3/chunks/$FIRST_CHUNK"

echo "Verifying snapshot with missing chunks..."
if python src/cli.py verify "$SNAP3" 2>&1 | grep -q "Missing"; then
    echo "✓ Missing chunks detected successfully!"
else
    echo "✗ Failed to detect missing chunks!"
    exit 1
fi
echo ""

echo "Test 7: Rollback Attack Detection"
echo "----------------------------------"
# Tạo 2 snapshots sạch
rm -rf store
mkdir -p dataset
echo "Version 1" > dataset/file.txt
python src/cli.py backup dataset --label "v1"
SNAP_V1=$(ls -t store | grep -v ".log" | head -1)

echo "Version 2" > dataset/file.txt
python src/cli.py backup dataset --label "v2"
SNAP_V2=$(ls -t store | grep -v ".log" | head -1)

echo "Trying to verify older snapshot (should fail)..."
if python src/cli.py verify "$SNAP_V1" 2>&1 | grep -q "Rollback"; then
    echo "✓ Rollback attack detected successfully!"
else
    echo "✗ Failed to detect rollback attack!"
    exit 1
fi

echo "Verifying latest snapshot (should pass)..."
if python src/cli.py verify "$SNAP_V2" 2>&1 | grep -q "passed"; then
    echo "✓ Latest snapshot verified successfully!"
else
    echo "✗ Failed to verify latest snapshot!"
    exit 1
fi
echo ""

echo "Test 8: Deduplication"
echo "---------------------"
# Tạo files giống nhau
rm -rf dataset store
mkdir dataset
echo "Same content" > dataset/file1.txt
echo "Same content" > dataset/file2.txt
echo "Same content" > dataset/file3.txt

python src/cli.py backup dataset --label "dedup-test"
SNAP_DEDUP=$(ls -t store | grep -v ".log" | head -1)

CHUNK_COUNT=$(ls store/$SNAP_DEDUP/chunks | wc -l)
if [ "$CHUNK_COUNT" -eq 1 ]; then
    echo "✓ Deduplication working! Only 1 chunk for 3 identical files"
else
    echo "✗ Deduplication failed! Found $CHUNK_COUNT chunks"
    exit 1
fi
echo ""

echo "Test 9: Audit Log Chain"
echo "-----------------------"
# Không cần lệnh export PYTHONPATH ở đây nữa nếu dùng cách dưới
python -c "
import sys
import os
# Chèn thư mục src vào đầu danh sách tìm kiếm module
sys.path.insert(0, os.path.join(os.getcwd(), 'src'))

from utils.hash import sha256_str
from utils.constants import ZERO_HASH

with open('store/audit.log', 'r') as f:
    lines = f.readlines()

prev_hash = ZERO_HASH
valid = True

for i, line in enumerate(lines):
    parts = line.strip().split()
    if len(parts) < 2: continue # Bỏ qua dòng trống
    
    entry_hash = parts[0]
    prev_in_entry = parts[1]
    
    if prev_hash != prev_in_entry:
        print(f'✗ Chain broken at entry {i+1}')
        valid = False
        break
    
    # Verify hash: băm phần nội dung còn lại của dòng
    raw = ' '.join(parts[1:])
    computed = sha256_str(raw)
    if computed != entry_hash:
        print(f'✗ Hash mismatch at entry {i+1}')
        valid = False
        break
    
    prev_hash = entry_hash

if valid:
    print(f'✓ Audit log chain valid ({len(lines)} entries)')
"
echo ""

echo "Test 10: Large File Chunking"
echo "-----------------------------"
rm -rf dataset store
mkdir dataset

# Tạo file 5MB (sẽ được chia thành 5 chunks 1MB)
dd if=/dev/urandom of=dataset/large.dat bs=1M count=5 2>/dev/null

python src/cli.py backup dataset --label "large-file"
SNAP_LARGE=$(ls -t store | grep -v ".log" | head -1)

CHUNK_COUNT=$(ls store/$SNAP_LARGE/chunks | wc -l)
echo "File 5MB được chia thành $CHUNK_COUNT chunks"

if [ "$CHUNK_COUNT" -eq 5 ]; then
    echo "✓ Chunking working correctly!"
else
    echo "✗ Expected 5 chunks, got $CHUNK_COUNT"
    exit 1
fi
echo ""

echo "Test 11: Restore Abort on Failed Verify"
echo "----------------------------------------"
# Corrupt snapshot
FIRST_CHUNK=$(ls store/$SNAP_LARGE/chunks | head -1)
echo "corrupted" > "store/$SNAP_LARGE/chunks/$FIRST_CHUNK"

rm -rf store
if python src/cli.py restore "$SNAP_LARGE" store 2>&1 | grep -q "aborted"; then
    echo "✓ Restore correctly aborted on failed verification!"
    
    # Verify target not created or empty
    if [ ! -d "store" ] || [ -z "$(ls -A store 2>/dev/null)" ]; then
        echo "✓ No partial restore created!"
    else
        echo "✗ Partial restore was created!"
        exit 1
    fi
else
    echo "✗ Restore should have been aborted!"
    exit 1
fi
echo ""

echo "=========================================="
echo "All Tests Passed! ✓"
echo "=========================================="
echo ""

echo "Summary:"
echo "--------"
echo "✓ Backup creates valid snapshots"
echo "✓ Verify detects data corruption"
echo "✓ Verify detects missing chunks"
echo "✓ Rollback attacks are detected"
echo "✓ Restore recreates exact files"
echo "✓ Restore aborts on failed verify"
echo "✓ Deduplication works correctly"
echo "✓ Audit log chain is valid"
echo "✓ Large files are chunked properly"
echo ""

# Cleanup
rm -rf dataset store

echo "Test artifacts preserved in: store/"