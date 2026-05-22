"""Bootstrap hermes-claude-auth without relying on sitecustomize resolution.

Some Python distributions, including Ubuntu's Python 3.12 packages, ship a
global ``sitecustomize.py`` in the standard library.  Python imports only the
first module named ``sitecustomize`` it finds, so a venv-local
``sitecustomize.py`` can be skipped even when it exists.

This module is imported from a ``.pth`` file during ``site`` initialization.
It loads the managed venv ``sitecustomize.py`` by absolute path, avoiding the
module-name collision while keeping the original hook implementation in one
place.
"""

from __future__ import annotations

import os
import runpy
import sys


def _install() -> None:
    if os.environ.get("HERMES_CLAUDE_AUTH_DISABLE"):
        return
    if getattr(sys, "_hermes_claude_auth_bootstrap_loaded", False):
        return

    sys._hermes_claude_auth_bootstrap_loaded = True

    hook_path = os.path.join(os.path.dirname(__file__), "sitecustomize.py")
    if not os.path.exists(hook_path):
        sys.stderr.write(
            "[hermes-claude-auth] managed sitecustomize.py not found; "
            "bootstrap skipped\n"
        )
        return

    try:
        with open(hook_path, "r", encoding="utf-8") as hook_file:
            header = hook_file.read(4096)
        if "# hermes-claude-auth managed" not in header:
            sys.stderr.write(
                "[hermes-claude-auth] sitecustomize.py is not managed by "
                "hermes-claude-auth; bootstrap skipped\n"
            )
            return
        runpy.run_path(hook_path, run_name="_hermes_claude_auth_sitecustomize")
    except Exception as exc:
        sys.stderr.write(
            f"[hermes-claude-auth] bootstrap failed: "
            f"{type(exc).__name__}: {exc}\n"
        )


_install()
