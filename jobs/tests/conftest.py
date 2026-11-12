import importlib.util
import sys
from pathlib import Path

# The job is one script (serverless cannot import a sibling module); load it
# as a module for the tests.
_path = Path(__file__).resolve().parents[1] / "patch_desk_job.py"
_spec = importlib.util.spec_from_file_location("patch_desk_job", _path)
patch_desk_job = importlib.util.module_from_spec(_spec)
sys.modules["patch_desk_job"] = patch_desk_job
_spec.loader.exec_module(patch_desk_job)
