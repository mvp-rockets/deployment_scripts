"""The remote half's secrets: init_api.sh's check against secrets-manifest.json before
load-secrets, and reload_secrets.sh (`secrets.sh <env> reload`). Each runs the real script in a
fake ~/apps layout with pm2, curl, npm and aws stubbed; node_modules comes from the real
nm_store through a stubbed `npm ci`."""
import json
import os
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
REMOTE = ROOT / "remote"

STUBS = {
    # pm2: record the call; jlist prints STUB_JLIST (default: none, like the default empty dump)
    "pm2": '#!/bin/sh\necho "pm2 $* (in $(pwd -P))" >> "$STUB_LOG"\n[ "$1" = jlist ] && echo "${STUB_JLIST:-[]}"\nexit 0\n',
    # curl: the health URL answers per STUB_HEALTH; webhook POSTs are recorded
    "curl": '#!/bin/bash\nfor a; do last=$a; done\nif [ "$last" = "$DORA_WEBHOOK_URL" ]; then echo "webhook $*" >> "$STUB_LOG"; exit 0; fi\n'
            '[ "$STUB_HEALTH" = ok ] && exit 0; exit 22\n',
    # npm: ci makes a node_modules; run <script> is recorded
    "npm": '#!/bin/bash\nif [ "$1" = ci ]; then mkdir -p node_modules/pkg && echo x > node_modules/pkg/index.js; exit 0; fi\n'
           'echo "npm $*" >> "$STUB_LOG"\n',
    "aws": '#!/bin/sh\necho "aws $*" >> "$STUB_LOG"\ncat "$STUB_SECRET"\n',
    "node": "#!/bin/sh\necho v24.11.0\n",
}

MANIFEST = {"api": ["DB_HOST", "DB_PASSWORD"], "postiz": ["POSTIZ_KEY"]}  # ADR 0053's generated form


@pytest.fixture
def env(tmp_path):
    home = tmp_path / "home"
    svc = home / "apps" / "app" / "qa" / "api"
    (svc / "releases").mkdir(parents=True)
    for f in (REMOTE / "common").iterdir():
        shutil.copy(f, svc / f.name)
    bindir = tmp_path / "bin"
    bindir.mkdir()
    for name, body in STUBS.items():
        (bindir / name).write_text(body)
        (bindir / name).chmod(0o755)
    secret = tmp_path / "secret.json"
    secret.write_text(json.dumps({"DB_HOST": "h", "DB_PASSWORD": "p", "QUEUE_URL": "q"}))
    return {"home": home, "svc": svc, "bin": bindir, "log": tmp_path / "stub.log",
            "events": tmp_path / "events.jsonl", "secret": secret, "tmp": tmp_path}


def make_release(env, sha, manifest=MANIFEST, health_url="http://127.0.0.1:4000/api/healthz"):
    rel = env["svc"] / "releases" / sha
    rel.mkdir()
    for f in (REMOTE / "current").iterdir():
        shutil.copy(f, rel / f.name)
    (rel / "package.json").write_text('{"name": "app"}')
    (rel / "package-lock.json").write_text('{"lockfileVersion": 3}')
    (rel / "tsconfig.json").write_text("{}")
    (rel / "deploy.config.json").write_text('{"apps": []}')
    if manifest is not None:
        (rel / "secrets-manifest.json").write_text(json.dumps(manifest))
    lines = {"PROJECT_NAME": "app", "APP_ENV": "qa", "DEPLOY_SERVICE": "api", "GIT_COMMIT": sha,
             "GIT_BRANCH": "main", "DEPLOY_TRIGGER": "build-42", "ROOT_DEPLOYMENT_DIR": str(env["svc"].parent),
             "DEPLOYMENT_DIR": str(rel), "AWS_SM_SECRET_ID": "app-qa-api"}
    if health_url:
        lines["HEALTH_URL"] = health_url
    (rel / ".env.deploy").write_text("".join(f"{k}={v}\n" for k, v in lines.items()))
    return rel


def run(env, cwd, script, dump="[]", **extra):  # dump: ~/.pm2/dump.pm2's content, None for no file
    e = {**os.environ, "HOME": str(env["home"]), "PATH": f"{env['bin']}:{os.environ['PATH']}",
         "STUB_LOG": str(env["log"]), "STUB_SECRET": str(env["secret"]), "STUB_HEALTH": "ok",
         "NAPSES_DEPLOY_EVENTS": str(env["events"]), "HEALTH_TIMEOUT": "2", "HEALTH_INTERVAL": "0.2", **extra}
    (env["home"] / ".pm2").mkdir(exist_ok=True)
    dump_file = env["home"] / ".pm2" / "dump.pm2"
    if dump is None:
        dump_file.unlink(missing_ok=True)
    else:
        dump_file.write_text(dump)
    return subprocess.run(["bash", script], cwd=cwd, capture_output=True, text=True, env=e, stdin=subprocess.DEVNULL)


def events(env):
    return [json.loads(ln) for ln in env["events"].read_text().splitlines()] if env["events"].exists() else []


def calls(env):
    return env["log"].read_text().splitlines() if env["log"].exists() else []


def test_init_api_uses_the_store_checks_secrets_then_loads_them(env):
    rel = make_release(env, "sha1")
    r = run(env, rel, "./init_api.sh")
    assert r.returncode == 0, r.stdout + r.stderr
    assert (rel / "node_modules" / "pkg" / "index.js").exists() and (rel / ".nm-store-key").exists()
    assert "secrets manifest: ok (api)" in r.stdout
    assert [c.split()[1] for c in calls(env) if c.startswith(("aws", "npm"))][:2] == ["secretsmanager", "run"]
    assert "npm run load-secrets" in calls(env)
    assert [e["event"] for e in events(env)] == ["deploy_start"]
    start = events(env)[0]
    assert (start["app"], start["env"], start["service"], start["sha"], start["branch"], start["trigger"]) == \
        ("app", "qa", "api", "sha1", "main", "build-42")


def test_missing_required_secret_fails_before_load_secrets(env):
    env["secret"].write_text(json.dumps({"DB_HOST": "h"}))
    rel = make_release(env, "sha1")
    r = run(env, rel, "./init_api.sh")
    assert r.returncode != 0
    assert "keys missing from the secret for api: DB_PASSWORD" in r.stderr
    assert "npm run load-secrets" not in calls(env)
    end = events(env)[-1]
    assert (end["event"], end["result"], end["stage"]) == ("deploy_end", "failure", "init")
    assert isinstance(end["duration_s"], int)


def test_unlisted_secret_keys_only_warn(env):
    env["secret"].write_text(json.dumps({"DB_HOST": "h", "DB_PASSWORD": "p", "OLD_AWS_KEY": "k"}))
    for sha in ("sha1", "sha2"):
        r = run(env, make_release(env, sha), "./init_api.sh")
        assert r.returncode == 0, r.stderr
        assert "WARNING: keys in the secret that api's list doesn't name: OLD_AWS_KEY" in r.stderr


def test_a_service_without_a_list_is_not_checked(env):
    r = run(env, make_release(env, "sha1", manifest={"postiz": ["POSTIZ_KEY"]}), "./init_api.sh")
    assert r.returncode == 0 and "no key list for 'api'" in r.stderr
    assert "npm run load-secrets" in calls(env)


def test_adr_0020_manifest_is_read_as_its_required_keys(env):
    old = {"services": {"api": {"required": ["DB_HOST", "MISSING_ONE"], "optional": ["SENTRY_DSN"]}}}
    r = run(env, make_release(env, "sha1", manifest=old), "./init_api.sh")
    assert r.returncode != 0 and "for api: MISSING_ONE" in r.stderr and "SENTRY_DSN" not in r.stderr


def test_no_manifest_warns_and_continues(env):
    r = run(env, make_release(env, "sha1", manifest=None), "./init_api.sh")
    assert r.returncode == 0 and "secrets manifest: none at" in r.stderr
    assert not any(c.startswith("aws") for c in calls(env))


# --- reload_secrets.sh: `secrets.sh <env> reload` in the live release (ADR 0053) ---

def live_release(env, health="ok"):
    rel = make_release(env, "sha1")
    (env["svc"] / "current").symlink_to(rel)
    (rel / ".env").write_text("DB_PASSWORD=old\n")
    # load-secrets writes the new values; STUB_LOAD=fail makes it fail half-way
    (env["bin"] / "npm").write_text(
        '#!/bin/bash\necho "npm $*" >> "$STUB_LOG"\n'
        'if [ "$2" = load-secrets ]; then echo DB_PASSWORD=new > .env; echo X=1 > .env.qa; [ "$STUB_LOAD" != fail ]; fi\n')
    return rel


def reload(env, **extra):
    return run(env, env["svc"] / "current", "./reload_secrets.sh", **extra)


def test_reload_checks_loads_reloads_and_passes_the_health_gate(env):
    rel = live_release(env)
    r = reload(env)
    assert r.returncode == 0, r.stdout + r.stderr
    assert (rel / ".env").read_text() == "DB_PASSWORD=new\n" and (rel / ".env.qa").exists()
    seq = [c for c in calls(env) if c.startswith(("aws", "npm", "pm2"))]
    assert [c.split()[0] for c in seq] == ["aws", "npm", "pm2"] and "startOrReload deploy.config.json" in seq[2]
    end = events(env)[-1]
    assert (end["event"], end["outcome"], end["health"]) == ("secrets_reload", "success", "pass")
    assert "result" not in end  # not counted as a deploy


def test_reload_with_a_missing_key_changes_nothing(env):
    rel = live_release(env)
    env["secret"].write_text(json.dumps({"DB_HOST": "h"}))
    r = reload(env)
    assert r.returncode != 0 and "for api: DB_PASSWORD" in r.stderr
    assert not any(c.startswith(("npm", "pm2")) for c in calls(env))
    assert (rel / ".env").read_text() == "DB_PASSWORD=old\n"
    assert (events(env)[-1]["outcome"], events(env)[-1]["stage"]) == ("failure", "check")


@pytest.mark.parametrize("stage, extra", [("health", {"STUB_HEALTH": "down"}), ("load", {"STUB_LOAD": "fail"})])
def test_reload_failure_restores_the_previous_values(env, stage, extra):
    rel = live_release(env)
    r = reload(env, **extra)
    assert r.returncode != 0
    assert (rel / ".env").read_text() == "DB_PASSWORD=old\n" and not (rel / ".env.qa").exists()
    assert any(c.startswith("pm2 startOrReload") for c in calls(env))
    end = events(env)[-1]
    assert (end["event"], end["outcome"], end["stage"], end["restored"]) == ("secrets_reload", "failure", stage, "true")
