"""static_service.sh: dist/version.txt written from .env.deploy, the sync to /var/www without sudo,
and the health gate (a version.txt URL must show the release's commit) with its rollback. Runs the
real script in test_remote_secrets.py's fake ~/apps layout; curl prints STUB_BODY's file, standing
in for what nginx would serve."""
import os
import re
import shutil

from test_remote_secrets import REMOTE, calls, env, events, make_release, run  # noqa: F401 (env: fixture)

CURL = ('#!/bin/bash\nfor a; do last=$a; done\nif [ "$last" = "$DORA_WEBHOOK_URL" ]; then exit 0; fi\n'
        'echo "curl $*" >> "$STUB_LOG"\n'
        '[ "$STUB_HEALTH" = ok ] || exit 22\n[ -n "$STUB_BODY" ] && { cat "$STUB_BODY" || exit 22; }\nexit 0\n')

VERSION_META = {"APP_VERSION": "1.4.0", "GIT_TAG": "none", "BUILD_ID": "bitbucket-77",
                "BUILD_TIME": "2026-11-11T10:00:00Z", "BUILD_NODE_VERSION": "v24.22.1"}


def static_release(env, sha, www, health_url="https://web.test/version.txt", meta=True, history=()):
    """A release of static service `web` (dist/index.html), its /var/www directory and the
    service's deployment_history; .env.deploy as deploy-static.sh writes it; `current` already
    on it, as deploy-static.sh moves it before running the script."""
    (env["bin"] / "curl").write_text(CURL)
    env["svc"] = env["svc"].parent / "web"
    (env["svc"] / "releases").mkdir(parents=True, exist_ok=True)
    for f in (REMOTE / "common").iterdir():
        shutil.copy(f, env["svc"] / f.name)
    extra = {"DEPLOY_SERVICE": "web", "GIT_COMMIT_FULL": (sha * 40)[:40], **(VERSION_META if meta else {})}
    rel = make_release(env, sha, health_url=health_url, deploy_env=extra)
    (rel / "dist").mkdir()
    (rel / "dist" / "index.html").write_text(f"index {sha}\n")
    (www / "app-qa-web").mkdir(parents=True, exist_ok=True)
    if history:
        (env["svc"] / "deployment_history").write_text("".join(f"{h}\n" for h in history))
    (env["svc"] / "current").unlink(missing_ok=True)
    (env["svc"] / "current").symlink_to(rel)
    return rel


def version_txt(path):
    return dict(ln.split("=", 1) for ln in path.read_text().splitlines())


def test_needs_the_server_setups_directory_and_no_sudo(env):
    www = env["tmp"] / "www"
    rel = static_release(env, "abc1234", www, health_url=None)
    shutil.rmtree(www / "app-qa-web")
    r = run(env, rel, "./static_service.sh", STATIC_ROOT=str(www))
    assert r.returncode == 1 and "is missing or not writable" in r.stderr
    assert events(env)[-1]["stage"] == "preflight"
    assert "sudo" not in (REMOTE / "current" / "static_service.sh").read_text().replace("without sudo", "")


def test_writes_version_txt_and_waits_for_its_commit(env):
    www = env["tmp"] / "www"
    rel = static_release(env, "abc1234", www)
    served = www / "app-qa-web" / "version.txt"
    r = run(env, rel, "./static_service.sh", STATIC_ROOT=str(www), STUB_BODY=str(served))
    assert r.returncode == 0, r.stdout + r.stderr
    assert (www / "app-qa-web" / "index.html").read_text() == "index abc1234\n"
    v = version_txt(served)
    assert v == version_txt(rel / "dist" / "version.txt")   # the release keeps its own, for a rollback
    assert {k: v[k] for k in ("version", "tag", "commit", "commitShort", "branch", "buildId", "buildTime",
                              "env", "nodeVersion")} == {
        "version": "1.4.0", "tag": "none", "commit": ("abc1234" * 40)[:40], "commitShort": "abc1234",
        "branch": "main", "buildId": "bitbucket-77", "buildTime": "2026-11-11T10:00:00Z", "env": "qa",
        "nodeVersion": "v24.22.1"}
    assert re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", v["deployTime"])
    assert "build-42" not in served.read_text()   # DEPLOY_TRIGGER (an email on a laptop) isn't published
    assert oct(served.stat().st_mode & 0o777) == "0o644"
    assert any("Cache-Control: no-cache" in c and "https://web.test/version.txt" in c for c in calls(env))
    end = events(env)[-1]
    assert (end["event"], end["result"], end["health"], end["service"]) == ("deploy_end", "success", "pass", "web")


def test_version_txt_from_an_older_laptop_half(env):
    """.env.deploy without set_version_metadata's keys: the short commit and 'unknown'."""
    www = env["tmp"] / "www"
    rel = static_release(env, "abc1234", www, health_url=None, meta=False)
    r = run(env, rel, "./static_service.sh", STATIC_ROOT=str(www))
    assert r.returncode == 0, r.stderr
    v = version_txt(www / "app-qa-web" / "version.txt")
    assert (v["commit"], v["version"], v["tag"], v["buildId"], v["nodeVersion"]) == \
        (("abc1234" * 40)[:40], "unknown", "none", "unknown", "unknown")
    assert events(env)[-1]["health"] == "skipped"
    assert not any(c.startswith("curl") for c in calls(env))


def test_rolls_back_when_version_txt_shows_another_commit(env):
    www = env["tmp"] / "www"
    old = static_release(env, "0ld0000", www, health_url=None)
    assert run(env, old, "./static_service.sh", STATIC_ROOT=str(www)).returncode == 0
    stale = env["tmp"] / "stale.txt"   # a cache or another host still serving the old build
    stale.write_text((www / "app-qa-web" / "version.txt").read_text())
    rel = static_release(env, "abc1234", www, history=["0ld0000"])
    r = run(env, rel, "./static_service.sh", STATIC_ROOT=str(www), STUB_BODY=str(stale))
    assert r.returncode == 1
    assert "health check failed (https://web.test/version.txt): rolling back to 0ld0000" in r.stderr
    assert (www / "app-qa-web" / "index.html").read_text() == "index 0ld0000\n"
    assert version_txt(www / "app-qa-web" / "version.txt")["commitShort"] == "0ld0000"
    assert os.readlink(env["svc"] / "current") == str(env["svc"] / "releases" / "0ld0000")
    ev = events(env)
    assert [e["event"] for e in ev[-3:]] == ["health_check", "rollback", "deploy_end"]
    assert ev[-2]["to_sha"] == "0ld0000"
    assert (ev[-1]["result"], ev[-1]["stage"], ev[-1]["rolled_back"]) == ("failure", "health", "true")


def test_fails_without_a_previous_release(env):
    www = env["tmp"] / "www"
    rel = static_release(env, "abc1234", www, history=["abc1234"])   # only itself: nothing to go back to
    r = run(env, rel, "./static_service.sh", STATIC_ROOT=str(www), STUB_HEALTH="down")
    assert r.returncode == 1 and "no previous release to roll back to" in r.stderr
    assert os.readlink(env["svc"] / "current") == str(rel)
    end = events(env)[-1]
    assert (end["result"], end["stage"], end["rolled_back"]) == ("failure", "health", "false")


def test_another_health_url_needs_only_a_2xx(env):
    www = env["tmp"] / "www"
    rel = static_release(env, "abc1234", www, health_url="https://web.test/")
    r = run(env, rel, "./static_service.sh", STATIC_ROOT=str(www))
    assert r.returncode == 0, r.stderr
    assert events(env)[-1]["health"] == "pass"
