"""The npm scripts preflight (remote/common/npm_scripts.sh): every `npm run` of init_api.sh is
in the service's package.json before anything runs, on the laptop (deploy-api.sh, before the
build and the first sync) and on the host (init_api.sh, before the install and the first
migration). A missing seeder otherwise fails the deploy after the migrations ran. Runs the real
scripts in test_remote_secrets.py's fake ~/apps layout."""
import re

import pytest

from test_remote_secrets import (OLD_SCRIPTS, REMOTE, ROOT, TS_SCRIPTS, calls, env, events,  # noqa: F401 (env: fixture)
                                 make_release, run)


def assert_preflight_failure(env, rel, r):
    assert r.returncode != 0
    assert not (rel / "node_modules").exists() and not any(c.startswith(("npm", "aws")) for c in calls(env))
    end = events(env)[-1]
    assert (end["event"], end["result"], end["stage"]) == ("deploy_end", "failure", "preflight")


@pytest.mark.parametrize("tsconfig, scripts", [(True, TS_SCRIPTS), (False, OLD_SCRIPTS)], ids=["ts", "older"])
def test_init_api_refuses_a_missing_npm_script_before_the_install_and_migrations(env, tsconfig, scripts):
    rel = make_release(env, "sha1", scripts=scripts[:-1], tsconfig=tsconfig)
    r = run(env, rel, "./init_api.sh")
    assert f"npm scripts missing from {rel}/package.json: {scripts[-1]}" in r.stderr
    assert "NPM_SCRIPTS_REQUIRED" in r.stderr
    assert_preflight_failure(env, rel, r)


def test_the_older_template_needs_its_own_scripts(env):
    r = run(env, make_release(env, "sha1", scripts=OLD_SCRIPTS, tsconfig=False), "./init_api.sh")
    assert r.returncode == 0, r.stdout + r.stderr
    assert f"npm scripts: ok ({' '.join(OLD_SCRIPTS)})" in r.stdout
    assert [c for c in calls(env) if c.startswith("npm run")] == [
        "npm run build:env", "npm run db:migrate --env=qa", "npm run db:seed:all --env=qa"]


def test_a_project_with_its_own_init_names_its_scripts(env):
    own = ["load-secrets", "migration:run", "seed:all"]   # a project init_api.sh with its own seeder
    rel = make_release(env, "sha1", scripts=own, deploy_env={"NPM_SCRIPTS_REQUIRED": f"'{' '.join(own)}'"})
    r = run(env, rel, "./init_api.sh")
    assert f"npm scripts: ok ({' '.join(own)})" in r.stdout, r.stdout + r.stderr
    # without the variable the common list applies, and migration:seed is missing
    r = run(env, make_release(env, "sha2", scripts=own), "./init_api.sh")
    assert r.returncode != 0 and "missing from" in r.stderr and "migration:seed" in r.stderr


@pytest.mark.parametrize("package", [None, "not json", '{"scripts": []}'], ids=["none", "not-json", "scripts-not-object"])
def test_an_unreadable_package_json_fails_the_preflight(env, package):
    rel = make_release(env, "sha1")
    if package is None:
        (rel / "package.json").unlink()
    else:
        (rel / "package.json").write_text(package)
    r = run(env, rel, "./init_api.sh")
    assert "is missing or isn't a package.json" in r.stderr
    assert_preflight_failure(env, rel, r)


def test_the_list_is_what_init_api_runs_branch_by_branch():
    """npm_scripts_required and init_api.sh's `npm run` lines stay in step."""
    text = (REMOTE / "current" / "init_api.sh").read_text()
    ts, older = text.split('if [[ -f "$DEPLOYMENT_DIR/tsconfig.json" ]]; then', 1)[1].split("\nelse", 1)
    runs = [re.findall(r"npm run ([\w:-]+)", part) for part in (ts, older.split("\nfi", 1)[0])]
    lib = (REMOTE / "common" / "npm_scripts.sh").read_text()
    assert runs == [TS_SCRIPTS, OLD_SCRIPTS]
    assert f"list=({' '.join(TS_SCRIPTS)})" in lib and f"list=({' '.join(OLD_SCRIPTS)})" in lib


def test_the_laptop_checks_before_the_build_and_the_first_sync():
    text = (ROOT / "deploy-api.sh").read_text()
    check = text.index("npm_scripts_check .")
    assert text.index('cd "$PROJECT_DIR/$local_dir"') < check < text.index("npm ci --include=dev")
    assert check < text.index("sync_remote_folder_structure") and check < text.index('sync "/$local_dir/build"')
    assert 'source "$SCRIPT_DIR/remote/common/npm_scripts.sh"' in text
