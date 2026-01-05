import yaml

class Policy:
    def __init__(self, path="policy.yaml"):
        with open(path, "r") as f:
            data = yaml.safe_load(f)
        self.users = data.get("users", {})
        self.roles = data.get("roles", {})

    def is_allowed(self, user: str, command: str) -> bool:
        role = self.users.get(user)
        if not role:
            return False
        return command in self.roles.get(role, [])
