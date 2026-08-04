# Replace every example value before applying this formula.
salt_deploy:
  deploy:
    repository_url: git@github.com:example/salt-states.git
    branch: main

    # Store these values in encrypted pillar or another protected pillar source.
    private_key: |
      -----BEGIN OPENSSH PRIVATE KEY-----
      REPLACE_WITH_A_READ_ONLY_GITHUB_DEPLOY_KEY
      -----END OPENSSH PRIVATE KEY-----

    # Obtain the current trusted github.com host keys through a separately
    # authenticated channel. Do not populate this with an unauthenticated
    # ssh-keyscan performed during deployment.
    known_hosts: |
      github.com REPLACE_WITH_TRUSTED_GITHUB_HOST_KEY

    validation_command: test -f top.sls
    retain_releases: 5
    bootstrap: true

    # Optional master-local actions after a successful promotion. These values
    # are baked into the root-owned deployment script, not supplied by CI.
    post_deploy:
      sync_all: false
      states: []
      # Example:
      # states:
      #   - salt_pass
      #   - salt_deploy

  master:
    manage_file_roots: true
    config_file: /etc/salt/master.d/99-salt-deploy.conf
    service: salt-master
    saltenv: base

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
