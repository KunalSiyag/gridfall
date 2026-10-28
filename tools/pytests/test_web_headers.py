from tools.checks import web_headers

CADDY_OK = """{
\troot * /srv
\theader {
\t\tCross-Origin-Opener-Policy same-origin
\t\tCross-Origin-Embedder-Policy require-corp
\t}
}
"""

CADDY_BARE = "{\n\troot * /srv\n}\n"


def test_caddyfile_with_isolation_headers_passes(repo):
    root = repo({"deploy/web/Caddyfile": CADDY_OK})
    res = web_headers.run(root)
    assert res.ok, res.new
    assert res.stats == {"serving_configs": 1}


def test_config_without_isolation_headers_fails(repo):
    root = repo(
        {
            "deploy/web/Caddyfile": CADDY_OK,
            "deploy/web/nginx.conf": "server { listen 8080; }\n",
            "deploy/web/site.vhost": CADDY_BARE,
        }
    )
    res = web_headers.run(root)
    assert not res.ok
    assert len(res.new) == 4  # two configs, two headers each
    assert any("nginx.conf" in n for n in res.new)
    assert any("site.vhost" in n for n in res.new)
    assert not any("Caddyfile: missing" in n for n in res.new)


def test_missing_serving_config_is_a_finding(repo):
    root = repo({"deploy/web/smoke.js": "// not a server config\n"})
    res = web_headers.run(root)
    assert not res.ok
    assert any("no serving config" in n for n in res.new)


def test_repo_caddyfile_carries_both_headers():
    res = web_headers.run(web_headers.common.REPO)
    assert res.ok, res.new
