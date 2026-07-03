"""pytest fixtures + path setup for worker module tests."""
from __future__ import annotations

import sys
from pathlib import Path

# Add the worker dir to sys.path so `import frames` / `import captions` works
# without packaging.
ROOT = Path(__file__).resolve().parents[2]
WORKER = ROOT / "plugins" / "watch-local" / "scripts" / "worker"
sys.path.insert(0, str(WORKER))
