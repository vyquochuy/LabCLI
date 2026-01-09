import argparse
import sys

from utils import STATUS_DENY, STATUS_OK, STATUS_FAIL
from core import backup, verify, restore
from security import get_current_user, Policy, AuditLogger

def audit_verify_command(audit_log_path):
    """
    Kiểm tra toàn vẹn của audit log chain
    """
    from utils.hash import sha256_str
    from utils.constants import ZERO_HASH
    import os
    
    try:
        with open(audit_log_path, 'r') as f:
            lines = f.readlines()
    except FileNotFoundError:
        print("Audit log not found")
        return STATUS_FAIL
    
    if not lines:
        print("Empty audit log (valid)")
        return STATUS_OK
    
    prev_hash = ZERO_HASH
    
    for i, line in enumerate(lines):
        line = line.strip()
        if not line:
            continue
        
        parts = line.split()
        if len(parts) < 7:
            print(f"AUDIT CORRUPTED: Line {i+1} - Invalid format")
            return STATUS_FAIL
        
        entry_hash = parts[0]
        prev_in_entry = parts[1]
        
        # Kiểm tra chain linking
        if prev_hash != prev_in_entry:
            print(f"AUDIT CORRUPTED: Line {i+1} - Chain broken")
            print(f"  Expected prev: {prev_hash}")
            print(f"  Got prev: {prev_in_entry}")
            return STATUS_FAIL
        
        # Kiểm tra entry hash
        raw = ' '.join(parts[1:])
        computed_hash = sha256_str(raw)
        
        if computed_hash != entry_hash:
            print(f"AUDIT CORRUPTED: Line {i+1} - Hash mismatch")
            print(f"  Expected hash: {entry_hash}")
            print(f"  Computed hash: {computed_hash}")
            return STATUS_FAIL
        
        prev_hash = entry_hash
    
    # Kiểm tra truncation bằng audit_roots.log
    audit_roots_path = os.path.join(os.path.dirname(audit_log_path), "audit_roots.log")
    try:
        with open(audit_roots_path, 'r') as f:
            roots = f.readlines()
        
        if roots:
            last_root = roots[-1].strip().split()
            if len(last_root) >= 2:
                expected_count = int(last_root[0])
                expected_hash = last_root[1]
                current_count = len([l for l in lines if l.strip()])
                
                if current_count < expected_count:
                    print(f"AUDIT CORRUPTED: Truncation detected")
                    print(f"  Expected {expected_count} entries, found {current_count}")
                    return STATUS_FAIL
                
                if current_count == expected_count and prev_hash != expected_hash:
                    print(f"AUDIT CORRUPTED: Last entry hash mismatch")
                    print(f"  Expected: {expected_hash}")
                    print(f"  Got: {prev_hash}")
                    return STATUS_FAIL
    except FileNotFoundError:
        pass  # audit_roots.log chưa tồn tại, bỏ qua kiểm tra truncation
    
    print(f"✓ Audit log valid ({len(lines)} entries)")
    return STATUS_OK

def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command")

    b = sub.add_parser("backup")
    b.add_argument("source")
    b.add_argument("--label", required=True)

    v = sub.add_parser("verify")
    v.add_argument("snapshot")

    r = sub.add_parser("restore")
    r.add_argument("snapshot")
    r.add_argument("target")
    
    # Lệnh audit-verify
    sub.add_parser("audit-verify")
    
    # Các lệnh phụ khác để test policy
    sub.add_parser("init")
    sub.add_parser("purge")
    ds = sub.add_parser("delete-snapshot")
    ds.add_argument("snapshot")
    sub.add_parser("list-snapshots")

    args = parser.parse_args()

    # Xử lý audit-verify đặc biệt (không cần policy check cho lệnh này trong một số trường hợp)
    if args.command == "audit-verify":
        user = get_current_user()
        policy = Policy()
        audit = AuditLogger("store/audit.log")
        
        print(f"User: {user}")
        
        # Check policy trước
        args_str = args.command
        if not policy.is_allowed(user, args.command):
            audit.log(user, args.command, args_str, STATUS_DENY)
            print("DENY by policy")
            return
        
        # Chạy audit-verify
        status = audit_verify_command("store/audit.log")
        audit.log(user, args.command, args_str, status)
        return

    user = get_current_user()
    policy = Policy()
    audit = AuditLogger("store/audit.log")
    
    print(f"User: {user}")

    # Tạo args_str từ command arguments
    if args.command == "backup":
        args_str = f"{args.source} {args.label}"
    elif args.command == "verify":
        args_str = args.snapshot
    elif args.command == "restore":
        args_str = f"{args.snapshot} {args.target}"
    elif args.command == "delete-snapshot":
        args_str = args.snapshot
    else:
        args_str = args.command

    # Check policy
    if not policy.is_allowed(user, args.command):
        audit.log(user, args.command, args_str, STATUS_DENY)
        print("DENY by policy")
        return

    # Execute command
    if args.command == "backup":
        status = backup(args.source, "store", args.label)
    elif args.command == "verify":
        status = verify(args.snapshot, "store")
    elif args.command == "restore":
        status = restore(args.snapshot, "store", args.target)
    elif args.command == "init":
        print("Init command executed")
        status = STATUS_OK
    elif args.command == "purge":
        print("Purge command executed")
        status = STATUS_OK
    elif args.command == "delete-snapshot":
        print(f"Delete snapshot: {args.snapshot}")
        status = STATUS_OK
    elif args.command == "list-snapshots":
        print("Listing snapshots...")
        status = STATUS_OK
    else:
        print(f"Unknown command: {args.command}")
        return

    audit.log(user, args.command, args_str, status)

if __name__ == "__main__":
    main()