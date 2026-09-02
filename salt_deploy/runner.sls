{% from 'salt_deploy/map.jinja' import salt_deploy with context %}
{% set runner = salt_deploy.runner %}

{% if runner.arch not in ['x64', 'arm64'] %}
salt_deploy_runner_architecture:
  test.fail_without_changes:
    - name: Unsupported runner architecture: {{ grains.get('osarch', grains.get('cpuarch', 'unknown')) }}
    - failhard: true

{% elif runner.provider == 'github' %}
{% set github = runner.github %}

salt_deploy_runner_directories:
  file.directory:
    - names:
      - {{ runner.install_dir }}
      - {{ runner.work_dir }}
    - user: {{ runner.user }}
    - group: {{ runner.group }}
    - dir_mode: '0755'
    - require:
      - user: salt_deploy_runner_user

salt_deploy_github_runner_archive:
  archive.extracted:
    - name: {{ runner.install_dir }}
    - source: https://github.com/actions/runner/releases/download/v{{ github.version }}/actions-runner-linux-{{ runner.arch }}-{{ github.version }}.tar.gz
    - source_hash: {{ github.source_hashes[runner.arch] }}
    - enforce_toplevel: false
    - if_missing: {{ runner.install_dir }}/bin/Runner.Listener
    - user: {{ runner.user }}
    - group: {{ runner.group }}
    - require:
      - pkg: salt_deploy_packages
      - file: salt_deploy_runner_directories

{#- The registration token is written to a root-owned file and read back by
    the command, rather than interpolated into it.

    `hide_output` suppresses the command's stdout and stderr, but not the
    command itself: a cmd.run's `name` is part of the state return, and the
    state return is written to the master job cache. On a master configured
    for Alcali that cache is a database several people can read, and the
    token is a credential that registers a runner against the repository.

    The file is left in place afterwards. The token is single-use and
    short-lived, `unless` keeps this state from running again once .runner
    exists, and deleting it would make a legitimate re-registration
    (--replace) need a fresh token for no security gain. #}
{%- if github.registration_token %}
salt_deploy_github_registration_token:
  file.managed:
    - name: {{ salt_deploy.deploy.config_dir }}/github-registration-token
    - contents_pillar: salt_deploy:runner:github:registration_token
    - user: {{ runner.user }}
    - group: {{ runner.group }}
    - mode: '0400'
    - show_changes: false
    - require:
      - file: salt_deploy_directories
      - user: salt_deploy_runner_user
{%- endif %}

salt_deploy_github_runner_configured:
  cmd.run:
    - name: >-
        ./config.sh --unattended
        --url {{ github.repository_url | json }}
        --token "$(cat {{ (salt_deploy.deploy.config_dir ~ '/github-registration-token') | json }})"
        --name {{ runner.name | json }}
        --labels {{ github.labels | join(',') | json }}
        --work {{ runner.work_dir | json }}
        {{ ('--runnergroup ' ~ (github.runner_group | json)) if github.runner_group else '' }}
        {{ '--replace' if github.replace else '' }}
    - cwd: {{ runner.install_dir }}
    - runas: {{ runner.user }}
    - unless: test -f {{ runner.install_dir }}/.runner
    - hide_output: true
    - require:
      - cmd: salt_deploy_github_runner_dependencies
      {%- if github.registration_token %}
      - file: salt_deploy_github_registration_token
      {%- endif %}

salt_deploy_github_runner_dependencies:
  cmd.run:
    - name: ./bin/installdependencies.sh && touch .salt-dependencies-installed
    - cwd: {{ runner.install_dir }}
    - unless: test -f .salt-dependencies-installed
    - require:
      - archive: salt_deploy_github_runner_archive

salt_deploy_github_runner_service_installed:
  cmd.run:
    - name: ./svc.sh install {{ runner.user }}
    - cwd: {{ runner.install_dir }}
    - unless: test -s {{ runner.install_dir }}/.service
    - require:
      - cmd: salt_deploy_github_runner_configured

salt_deploy_github_runner_service_running:
  cmd.run:
    - name: ./svc.sh start
    - cwd: {{ runner.install_dir }}
    - unless: test -s .service && systemctl is-active --quiet "$(cat .service)"
    - require:
      - cmd: salt_deploy_github_runner_service_installed

{% elif runner.provider == 'forgejo' %}
{% set forgejo = runner.forgejo %}

salt_deploy_forgejo_directories:
  file.directory:
    - name: {{ runner.work_dir }}
    - user: {{ runner.user }}
    - group: {{ runner.group }}
    - dir_mode: '0750'
    - require:
      - user: salt_deploy_runner_user

salt_deploy_forgejo_config_directory:
  file.directory:
    - name: /etc/forgejo-runner
    - user: root
    - group: {{ runner.group }}
    - dir_mode: '0750'
    - require:
      - user: salt_deploy_runner_user

salt_deploy_forgejo_runner_binary:
  file.managed:
    - name: {{ forgejo.binary }}
    - source: https://code.forgejo.org/forgejo/runner/releases/download/v{{ forgejo.version }}/forgejo-runner-{{ forgejo.version }}-linux-{{ forgejo.arch }}
    - source_hash: {{ forgejo.source_hashes[forgejo.arch] }}
    - user: root
    - group: root
    - mode: '0755'
    - require:
      - pkg: salt_deploy_packages

salt_deploy_forgejo_runner_config:
  file.managed:
    - name: {{ forgejo.config_file }}
    - source: salt://salt_deploy/files/forgejo-runner.yml.jinja
    - template: jinja
    - context:
        runner: {{ runner | json }}
        forgejo: {{ forgejo | json }}
    - user: root
    - group: {{ runner.group }}
    - mode: '0640'
    - show_changes: false
    - require:
      - file: salt_deploy_forgejo_config_directory

salt_deploy_forgejo_runner_service_unit:
  file.managed:
    - name: /etc/systemd/system/{{ forgejo.service }}.service
    - source: salt://salt_deploy/files/forgejo-runner.service.jinja
    - template: jinja
    - context:
        runner: {{ runner | json }}
        forgejo: {{ forgejo | json }}
        deploy: {{ salt_deploy.deploy | json }}
    - user: root
    - group: root
    - mode: '0644'
    - require:
      - file: salt_deploy_forgejo_runner_binary
      - file: salt_deploy_forgejo_runner_config

salt_deploy_forgejo_runner_service:
  service.running:
    - name: {{ forgejo.service }}
    - enable: true
    - watch:
      - file: salt_deploy_forgejo_runner_binary
      - file: salt_deploy_forgejo_runner_config
      - file: salt_deploy_forgejo_runner_service_unit

{% endif %}
