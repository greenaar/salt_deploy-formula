# salt_deploy Salt formula

Installs a repository-scoped GitHub Actions or Forgejo Actions runner on the
Salt master and turns a push to the states repository into a validated,
locked, in-place update of the checkout the master already serves.

The forge is used only during deployment. An outage, failed fetch, invalid
revision, or interrupted run leaves the master serving the revision it was
already serving.

## Design

The formula does **not** introduce a directory layout of its own, and does
not write master configuration. It takes the Git working tree the master is
already configured for - `salt_deploy:deploy:work_tree`, default `/srv/salt` -
and updates it in place:

```text
/srv/salt/          the tree the master already serves, unchanged in place
|-- .git/           fetched from and reset by the deployment
`-- ...             file_roots, pillar_roots, ext_pillar, auth_dirs targets
```

A deployment locks against concurrent runs, refuses to proceed over
uncommitted changes, fetches the configured branch, requires the requested
commit to still be that branch's head, validates the commit in a throwaway
export, resets the checkout onto it, and clears the Salt roots file-list
cache. If cache clearing fails, it restores the previous commit.

It can optionally synchronize master extension modules and apply an explicit
list of states locally afterwards. Those actions are baked into the
root-owned script; the workflow cannot select states or supply commands.

### Why in place

The obvious alternative - export each commit to an immutable release
directory and swap a `current` symlink - buys atomic promotion and cheap
rollback. It costs the paths, and on a real master the paths are load-bearing
in ways that are easy to miss:

- `file_roots`, `pillar_roots`, the PillarStack `ext_pillar` and `auth_dirs`
  are four separate options, in two different formulas' pillar. Moving states
  without pillar produces a master serving new states against stale pillar,
  and nothing reports it.
- The tree is frequently exported over NFS. An export root cannot be a
  symlink, and an NFSv4 root (`fsid=0`) cannot be repointed per release at
  all.
- It is often a writable Samba share people actually edit.
- It is usually a backup source. An exported release tree has no `.git`, so
  switching to one silently drops history out of the backups.
- Ignored working data living in the tree - vendored upstream sources, caches -
  is not in Git and does not survive being replaced by an export.

Updating in place keeps every one of those working and unchanged. What it
gives up is atomicity: for the moment `git checkout` is writing, the
fileserver can see a mixed tree. That window is short, it is the same window
a hand-run `git pull` already has, and validation happens before it rather
than after - so what lands in it is a revision already known to be servable.

If you want a release-directory deployment, this is the wrong formula; the
cost is not the symlink, it is the four options and the three services above.

### Coexisting with the `salt` formula

There is nothing to coexist with: this formula writes no file into
`master.d`, so the `salt` formula's `clean: true` recurse has nothing of
this formula's to delete, and there is no second `file_roots` to win or lose
a sort-order race.

Instead, `salt_deploy.master` checks the assumption that makes in-place
updating correct. It reads `salt:master:file_roots`, `pillar_roots`,
`auth_dirs` and the PillarStack `ext_pillar` - the same pillar the `salt`
formula renders `master.d` from - and fails if any of them resolves outside
`work_tree`. A path left outside is the silent failure this formula exists to
avoid: deployments keep reporting success while that part of the tree is
served from somewhere nothing updates.

Set `salt_deploy:master:verify_roots: false` if some path is outside the tree
deliberately.

## Supported systems

- Linux with systemd
- `x86_64`/`amd64` or `aarch64`/`arm64`
- A modern Salt release with `slsutil.merge`
- Forgejo 15 or newer when `runner:provider` is `forgejo`
- `git`, and a `work_tree` that is already a checkout of the states repository

Package defaults target Debian and Ubuntu. Override `packages` if another
system uses different package names.

## Prerequisites

1. Create a read-only SSH deploy key for the states repository.
2. Obtain the forge's SSH host keys through a trusted, authenticated source.
3. Create a repository-scoped Actions runner in GitHub or Forgejo.
4. Protect the deployment branch and restrict who can change workflows.
5. Ensure `work_tree`'s `.git/objects/` is writable by `deploy:owner`. If
   the checkout was cloned by root, the `salt` user cannot write new objects
   and the first fetch fails with a confusing permission error:
   ```bash
   chown -R <owner>:<group> <work_tree>/.git
   ```

Do not use this host runner with an untrusted or public repository. Anyone
able to change its workflow can execute commands as the runner account. The
sudo boundary prevents that account from rewriting the root-owned deployment
command, but it is not a general sandbox - see "Runner confinement" below.

## Configuration

Copy `pillar.example.sls` into a protected pillar tree and replace every
placeholder. Private keys and runner tokens should come from encrypted pillar,
a `pass`-backed resolver, or another protected external pillar.

```yaml
salt_deploy:
  deploy:
    repository_url: git@github.com:example/salt-states.git
    branch: main
    work_tree: /srv/salt
    owner: salt
    group: salt
    private_key: |
      <read-only deploy private key>
    known_hosts: |
      <trusted SSH host-key entries>
```

`work_tree` must already be a checkout of `repository_url`. The formula
deliberately does not clone it: on a master whose `file_roots` already point
at that path, a half-finished clone is served the moment it appears.

`owner` is the account that owns the served tree, and every Git command runs
as it. A root `git checkout` would leave root-owned files across an exported,
shared, backed-up directory and a half root-owned `.git`. The deploy key is
therefore readable by `owner` - on a normal master that is a `nologin` system
account which already owns the tree.

A forge on a non-default SSH port needs the bracketed `known_hosts` form,
matching the port in `repository_url`:

```text
[forge.example.com]:2222 ssh-ed25519 AAAA...
```

### Validation

`deploy:validation_command` runs as root, from inside a throwaway export of
the requested commit, before the working tree is touched. A revision that
fails it never reaches the master at all.

The default, `test -f top.sls`, assumes the top file is at the root of the
repository. When `file_roots` points at subdirectories, set it to match:

```yaml
salt_deploy:
  deploy:
    validation_command: test -f base/top.sls && test -d formulas
```

Replace it with your repository's lint or render checks where practical.

### Uncommitted changes

`git checkout --force` discards whatever is in its way. When the tree is
writable by people - a Samba share, an NFS export - that is somebody's work
in progress, so a deployment refuses to run and reports the paths instead:

```console
Refusing to deploy: /srv/salt has uncommitted changes.
 M formulas/nginx/init.sls
Commit, revert, or set salt_deploy:deploy:allow_dirty to discard them.
```

`salt_deploy:deploy:allow_dirty: true` discards them instead, still listing
what was discarded. The check honours `.gitignore`, so ignored working data
in the tree is never mistaken for an edit.

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

The token is written to `/etc/salt-deploy/github-registration-token` (mode
0400, owned by the runner account) and read from there by `config.sh`, rather
than being interpolated into the command. A `cmd.run`'s command line is part
of its state return, and state returns end up in the master job cache - which
on a master configured for Alcali is a database more than one person can
read. `hide_output` does not cover this; it suppresses the command's output,
not the command.

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
command. Forgejo warns that host jobs have no isolation, so register this
runner only to the trusted states repository.

### Runner confinement

The managed Forgejo unit sets `PrivateTmp=true` and nothing else. That is
deliberate, and worth understanding before "hardening" it.

A process started with `sudo` from the runner stays inside the unit's mount
namespace. Any path made read-only for the runner is read-only for the
deployment too. Under `ProtectSystem=strict` the checkout, the fileserver
cache, and every post-deployment state that writes to `/etc` or installs a
package all fail - as permission errors that look like anything but a
sandbox. Confinement that has to be switched off to let the service work is
worse than none, because the next person reads it and believes it.

The boundary that does hold is the sudoers rule: the runner account is
unprivileged and may run exactly one root command, whose behaviour is fixed
at render time and cannot be steered by the workflow.

To confine the deployment, confine the deployment - have the script hand its
work to a transient unit via `systemd-run`, which leaves the runner's
namespace behind. That needs its own review of what your `post_deploy` states
touch, so it is not the default.

## Post-deployment master actions

Optional actions run after the new revision is checked out and the roots
file-list cache has been cleared:

```yaml
salt_deploy:
  deploy:
    post_deploy:
      sync_all: true
      states:
        - salt.pass
        - salt_deploy
```

`sync_all` runs `salt-run saltutil.sync_all`, which synchronizes extension
modules used by the master. Each state is then applied to the master minion
with `salt-call --retcode-passthrough state.apply`, in the listed order. State
names are passed as literal arguments rather than evaluated as shell commands.

These are SLS names as Salt resolves them. A state living in
`formulas/salt/pass/` is `salt.pass`, not `salt_pass`; a name that does not
resolve fails the deployment on every run.

Configuration is intentionally a two-step process. A change to `post_deploy`
takes effect after the master minion next applies `salt_deploy` and rewrites
the fixed deployment script. Including `salt_deploy` in the existing
post-deploy state list can install later configuration changes, but the newly
rendered action list is used beginning with the following deployment.

If synchronization or a state apply fails, deployment exits unsuccessfully
and does not launch later actions. The checkout stays on the new revision: an
automatic rollback would not undo changes a state has already made, only
obscure which revision produced them. Investigate the failed action and roll
back by hand.

## Applying

```console
salt-call state.apply salt_deploy test=True
salt-call state.apply salt_deploy
```

Applying the formula installs the runner, the deployment script and the sudo
rule. It does not deploy anything by itself, and it does not change what the
master serves - the first deployment happens on the next push, or when you
run the command below.

## Add the workflow

For GitHub, copy `examples/deploy-salt.yml` to
`.github/workflows/deploy-salt.yml`. For Forgejo, copy
`examples/deploy-salt-forgejo.yml` to `.forgejo/workflows/deploy-salt.yml`.

Both workflows pass the triggering SHA. The deployment command independently
fetches the branch and verifies that SHA is still its current head, so a
delayed workflow cannot roll the master back over a newer push.

## Operations

Inspect the applicable runner and recent deployment messages with:

```console
systemctl status "$(cat /opt/actions-runner/.service)"  # GitHub
systemctl status forgejo-runner                         # Forgejo
journalctl -t salt-deploy
git -C /srv/salt log -1 --oneline
```

Deploy the current branch head manually with:

```console
sudo /usr/local/sbin/deploy-salt --latest
```

Rollback is intentionally manual and privileged. Because the tree is an
ordinary checkout, it is ordinary Git:

```console
runuser -u salt -- git -C /srv/salt checkout --force -B master <known-good-sha>
salt-run fileserver.clear_file_list_cache backend=roots
```

Note the next deployment will refuse to run while `HEAD` is behind
`origin/<branch>` only if the tree is also dirty; a rollback that must
survive further pushes needs the bad commit reverted on the branch.

Exit codes: 64 usage, 65 uncommitted changes or a stale requested SHA, 70
cache refresh or post-deployment failure, 72 `work_tree` is not a checkout,
75 another deployment holds the lock.

The GitHub runner normally self-updates. The Forgejo binary updates when its
pinned version and verified digest change. Review runner releases
periodically. This formula does not automatically deregister runners because
that changes external state and requires provider-specific removal
credentials.

## References

- [GitHub: adding self-hosted runners](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/add-runners)
- [GitHub: self-hosted runner security](https://docs.github.com/en/actions/reference/security/secure-use#hardening-for-self-hosted-runners)
- [Forgejo: runner binary installation](https://forgejo.org/docs/latest/admin/actions/installation/binary/)
- [Forgejo: runner registration](https://forgejo.org/docs/latest/admin/actions/registration/)
- [Forgejo: Actions security](https://forgejo.org/docs/latest/admin/actions/security/)
- [Salt: fileserver cache runner](https://docs.saltproject.io/en/latest/ref/runners/all/salt.runners.fileserver.html)
