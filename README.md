# salt_deploy Salt formula

Installs either a repository-scoped GitHub Actions runner or a Forgejo Actions
runner and promotes a remotely hosted Salt state tree into an entirely local
`file_roots` directory. The forge is used only during deployment. An outage,
failed fetch, invalid state tree, or interrupted checkout leaves the last
promoted release available to the Salt master.

## Design

The formula creates this layout:

```text
/srv/salt-deploy/
|-- repo.git/                 bare fetch mirror
|-- releases/<commit>/       immutable exported releases
`-- current -> releases/...  atomically replaced live link
```

The Salt master serves `/srv/salt-deploy/current` through its normal `roots`
backend. The selected runner makes an outbound connection to the forge and
invokes a fixed, root-owned deployment command through a narrow sudo rule. The
workflow cannot replace that command.

The deployment command locks against concurrent runs, fetches into the mirror,
requires the requested commit to equal the current configured branch head,
exports and validates a new release, atomically changes the live symlink, and
clears the Salt roots file-list cache. If cache clearing fails, it restores the
previous symlink. Old releases are pruned only after successful promotion.

It can optionally synchronize master extension modules and apply an explicit
list of states locally on the Salt master after promotion. These actions are
baked into the root-owned script; the workflow cannot select states or supply
commands.

## Supported systems

- Linux with systemd
- `x86_64`/`amd64` or `aarch64`/`arm64`
- A modern Salt release with `slsutil.merge`
- Forgejo 15 or newer when `runner:provider` is `forgejo`

Package defaults target Debian and Ubuntu. Override `packages` if another
system uses different package names.

## Prerequisites

1. Create a read-only SSH deploy key for the states repository.
2. Obtain the forge's SSH host keys through a trusted, authenticated source.
3. Create a repository-scoped Actions runner in GitHub or Forgejo.
4. Protect the deployment branch and restrict who can change workflows.

Do not use this host runner with an untrusted or public repository. Anyone able
to change its workflow can execute commands as the runner account. The sudo
boundary prevents that account from rewriting the root-owned deployment
command directly, but it is not a general sandbox.

## Configuration

Copy `pillar.example` into a protected pillar tree and replace every
placeholder. Private keys and runner tokens should come from encrypted pillar,
SOPS/GPG rendering, or another protected external pillar.

Common deployment settings look like this:

```yaml
salt_deploy:
  deploy:
    repository_url: git@github.com:example/salt-states.git
    private_key: |
      <read-only deploy private key>
    known_hosts: |
      <trusted SSH host-key entries>
```

The same `deploy:repository_url` may point to a Forgejo SSH repository.

### GitHub runner

```yaml
salt_deploy:
  runner:
    provider: github
    github:
      repository_url: https://github.com/example/salt-states
      registration_token: <short-lived registration token>
```

Generate the token immediately before the first apply from **Repository
Settings -> Actions -> Runners -> New self-hosted runner**. It is used only
when `/opt/actions-runner/.runner` is absent and may be removed from pillar
after registration.

### Forgejo runner

Forgejo 15+ creates a runner UUID/token under **Repository Settings -> Actions
-> Runners**. The formula writes those credentials directly into the protected
runner configuration, following Forgejo's current connection model rather than
its deprecated interactive registration command:

```yaml
salt_deploy:
  runner:
    provider: forgejo
    forgejo:
      instance_url: https://forgejo.example.com/
      uuid: <UUID shown by Forgejo>
      token: <token shown by Forgejo>
      labels:
        - salt-deploy:host
      source_hashes:
        amd64: sha256=<verified runner binary digest>
```

Forgejo publishes detached signatures alongside runner binaries. Verify the
selected binary using Forgejo's documented release key, calculate its SHA-256
digest, and put that digest in pillar. Salt then enforces the digest on every
download. There is deliberately no `source_hash: skip` fallback.

The `host` label is necessary because this workflow calls a local deployment
command. Forgejo warns that host jobs have no isolation, so register this runner
only to the trusted states repository. The managed systemd service restricts
writable paths, and the runner receives only the fixed deployment sudo command.

## Validation and bootstrap

`deploy:validation_command` runs as root from inside a staged release before
the live symlink changes. Its default requires `top.sls`; replace it with your
repository's lint or rendering checks where practical.

Apply from the master's existing state tree:

```console
salt-call state.apply salt_deploy test=True
salt-call state.apply salt_deploy
```

With `deploy:bootstrap: true`, the real apply promotes the configured branch
before changing `file_roots`. Before applying, confirm the deployed repository
contains this formula or another state tree capable of managing the host. Once
the master switches, the previous source tree is no longer served.

## Post-deployment master actions

Optional actions run after the new release is active and the roots file-list
cache has been cleared:

```yaml
salt_deploy:
  deploy:
    post_deploy:
      sync_all: true
      states:
        - salt_pass
        - salt_deploy
```

`sync_all` runs `salt-run saltutil.sync_all`, which synchronizes extension
modules used by the master. Each state is then applied to the master minion with
`salt-call state.apply`, in the listed order. Both operations use
`salt_deploy:master:saltenv`. State names are passed as literal arguments rather
than evaluated as shell commands.

The first bootstrap release skips these actions because bootstrap may itself be
running inside `state.apply salt_deploy`; a nested state run would contend with
Salt's active-state lock. Hooks begin with the next deployment.

Configuration is intentionally a two-step process. A change to `post_deploy`
takes effect after the master minion next applies `salt_deploy` and rewrites the
fixed deployment script. Including `salt_deploy` in the existing post-deploy
state list can install later configuration changes, but the newly rendered
action list is used beginning with the following deployment.

If synchronization or a state apply fails, deployment exits unsuccessfully and
does not launch later actions. The new release remains active: an automatic
symlink rollback would not undo changes already made by a state. Investigate
the failed action and roll back manually when appropriate.

## Add the workflow

For GitHub, copy `examples/deploy-salt.yml` to
`.github/workflows/deploy-salt.yml`. For Forgejo, copy
`examples/deploy-salt-forgejo.yml` to
`.forgejo/workflows/deploy-salt.yml`.

Both workflows pass the triggering SHA. The deployment command independently
fetches the branch and verifies that SHA is still its current head, so a delayed
workflow cannot roll the master back over a newer push.

## Operations

Inspect the applicable runner and recent deployment messages with:

```console
systemctl status "$(cat /opt/actions-runner/.service)"  # GitHub
systemctl status forgejo-runner                        # Forgejo
journalctl -t salt-deploy
readlink -f /srv/salt-deploy/current
```

Deploy the latest branch head manually with:

```console
sudo /usr/local/sbin/deploy-salt --latest
```

Rollback is intentionally manual and privileged: atomically repoint `current`
to a retained release, then run
`salt-run fileserver.clear_file_list_cache backend=roots`.

The GitHub runner normally self-updates. The Forgejo binary updates when its
pinned version and verified digest change. Review runner releases periodically.
This formula does not automatically deregister runners because that changes
external state and requires provider-specific removal credentials.

## References

- [GitHub: adding self-hosted runners](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/add-runners)
- [GitHub: self-hosted runner security](https://docs.github.com/en/actions/reference/security/secure-use#hardening-for-self-hosted-runners)
- [Forgejo: runner binary installation](https://forgejo.org/docs/latest/admin/actions/installation/binary/)
- [Forgejo: runner registration](https://forgejo.org/docs/latest/admin/actions/registration/)
- [Forgejo: Actions security](https://forgejo.org/docs/latest/admin/actions/security/)
- [Salt: fileserver cache runner](https://docs.saltproject.io/en/latest/ref/runners/all/salt.runners.fileserver.html)

## Relationship to upstream

**This formula was written from scratch for one specific deployment. It is
not a fork of anything, and there is no upstream to fall back to.**

There is no formula of this name in the
[saltstack-formulas](https://github.com/saltstack-formulas) project. What it borrows from that project is
convention, not code: the `map.jinja` + `defaults.yaml` pattern, pillar as
the single override surface, and the general layout. Anything that did come
from elsewhere is noted in the file headers.

Its states, pillar keys, and defaults are shaped around the deployment it
was built for. Read `pillar.example` before pointing it at anything you
care about — it has had far less exposure than a widely-used formula, so
expect rough edges on platforms other than the ones it was written against.

### Credit

The structure and conventions come from the
[saltstack-formulas](https://github.com/saltstack-formulas) project; credit for that groundwork belongs to
its authors and contributors.

## License

Dedicated to the public domain under [CC0 1.0 Universal](LICENSE).
