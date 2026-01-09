import argparse

from utils import STATUS_DENY
from core import backup, verify, restore
from security import get_current_user, Policy, AuditLogger

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
    
    # Các lệnh phụ khác để phục vụ các bài test
    sub.add_parser("init")           # Phục vụ Test 14
    sub.add_parser("audit-verify")   # Phục vụ Test 13
    sub.add_parser("delete-snapshot").add_argument("snapshot")

    args = parser.parse_args()

    user = get_current_user()
    policy = Policy()
    audit = AuditLogger("store/audit.log")
    print("DEBUG USER =", user)

    args_str = " ".join(vars(args).values())

    if not policy.is_allowed(user, args.command):
        audit.log(user, args.command, args_str, STATUS_DENY)
        print("DENY by policy")
        return

    if args.command == "backup":
        status = backup(args.source, "store", args.label)
    elif args.command == "verify":
        status = verify(args.snapshot, "store")
    elif args.command == "restore":
        status = restore(args.snapshot, "store", args.target)
    else:
        return

    audit.log(user, args.command, args_str, status)

if __name__ == "__main__":
    main()


#cli.py