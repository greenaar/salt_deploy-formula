{% from 'salt_deploy/map.jinja' import salt_deploy with context %}
{% set deploy = salt_deploy.deploy %}
{% set master = salt_deploy.master %}
{% set runner = salt_deploy.runner %}

salt_deploy_runner_group:
  group.present:
    - name: {{ runner.group }}
    - system: true

salt_deploy_runner_user:
  user.present:
    - name: {{ runner.user }}
    - gid: {{ runner.group }}
    - home: {{ runner.home }}
    - shell: /bin/bash
    - createhome: true
    - system: true
    - require:
      - group: salt_deploy_runner_group

salt_deploy_directories:
  file.directory:
    - name: {{ deploy.config_dir }}
    - user: root
    - group: root
    - dir_mode: '0755'
    - require:
      - pkg: salt_deploy_packages

{#- This formula updates a checkout that already exists; it does not create
    one. Cloning here would race whatever put the tree there, and on a master
    whose file_roots already point at this path a half-made clone is served
    the moment it appears. Fail with the path named instead. #}
salt_deploy_work_tree:
  file.exists:
    - name: {{ deploy.work_tree }}/.git
    - require:
      - pkg: salt_deploy_packages

{#- Owned by the account git runs as, not by root: the deployment fetches as
    salt_deploy:deploy:owner, so a root-only key makes every fetch fail with
    a permission error that reads like an authentication failure. The account
    is a nologin system identity that already owns the served tree. #}
salt_deploy_private_key:
  file.managed:
    - name: {{ deploy.private_key_path }}
    - contents_pillar: {{ deploy.private_key_pillar }}
    - user: {{ deploy.owner }}
    - group: {{ deploy.group }}
    - mode: '0400'
    - show_changes: false
    - require:
      - file: salt_deploy_directories

salt_deploy_known_hosts:
  file.managed:
    - name: {{ deploy.known_hosts_path }}
    - contents_pillar: {{ deploy.known_hosts_pillar }}
    - user: root
    - group: root
    - mode: '0644'
    - require:
      - file: salt_deploy_directories

salt_deploy_script:
  file.managed:
    - name: {{ deploy.script }}
    - source: salt://salt_deploy/files/deploy-salt.sh.jinja
    - template: jinja
    - context:
        deploy: {{ deploy | json }}
        master: {{ master | json }}
    - user: root
    - group: root
    - mode: '0755'
    - require:
      - pkg: salt_deploy_packages
      - file: salt_deploy_work_tree
      - file: salt_deploy_private_key
      - file: salt_deploy_known_hosts

salt_deploy_sudoers:
  file.managed:
    - name: /etc/sudoers.d/salt-deploy-runner
    - contents: |
        {{ runner.user }} ALL=(root) NOPASSWD: {{ deploy.script }} *
    - user: root
    - group: root
    - mode: '0440'
    - check_cmd: /usr/sbin/visudo -cf
    - require:
      - pkg: salt_deploy_packages
      - file: salt_deploy_script
