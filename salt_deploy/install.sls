{% from 'salt_deploy/map.jinja' import salt_deploy with context %}

salt_deploy_supported_platform:
  test.check_pillar:
    - present:
      - salt_deploy:deploy:repository_url
{% if salt_deploy.runner.provider == 'github' %}
      - salt_deploy:runner:github:repository_url
{% elif salt_deploy.runner.provider == 'forgejo' %}
      - salt_deploy:runner:forgejo:instance_url
      - salt_deploy:runner:forgejo:uuid
      - salt_deploy:runner:forgejo:token
      - salt_deploy:runner:forgejo:source_hashes:{{ salt_deploy.runner.forgejo.arch }}
{% endif %}
    - require:
      - test: salt_deploy_linux_systemd

salt_deploy_linux_systemd:
  test.configurable_test_state:
    - name: salt_deploy requires Linux with systemd
    - changes: false
    - failhard: true
    - result: {{ (grains.get('kernel') == 'Linux' and grains.get('init') == 'systemd') | json }}
    - comment: >-
        {{ 'Supported platform detected.' if grains.get('kernel') == 'Linux' and grains.get('init') == 'systemd'
           else 'salt_deploy supports Linux systems using systemd only.' }}

salt_deploy_runner_provider:
  test.configurable_test_state:
    - name: salt_deploy runner provider must be github or forgejo
    - changes: false
    - failhard: true
    - result: {{ (salt_deploy.runner.provider in ['github', 'forgejo']) | json }}
    - comment: >-
        {{ 'Runner provider ' ~ salt_deploy.runner.provider ~ ' selected.'
           if salt_deploy.runner.provider in ['github', 'forgejo']
           else 'Unsupported runner provider: ' ~ salt_deploy.runner.provider }}

salt_deploy_packages:
  pkg.installed:
    - pkgs: {{ salt_deploy.packages | json }}
    - require:
      - test: salt_deploy_supported_platform
      - test: salt_deploy_runner_provider
