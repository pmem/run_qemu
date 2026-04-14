# /// script
# requires-python = ">=3.10"
# dependencies = [
#     "mcp>=1.0",
# ]
# ///
"""run_qemu MCP Server — tools for building kernels and managing QEMU VMs.

Wraps run_qemu.sh to provide structured, agent-friendly VM lifecycle
management: start, stop, status, run commands, read logs.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

# When running as __main__, alias this module as "server" so that
# `from server import mcp` in tool modules gets THIS module's mcp
# instance rather than re-importing server.py as a separate module.
if __name__ == "__main__":
    sys.modules["server"] = sys.modules[__name__]

from mcp.server.fastmcp import FastMCP

mcp = FastMCP("run-qemu")

# Import tool modules — they register tools via `from server import mcp`
import tools.lifecycle  # noqa: F401
import tools.execute  # noqa: F401
import tools.observe  # noqa: F401

if __name__ == "__main__":
    mcp.run()
