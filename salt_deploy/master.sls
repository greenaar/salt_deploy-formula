{% from 'salt_deploy/map.jinja' import salt_deploy with context %}
{% set deploy = salt_deploy.deploy %}
{% set master = salt_deploy.master %}

{% if master.manage_file_roots %}
salt_deploy_master_config:
  file.managed:
    - name: {{ master.config_file }}
    - user: root
    - group: root
    - mode: '0644'
    - makedirs: true
    - contents: |
        # Managed by the salt_deploy formula.
        file_roots:
          {{ master.saltenv }}:
            - {{ deploy.current_link }}
{% if deploy.bootstrap %}
    - require:
      - cmd: salt_deploy_bootstrap_release
{% endif %}

salt_deploy_master_service:
  service.running:
    - name: {{ master.service }}
    - enable: true
    - watch:
      - file: salt_deploy_master_config
{% endif %}
