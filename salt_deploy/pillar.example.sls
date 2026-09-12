# Replace every example value before applying this formula.
salt_deploy:
  deploy:
    repository_url: git@github.com:example/salt-states.git
    branch: main

    # The Git working tree the master already serves. salt_deploy updates
    # this checkout in place; it does not create it, and it does not change
    # any master path. Whatever else points at this directory - an NFS
    # export, a Samba share, a backup job - keeps working.
    work_tree: /srv/salt
    owner: salt
    group: salt

    # Store these values in encrypted pillar or another protected pillar source.
    private_key: |
      -----BEGIN OPENSSH PRIVATE KEY-----
      REPLACE_WITH_A_READ_ONLY_DEPLOY_KEY
      -----END OPENSSH PRIVATE KEY-----

    # Obtain the current trusted host keys through a separately authenticated
    # channel. Do not populate this with an unauthenticated ssh-keyscan
    # performed during deployment.
    #
    # A forge on a non-default SSH port needs the bracketed form, matching
    # the port in repository_url:
    #   [forge.example.com]:2222 ssh-ed25519 AAAA...
    known_hosts: |
      github.com REPLACE_WITH_TRUSTED_HOST_KEY

    # Runs as root inside a throwaway export of the requested commit, before
    # the working tree is touched. The default assumes the top file sits at
    # the root of the repository; set it to where file_roots actually expects
    # one. A repository whose file_roots are subdirectories needs, say,
    # `test -f base/top.sls`.
    validation_command: test -f top.sls

    # Deploy over uncommitted changes in the working tree. Leave false when
    # the tree is writable by anyone - a Samba share, an NFS export - because
    # the checkout is a --force and would discard their work without asking.
    allow_dirty: false

    # Optional master-local actions after a successful deployment. These
    # values are baked into the root-owned script, not supplied by CI.
    post_deploy:
      sync_all: false
      states: []
      # Example - note these are SLS names as Salt resolves them, so a state
      # in formulas/salt/pass/ is `salt.pass`, not `salt_pass`:
      # states:
      #   - salt.pass
      #   - salt_deploy

  master:
    saltenv: base
    verify_roots: true

  runner:
    # Select exactly one provider: github or forgejo.
    provider: github
    name: salt-master-01
    github:
      repository_url: https://github.com/example/salt-states
      registration_token: REPLACE_WITH_SHORT_LIVED_REGISTRATION_TOKEN
      labels:
        - salt-deploy
      runner_group: ''
      replace: false
      version: 2.336.0
      source_hashes:
        x64: sha256=04cf0be1aff4c3ec3554466c39124ca250e3effd8873bb7e8d68535aa9505d5d
        arm64: sha256=58b758e420b87093fbd4bfddd368074960053e2f1388f01848c82624b90f27d1

    # To use Forgejo, set provider: forgejo and fill this section instead.
    # Forgejo 15+ displays these values after creating a repository runner.
    forgejo:
      instance_url: https://forgejo.example.com/
      uuid: REPLACE_WITH_RUNNER_UUID
      token: REPLACE_WITH_RUNNER_TOKEN
      connection_name: salt-deploy
      labels:
        - salt-deploy:host
      version: 12.7.3
      # Verify the upstream .asc signature first, then calculate the digest.
      source_hashes:
        amd64: sha256=REPLACE_WITH_VERIFIED_AMD64_SHA256
        arm64: sha256=REPLACE_WITH_VERIFIED_ARM64_SHA256
