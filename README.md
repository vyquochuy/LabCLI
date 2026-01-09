# LabCLI – Secure Backup & Restore System

Hệ thống dòng lệnh thực hiện sao lưu và phục hồi dữ liệu với các cơ chế:

* Chunking + deduplication
* Kiểm chứng toàn vẹn bằng Merkle Tree
* Chống rollback attack
* Crash-safe thông qua Write-Ahead Logging (WAL)
* Audit log dạng hash chain
* Policy kiểm soát thao tác dựa trên OS user

---

## 1. Cài đặt và chạy chương trình

### Yêu cầu

* Python ≥ 3.7
* PyYAML

### Cài đặt

```bash
pip install -r requirements.txt
```

### Chạy các lệnh chính

```bash
python src/cli.py backup <source_path> --label <label>
python src/cli.py verify <snapshot_id>
python src/cli.py restore <snapshot_id> <target_path>
python src/cli.py audit-verify
```

Thư mục `store/` (lưu snapshot, chunk, audit, wal) sẽ **tự động được tạo khi chạy lần đầu**.

---

## 2. Chunk size, manifest canonical và Merkle Tree

### Chunking

* File được chia thành các chunk kích thước **1 MiB**
* Mỗi chunk được hash bằng SHA-256
* Chunk được lưu theo tên hash → tự động deduplication

### Canonical manifest

* Mỗi snapshot có một `manifest.json`
* File trong manifest được **sắp xếp theo đường dẫn (lexicographic order)**
* Danh sách chunk trong mỗi file giữ nguyên thứ tự xuất hiện
* Nhờ đó, cùng một dữ liệu đầu vào sẽ luôn sinh ra manifest và Merkle root giống nhau

### Merkle Tree

* Leaf nodes: hash của các chunk
* Node cha: SHA-256(left_hash || right_hash)
* Nếu số node lẻ, node cuối được nhân đôi
* Merkle root được lưu trong metadata snapshot và dùng để verify toàn vẹn

---

## 3. Cơ chế chống Rollback Attack

### Nguyên lý

Rollback attack xảy ra khi snapshot mới bị thay thế bằng snapshot cũ hơn.
Hệ thống ngăn chặn bằng cách **chỉ chấp nhận snapshot có Merkle root mới nhất**.

### roots.log

* Mỗi dòng lưu một Merkle root theo thứ tự append-only
* Không cho phép sửa hoặc xóa root cũ

### Kiểm tra

* Khi verify / restore:

  * Root của snapshot phải tồn tại trong `roots.log`
  * Root đó phải là **root cuối cùng**

### Reproduce test rollback

1. Backup lần 1 → snapshot A
2. Thay đổi dữ liệu → backup lần 2 → snapshot B
3. Thực hiện verify snapshot A
   → Kết quả: **FAIL (rollback detected)**

---

## 4. Journal / Write-Ahead Logging (WAL)

### Mục đích

Đảm bảo hệ thống không rơi vào trạng thái snapshot “nửa vời” khi crash.

### wal.log

* Ghi `BEGIN <snapshot_id>` khi bắt đầu backup
* Ghi `COMMIT <snapshot_id>` khi backup hoàn tất

### Nguyên tắc

* Snapshot không có COMMIT được xem là **không hợp lệ**
* Snapshot incomplete sẽ không được chấp nhận khi verify / restore

### Reproduce crash test

1. Backup dữ liệu lớn
2. Kill process giữa chừng
3. Quan sát `wal.log` có BEGIN nhưng không có COMMIT
4. Snapshot đó không được verify / restore thành công

---

## 5. Policy.yaml – kiểm soát thao tác

### Schema

```yaml
default_role: <role_name>   # optional

users:
  <os_username>: <role_name>

roles:
  <role_name>:
    - <command>
```

### Commands hỗ trợ

* `backup`
* `verify`
* `restore`
* `audit-verify`
* `list-snapshots`

### Ví dụ

```yaml
default_role: operator

users:
  root: admin

roles:
  admin:
    - backup
    - verify
    - restore
    - audit-verify

  operator:
    - backup
    - verify
    - restore
```

→ Mọi OS user đều được gán `operator` nếu không khai báo cụ thể.

---

## 6. Audit log

### Định dạng mỗi dòng

```
entry_hash prev_hash timestamp user command args_hash status
```

### Đặc điểm

* `entry_hash` = SHA-256 của toàn bộ nội dung dòng
* `prev_hash` = hash của dòng trước → tạo hash chain
* Log chỉ append, không sửa

### audit-verify

```bash
python src/cli.py audit-verify
```

Lệnh này:

* Kiểm tra liên kết hash chain
* Phát hiện chỉnh sửa, chèn hoặc xóa log

---

## 7. Cách xác định USER từ hệ điều hành

Chương trình **không dùng login/OAuth**, USER được xác định như sau:

1. Nếu tồn tại biến môi trường `SUDO_USER`
   → USER = `SUDO_USER` (người gọi sudo, không phải root)
2. Ngược lại
   → USER = tài khoản OS hiện tại (`whoami`)
3. Nếu không xác định được USER
   → từ chối chạy và ghi audit với `STATUS=FAIL`

Cách này đảm bảo:

* Audit ghi đúng người thực thi
* Không bypass policy bằng sudo

---

## 8. Tổng kết

Hệ thống đáp ứng đầy đủ yêu cầu đồ án:

* Toàn vẹn dữ liệu (Merkle Tree)
* Chống rollback
* An toàn khi crash (WAL)
* Audit tamper-evident
* Phân quyền dựa trên OS user

---