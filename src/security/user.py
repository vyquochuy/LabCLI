import os
import getpass

def get_current_user() -> str:
    if "SUDO_USER" in os.environ:
        return os.environ["SUDO_USER"]
    return getpass.getuser()
