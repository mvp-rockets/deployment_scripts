"""The laptop half's incl.sh: the api's pm2 instance count from PM2_API_INSTANCES (checked by
export_vars), and set_version_metadata, version.txt's metadata in .env.deploy. Sources the real
incl.sh in bash, in a throwaway git repo with node stubbed."""
import json
import os
import re
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]


@pytest.fixture
def repo(tmp_path):
    """A project checkout: scripts/ (SCRIPT_DIR, the real lib/dotenv) and web/package.json."""
    proj = tmp_path / "proj"
    (proj / "web").mkdir(parents=True)
    (proj / "scripts").symlink_to(ROOT)
    (proj / "web" / "package.json").write_text(json.dumps({"name": "web", "version": "1.2.3"}))
    bindir = tmp_path / "bin"
    bindir.mkdir()
    (bindir / "node").write_text("#!/bin/sh\necho v24.22.1\n")
    (bindir / "node").chmod(0o755)
    git = ["git", "-c", "user.email=t@example.com", "-c", "user.name=t", "-c", "commit.gpgsign=false"]
    subprocess.run(["git", "init", "-q", "-b", "main", str(proj)], check=True)
    subprocess.run([*git, "-C", str(proj), "add", "web"], check=True)
    subprocess.run([*git, "-C", str(proj), "commit", "-qm", "init"], check=True)
    return {"proj": proj, "bin": bindir, "tmp": tmp_path}


def bash(repo, script, cwd=None, **env):
    e = {k: v for k, v in os.environ.items() if not k.startswith(("GIT_", "BITBUCKET_", "PM2_"))}
    e.update(PATH=f"{repo['bin']}:{os.environ['PATH']}", SCRIPT_DIR=str(repo["proj"] / "scripts"),
             APP_ENV="qa", PROJECT_NAME="app", REMOTE_USER="deploy", **env)
    return subprocess.run(["bash", "-c", f"source {ROOT}/incl.sh\n{script}"], cwd=cwd or repo["proj"],
                          capture_output=True, text=True, env=e, stdin=subprocess.DEVNULL)


def api_app(repo, **env):
    r = bash(repo, 'PROJECT_TYPE=typescript ROOT_DEPLOYMENT_DIR=/r build_pm2_json api app-qa-api api', **env)
    assert r.returncode == 0, r.stderr
    return json.loads(r.stdout)


def test_api_instances_default_to_two(repo):
    app = api_app(repo)
    assert (app["exec_mode"], app["instances"]) == ("cluster", 2)


def test_api_instances_from_pm2_api_instances(repo):
    assert api_app(repo, PM2_API_INSTANCES="1")["instances"] == 1
    assert api_app(repo, PM2_API_INSTANCES="4")["instances"] == 4


def test_other_services_ignore_pm2_api_instances(repo):
    r = bash(repo, "PROJECT_TYPE=typescript ROOT_DEPLOYMENT_DIR=/r build_pm2_json sqs app-qa-sqs api",
             PM2_API_INSTANCES="1")
    assert "instances" not in json.loads(r.stdout)


@pytest.mark.parametrize("value", ["0", "two", "1.5", "-1", "2 "])
def test_export_vars_refuses_a_bad_instance_count(repo, value):
    r = bash(repo, "export_vars; echo reached", PM2_API_INSTANCES=value)
    assert r.returncode == 1 and "reached" not in r.stdout
    assert "PM2_API_INSTANCES in env/.env.qa must be a whole number of 1 or more" in r.stdout


@pytest.mark.parametrize("value", ["", "1", "12"])
def test_export_vars_takes_a_good_or_unset_count(repo, value):
    r = bash(repo, "export_vars; echo reached", PM2_API_INSTANCES=value)
    assert r.returncode == 0 and "reached" in r.stdout, r.stdout + r.stderr


def version_metadata(repo, **env):
    f = repo["tmp"] / ".env.deploy"
    f.write_text("GIT_COMMIT=x\n")
    r = bash(repo, f"set_version_metadata {f}", cwd=repo["proj"] / "web", **env)
    assert r.returncode == 0, r.stdout + r.stderr
    keys = ["APP_VERSION", "GIT_COMMIT_FULL", "GIT_TAG", "BUILD_ID", "BUILD_TIME", "BUILD_NODE_VERSION"]
    out = subprocess.run(["bash", "-c", f"set -a; source {f}; " + "; ".join(f'echo "{k}=${k}"' for k in keys)],
                         capture_output=True, text=True, check=True).stdout
    return dict(ln.split("=", 1) for ln in out.splitlines())


def test_version_metadata_in_a_pipeline(repo):
    head = subprocess.run(["git", "-C", str(repo["proj"]), "rev-parse", "HEAD"], capture_output=True,
                          text=True, check=True).stdout.strip()
    subprocess.run(["git", "-C", str(repo["proj"]), "tag", "v1.2.3"], check=True)
    m = version_metadata(repo, BITBUCKET_BUILD_NUMBER="77")
    assert {k: m[k] for k in ("APP_VERSION", "GIT_COMMIT_FULL", "GIT_TAG", "BUILD_ID", "BUILD_NODE_VERSION")} == \
        {"APP_VERSION": "1.2.3", "GIT_COMMIT_FULL": head, "GIT_TAG": "v1.2.3", "BUILD_ID": "bitbucket-77",
         "BUILD_NODE_VERSION": "v24.22.1"}
    assert re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", m["BUILD_TIME"])


def test_version_metadata_from_a_laptop_without_a_tag_or_version(repo):
    (repo["proj"] / "web" / "package.json").write_text('{"name": "web"}')
    m = version_metadata(repo)
    assert (m["APP_VERSION"], m["GIT_TAG"]) == ("unknown", "none")
    assert re.fullmatch(r"deploy-\d{8}T\d{6}Z", m["BUILD_ID"])


def test_deploy_static_writes_the_metadata_after_the_build():
    text = (ROOT / "deploy-static.sh").read_text()
    assert text.index("npm run build") < text.index("set_version_metadata") < text.index("static_service.sh\"")
