"""The cluster-mode .nvmrc check (remote/common/pm2_node.sh) in init_api.sh and
start_service.sh: pm2 cluster mode runs every worker on pm2's own Node, so a cluster-mode app
whose .nvmrc names another version is refused before anything changes. Runs the real scripts in
test_remote_secrets.py's fake ~/apps layout."""
import json
import os
import subprocess

import pytest

from test_remote_secrets import calls, env, events, make_release, run  # noqa: F401 (env: fixture)


def cluster_release(env, sha, nvmrc, exec_mode="cluster"):
    rel = make_release(env, sha)
    apps = [{"name": "app-api", "script": "build/src/main.js", "exec_mode": exec_mode, "instances": 2}]
    (rel / "deploy.config.json").write_text(json.dumps({"apps": apps}))
    if nvmrc is not None:
        (rel / ".nvmrc").write_text(nvmrc + "\n")
    return rel


@pytest.mark.parametrize("nvmrc, exec_mode, ok", [
    ("v24.11.0", "cluster", True),     # the node stub (no pm2 daemon) prints v24.11.0
    ("24", "cluster", True),           # a major-only .nvmrc matches any 24.x
    ("24.11", "cluster_mode", True),
    ("20.12.2", "cluster", False),
    ("lts/*", "cluster", False),       # an alias can't be compared
    ("20.12.2", "fork", True),         # fork mode honours its own Node
    (None, "cluster", True),           # no .nvmrc: nothing declared
], ids=["exact", "major", "minor", "differs", "alias", "fork", "no-nvmrc"])
def test_cluster_mode_nvmrc_must_be_pm2s_node(env, nvmrc, exec_mode, ok):
    rel = cluster_release(env, "sha1", nvmrc, exec_mode)
    r = run(env, rel, "./init_api.sh")
    assert (r.returncode == 0) is ok, r.stdout + r.stderr
    if not ok:
        assert f"runs app-api on pm2's Node 24.11.0, but .nvmrc says {nvmrc.lstrip('v')}" in r.stderr
        assert "set .nvmrc to 24.11.0" in r.stderr and "fork mode" in r.stderr
        assert not (rel / "node_modules").exists() and not any(c.startswith(("npm", "aws")) for c in calls(env))
        end = events(env)[-1]
        assert (end["event"], end["result"], end["stage"]) == ("deploy_end", "failure", "preflight")


def test_start_service_refuses_the_mismatch_before_switching(env):
    old = make_release(env, "sha1")
    (env["svc"] / "current").symlink_to(old)
    r = run(env, cluster_release(env, "sha2", "20.12.2"), "./start_service.sh")
    assert r.returncode == 1 and "but .nvmrc says 20.12.2" in r.stderr
    assert os.readlink(env["svc"] / "current") == str(old)
    assert not any(c.startswith("pm2 startOrRestart") for c in calls(env))
    assert events(env)[-1]["stage"] == "preflight"


def test_pm2s_node_is_the_running_daemons(env):
    """With a live pid in pm2.pid, its binary is asked (here a python3 standing in for the
    daemon), not the node on PATH; a stale pid falls back to PATH."""
    rel = cluster_release(env, "sha1", "24.11.0")
    pidfile = env["home"] / ".pm2" / "pm2.pid"
    pidfile.parent.mkdir(parents=True, exist_ok=True)
    daemon = subprocess.Popen(["python3", "-c", "import time; time.sleep(30)"])
    try:
        pidfile.write_text(str(daemon.pid))
        r = run(env, rel, "./init_api.sh")
        assert r.returncode == 1 and "on pm2's Node Python 3." in r.stderr
    finally:
        daemon.kill()
        daemon.wait()
    r = run(env, cluster_release(env, "sha2", "24.11.0"), "./init_api.sh")
    assert r.returncode == 0, r.stderr
