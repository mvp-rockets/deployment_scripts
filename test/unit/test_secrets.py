"""Unit tests for secrets.sh: a project's secret values and generated manifest.
Each runs the real script in a fake project with `aws` stubbed by a small Secrets Manager kept
in a JSON file: versions, AWSCURRENT, a container with no value yet, a concurrent write. The
stub records every argv, so a test can check that no value ever reaches a command line."""
import json
import os
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "secrets.sh"

AWS_STUB = r'''#!/usr/bin/env python3
import json, os, sys, uuid
store_path = os.environ["STUB_STORE"]
store = json.load(open(store_path))
with open(os.environ["STUB_LOG"], "a") as log:
    log.write(json.dumps(sys.argv[1:]) + "\n")
args = sys.argv[1:]
op = args[1]
if op == "get-caller-identity":
    acct = os.environ.get("STUB_ACCOUNT", "384002304536")
    print(json.dumps({"Account": acct, "Arn": "arn:aws:sts::" + acct + ":assumed-role/AWSReservedSSO_Admin/dev@napses.com"}))
    sys.exit(0)
sid = args[args.index("--secret-id") + 1]
s = store.get(sid)
if s is None:
    sys.stderr.write("ResourceNotFoundException: no secret " + sid + "\n"); sys.exit(254)
def save():
    json.dump(store, open(store_path, "w"))
if op == "get-secret-value":
    if not s["current"]:
        sys.stderr.write("ResourceNotFoundException: no AWSCURRENT version\n"); sys.exit(254)
    print(json.dumps({"ARN": s["arn"], "VersionId": s["current"], "SecretString": s["versions"][s["current"]]}))
elif op == "describe-secret":
    if os.environ.get("STUB_BUMP_ON_DESCRIBE"):  # someone else writes between read and write
        vid = str(uuid.uuid4()); s["versions"][vid] = json.dumps({"OTHER": "x"}); s["current"] = vid; save()
    stages = {vid: (["AWSCURRENT"] if vid == s["current"] else ["AWSPREVIOUS"]) for vid in s["versions"]}
    print(json.dumps({"ARN": s["arn"], "VersionIdsToStages": stages}))
elif op == "put-secret-value":
    ref = args[args.index("--secret-string") + 1]
    assert ref.startswith("file://"), "value passed on argv"
    vid = str(uuid.uuid4()); s["versions"][vid] = open(ref[7:]).read(); s["current"] = vid; save()
    print(json.dumps(vid))
else:
    sys.exit(2)
'''

MANIFEST = {"api": ["DB_HOST", "DB_PASSWORD", "QUEUE_URL"], "postiz": ["POSTIZ_KEY"]}
ARN = "arn:aws:secretsmanager:ap-south-1:384002304536:secret:app-qa-api-AbCdEf"


@pytest.fixture
def proj(tmp_path):
    root = tmp_path / "proj"
    (root / "scripts" / "env").mkdir(parents=True)
    shutil.copy(SCRIPT, root / "scripts" / "secrets.sh")
    (root / "services.json").write_text(json.dumps({"projectName": "app", "services": []}))
    (root / "scripts" / "secrets-manifest.json").write_text(json.dumps(MANIFEST))
    bindir = tmp_path / "bin"
    bindir.mkdir()
    (bindir / "aws").write_text(AWS_STUB)
    (bindir / "aws").chmod(0o755)
    tmpdir = tmp_path / "tmpdir"
    tmpdir.mkdir()
    store = tmp_path / "store.json"
    put_store(store, {"app-qa-api": {"DB_HOST": "h", "DB_PASSWORD": "old-pw", "QUEUE_URL": "q"},
                      "app-prod-api": {"DB_HOST": "h", "QUEUE_URL": "q", "SENTRY_DSN": "s"},
                      "app-qa-postiz": {"POSTIZ_KEY": "pk"}})
    return {"root": root, "bin": bindir, "store": store, "log": tmp_path / "aws.log", "tmpdir": tmpdir}


def put_store(path, secrets, empty=()):
    store = {sid: {"arn": ARN.replace("app-qa-api", sid), "current": "v1", "versions": {"v1": json.dumps(v)}}
             for sid, v in secrets.items()}
    for sid in empty:
        store[sid] = {"arn": ARN.replace("app-qa-api", sid), "current": "", "versions": {}}
    path.write_text(json.dumps(store))


def secret(proj, sid="app-qa-api"):
    s = json.loads(proj["store"].read_text())[sid]
    return json.loads(s["versions"][s["current"]]) if s["current"] else None


def versions(proj, sid="app-qa-api"):
    return len(json.loads(proj["store"].read_text())[sid]["versions"])


def run(proj, *args, stdin="", **extra):
    e = {**os.environ, "PATH": f"{proj['bin']}:{os.environ['PATH']}", "STUB_STORE": str(proj["store"]),
         "STUB_LOG": str(proj["log"]), "TMPDIR": str(proj["tmpdir"]), **extra}
    e.pop("AWS_SM_SECRET_ID", None)
    return subprocess.run(["bash", str(proj["root"] / "scripts" / "secrets.sh"), *args], input=stdin,
                          capture_output=True, text=True, env=e, cwd=proj["root"])


def no_leak(proj, r, *values):
    """No value in the output, in any aws argv, or left in a temp file."""
    argv = proj["log"].read_text() if proj["log"].exists() else ""
    for v in values:
        assert v not in r.stdout + r.stderr
        assert v not in argv
    assert list(proj["tmpdir"].iterdir()) == []


def manifest(proj):
    return json.loads((proj["root"] / "scripts" / "secrets-manifest.json").read_text())


def envfile(proj, text, name="in.env"):
    f = proj["root"].parent / name
    f.write_text(text)
    return f


def test_keys_lists_names_and_how_they_differ_from_the_manifest(proj):
    (proj["root"] / "scripts" / "secrets-manifest.json").write_text(json.dumps({"api": ["DB_HOST", "NEW_KEY"]}))
    r = run(proj, "qa", "keys")
    assert r.returncode == 0, r.stderr
    assert r.stdout.split() == ["DB_HOST", "DB_PASSWORD", "QUEUE_URL"]
    assert "in the manifest, not in app-qa-api (a deploy fails): NEW_KEY" in r.stderr
    assert "in app-qa-api, not in the manifest: DB_PASSWORD QUEUE_URL" in r.stderr
    no_leak(proj, r, "old-pw")


def test_push_adds_and_updates_ignores_empty_values_and_lists_the_keys(proj):
    f = envfile(proj, "# a comment\n\nDB_PASSWORD=new-pw\nexport NEW_KEY='with spaces'\nEMPTY=\nALSO_EMPTY=\"\"\n")
    r = run(proj, "qa", "push", str(f), "--yes")
    assert r.returncode == 0, r.stderr
    assert secret(proj) == {"DB_HOST": "h", "DB_PASSWORD": "new-pw", "QUEUE_URL": "q", "NEW_KEY": "with spaces"}
    assert "ignored (empty): ALSO_EMPTY EMPTY" in r.stdout
    assert "added:   NEW_KEY" in r.stdout and "changed: DB_PASSWORD" in r.stdout and ARN in r.stdout
    assert manifest(proj) == {"api": ["DB_HOST", "DB_PASSWORD", "NEW_KEY", "QUEUE_URL"], "postiz": ["POSTIZ_KEY"]}
    no_leak(proj, r, "new-pw", "old-pw", "with spaces")


def test_push_reads_json_escapes_in_double_quotes_and_crlf(proj):
    f = envfile(proj, 'TLS_KEY="-----BEGIN KEY-----\\nabc\\n-----END KEY-----"\r\nRAW="not json \\d"\r\nURL=http://x?a=b\r\n')
    r = run(proj, "qa", "push", str(f), "--yes")
    assert r.returncode == 0, r.stderr
    s = secret(proj)
    assert s["TLS_KEY"] == "-----BEGIN KEY-----\nabc\n-----END KEY-----"
    assert s["RAW"] == "not json \\d" and s["URL"] == "http://x?a=b"
    no_leak(proj, r, "abc")


def test_push_a_json_file(proj):
    f = envfile(proj, json.dumps({"PORT": 4000, "FLAG": True, "GONE": None, "BLANK": "", "S": "v"}), "in.json")
    r = run(proj, "qa", "push", str(f), "--yes")
    assert r.returncode == 0, r.stderr
    assert {k: secret(proj)[k] for k in ("PORT", "FLAG", "S")} == {"PORT": "4000", "FLAG": "true", "S": "v"}
    assert "GONE" not in secret(proj) and "ignored (empty): BLANK GONE" in r.stdout
    bad = envfile(proj, json.dumps({"bad-name": "x"}), "bad.json")
    assert "aren't [A-Za-z_]" in run(proj, "qa", "push", str(bad), "--yes").stderr


def test_push_to_another_service(proj):
    r = run(proj, "qa", "push", str(envfile(proj, "POSTIZ_KEY=pk2\nPOSTIZ_URL=u\n")), "--service", "postiz", "--yes")
    assert r.returncode == 0, r.stderr
    assert secret(proj, "app-qa-postiz") == {"POSTIZ_KEY": "pk2", "POSTIZ_URL": "u"}
    assert secret(proj)["DB_PASSWORD"] == "old-pw"
    assert manifest(proj)["postiz"] == ["POSTIZ_KEY", "POSTIZ_URL"]


def test_push_with_no_change_writes_nothing_but_lists_the_keys(proj):
    (proj["root"] / "scripts" / "secrets-manifest.json").unlink()
    r = run(proj, "qa", "push", str(envfile(proj, "DB_HOST=h\nQUEUE_URL=q\n")))  # no terminal, no --yes: no write needed
    assert r.returncode == 0, r.stderr
    assert "no change to app-qa-api" in r.stdout and versions(proj) == 1
    assert manifest(proj) == {"api": ["DB_HOST", "QUEUE_URL"]}


def test_a_write_needs_a_terminal_or_yes(proj):
    r = run(proj, "qa", "push", str(envfile(proj, "DB_PASSWORD=new-pw\n")))
    assert r.returncode == 1 and "pass --yes" in r.stderr
    assert versions(proj) == 1 and manifest(proj) == MANIFEST


def test_a_concurrent_write_fails_and_writes_nothing(proj):
    r = run(proj, "qa", "push", str(envfile(proj, "NEW_KEY=v\n")), "--yes", STUB_BUMP_ON_DESCRIBE="1")
    assert r.returncode == 1 and "changed since it was read" in r.stderr
    assert secret(proj) == {"OTHER": "x"} and manifest(proj) == MANIFEST


def test_push_into_a_container_with_no_value_yet(proj):
    put_store(proj["store"], {}, empty=["app-qa-api"])
    r = run(proj, "qa", "push", str(envfile(proj, "DB_HOST=h\n")), "--yes")
    assert r.returncode == 0, r.stderr
    assert secret(proj) == {"DB_HOST": "h"}


def test_adr_0020_manifest_is_rewritten_in_the_new_form(proj):
    old = {"services": {"api": {"required": ["DB_HOST"], "optional": ["SENTRY_DSN"]}, "sqs": {"required": ["Q"]}}}
    (proj["root"] / "scripts" / "secrets-manifest.json").write_text(json.dumps(old))
    assert run(proj, "qa", "push", str(envfile(proj, "DB_PASSWORD=p\n")), "--yes").returncode == 0
    assert manifest(proj) == {"api": ["DB_HOST", "DB_PASSWORD"], "sqs": ["Q"]}


def test_delete_removes_keys_from_the_secret_and_the_list(proj):
    r = run(proj, "qa", "delete", "QUEUE_URL", "--yes")
    assert r.returncode == 0, r.stderr
    assert secret(proj) == {"DB_HOST": "h", "DB_PASSWORD": "old-pw"} and "removed: QUEUE_URL" in r.stdout
    assert manifest(proj)["api"] == ["DB_HOST", "DB_PASSWORD"]
    r = run(proj, "qa", "delete", "NOPE", "--yes")
    assert r.returncode == 1 and "not in app-qa-api or the manifest: NOPE" in r.stderr


def test_export_then_push_back_is_no_change(proj):
    pem = "-----BEGIN KEY-----\nabc\n-----END KEY-----"
    run(proj, "qa", "push", str(envfile(proj, f"TLS_KEY={json.dumps(pem)}\nODD=a b\"c\n")), "--yes")
    out = proj["root"].parent / "qa.env"
    r = run(proj, "qa", "export", str(out))
    assert r.returncode == 0, r.stderr
    assert out.stat().st_mode & 0o777 == 0o600 and "DB_HOST=h\n" in out.read_text()
    r = run(proj, "qa", "push", str(out))
    assert r.returncode == 0 and "no change to app-qa-api" in r.stdout, r.stdout + r.stderr
    assert "exists" in run(proj, "qa", "export", str(out)).stderr
    no_leak(proj, r, "old-pw", "abc")


def test_export_json(proj):
    out = proj["root"].parent / "qa.json"
    assert run(proj, "qa", "export", str(out)).returncode == 0
    assert json.loads(out.read_text()) == secret(proj)


def test_diff_names_keys_in_one_environment_only(proj):
    r = run(proj, "qa", "diff", "prod")
    assert r.returncode == 0, r.stderr
    assert "only in qa: DB_PASSWORD" in r.stdout and "only in prod: SENTRY_DSN" in r.stdout
    no_leak(proj, r, "old-pw")


def test_the_api_secret_id_from_the_env_file(proj):
    (proj["root"] / "scripts" / "env" / ".env.qa").write_text('AWS_SM_SECRET_ID="app-prod-api"\n')
    assert "SENTRY_DSN" in run(proj, "qa", "keys").stdout
    assert run(proj, "qa", "keys", "--service", "postiz").stdout.split() == ["POSTIZ_KEY"]


def test_no_secret_is_an_error(proj):
    r = run(proj, "uat", "keys")
    assert r.returncode == 1 and "can't read app-uat-api" in r.stderr


# reload goes through the project's real incl.sh (load_vars, export_vars, sync, run_remote) with
# REMOTE_TYPE=ssh; ssh and rsync are stubs that record their arguments.
NET_STUB = '#!/bin/sh\necho "$(basename "$0") $*" >> "$STUB_NET_LOG"\n'


def test_reload_runs_the_remote_script_over_the_deploys_ssh(proj, tmp_path):
    scripts = proj["root"] / "scripts"
    r = run(proj, "qa", "reload", "--yes")
    assert r.returncode == 1 and "reload_secrets.sh" in r.stderr  # a project copy without it
    shutil.copy(ROOT / "incl.sh", scripts / "incl.sh")
    shutil.copytree(ROOT / "remote", scripts / "remote")
    (scripts / "env" / ".env.qa").write_text(
        "PROJECT_NAME=app\nREMOTE_TYPE=ssh\nREMOTE_USER=deploy\nSERVER_NAME=qa2\nIDENTITY_FILE=key.pem\n")
    for name in ("ssh", "rsync"):
        (proj["bin"] / name).write_text(NET_STUB)
        (proj["bin"] / name).chmod(0o755)
    subprocess.run(["git", "init", "-q"], cwd=proj["root"], check=True)  # export_vars reads the commit
    subprocess.run(["git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "x"],
                   cwd=proj["root"], check=True)
    net = tmp_path / "net.log"
    assert "pass --yes" in run(proj, "qa", "reload", STUB_NET_LOG=str(net)).stderr and not net.exists()
    r = run(proj, "qa", "reload", "--service", "postiz", "--yes", STUB_NET_LOG=str(net))
    assert r.returncode == 0, r.stdout + r.stderr
    rsync, rsync2, ssh = net.read_text().splitlines()
    remote = "deploy@qa2:/home/deploy/apps/app/qa"
    assert rsync.endswith(f" {remote}/postiz/")  # the libraries reload_secrets.sh sources, as a deploy syncs them
    for lib in ("events.sh", "health.sh", "secrets_manifest.sh"):
        assert f"{scripts}/remote/common/{lib} " in rsync
    assert rsync2.endswith(f"{proj['root']}/scripts/remote/current/reload_secrets.sh {remote}/postiz/current/")
    assert f"-i {scripts}/key.pem -o IdentitiesOnly=yes" in rsync
    assert ssh.startswith("ssh -i") and ssh.endswith("deploy@qa2 cd /home/deploy/apps/app/qa/postiz/current; ./reload_secrets.sh")
    assert not (proj["log"].exists() and proj["log"].read_text())  # no AWS call: the host reads the secret
