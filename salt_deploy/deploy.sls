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
    - names:
      - {{ deploy.base_dir }}
      - {{ deploy.releases_dir }}
      - {{ deploy.config_dir }}
    - user: root
    - group: root
    - dir_mode: '0755'
    - require:
      - pkg: salt_deploy_packages

salt_deploy_private_key:
  file.managed:
    - name: {{ deploy.private_key_path }}
    - contents_pillar: {{ deploy.private_key_pillar }}
    - user: root
    - group: root
    - mode: '0600'
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

{% if deploy.bootstrap %}
salt_deploy_bootstrap_release:
  cmd.run:
    - name: {{ deploy.script }} --latest
    - unless: test -L {{ deploy.current_link }} && test -d "$(readlink -f {{ deploy.current_link }})"
    - require:
      - file: salt_deploy_script
{% endif %}
