{% from 'salt_deploy/map.jinja' import salt_deploy with context %}
{% set deploy = salt_deploy.deploy %}
{% set master = salt_deploy.master %}
{% set work_tree = deploy.work_tree.rstrip('/') %}

{#- This formula does not write master configuration. The master's paths are
    already correct - that is the point of updating the checkout in place -
    and a second file_roots in master.d would silently win over the salt
    formula's by sort order, which is how a state tree ends up being served
    from somewhere nobody is updating.

    What is worth checking is the assumption that makes that safe: that every
    master path really does resolve inside the tree this formula deploys into.
    A path left outside it keeps being served from wherever it points, and
    deployments appear to succeed while that part of the tree never changes.
    Read from the same pillar the salt formula renders master.d from. #}

{% if master.get('verify_roots', true) %}
{% set configured = [] %}

{% for _env, paths in salt['pillar.get']('salt:master:file_roots', {}).items() %}
{%   for path in paths %}{% do configured.append(('file_roots:' ~ _env, path)) %}{% endfor %}
{% endfor %}

{% for _env, paths in salt['pillar.get']('salt:master:pillar_roots', {}).items() %}
{%   for path in paths %}{% do configured.append(('pillar_roots:' ~ _env, path)) %}{% endfor %}
{% endfor %}

{% for path in salt['pillar.get']('salt:master:auth_dirs', []) %}
{%   do configured.append(('auth_dirs', path)) %}
{% endfor %}

{#- ext_pillar is a list of single-key mappings. PillarStack's value is
    variously a bare path, a list of them, or an env-keyed mapping. #}
{% for entry in salt['pillar.get']('salt:master:ext_pillar', []) %}
{%   if entry is mapping and 'stack' in entry %}
{%     set stack = entry['stack'] %}
{%     if stack is string %}
{%       do configured.append(('ext_pillar:stack', stack)) %}
{%     elif stack is mapping %}
{%       for _env, paths in stack.items() %}
{%         for path in ([paths] if paths is string else paths) %}
{%           do configured.append(('ext_pillar:stack:' ~ _env, path)) %}
{%         endfor %}
{%       endfor %}
{%     else %}
{%       for path in stack %}{% do configured.append(('ext_pillar:stack', path)) %}{% endfor %}
{%     endif %}
{%   endif %}
{% endfor %}

{% set outside = [] %}
{% for option, path in configured %}
{%   if not (path == work_tree or path.startswith(work_tree ~ '/')) %}
{%     do outside.append(option ~ ' -> ' ~ path) %}
{%   endif %}
{% endfor %}

salt_deploy_master_roots:
  test.configurable_test_state:
    - name: Salt master paths must resolve inside {{ work_tree }}
    - changes: false
    - failhard: true
    - result: {{ (outside | length == 0) | json }}
    - comment: >-
        {{ (configured | length ~ ' master path(s) resolve inside ' ~ work_tree ~ '.')
           if outside | length == 0
           else ('Configured outside ' ~ work_tree ~ ', so salt_deploy will not update what is served there: '
                 ~ (outside | join('; ')) ~ '. Point these at ' ~ work_tree
                 ~ ' under salt:master, or set salt_deploy:master:verify_roots to false if that is intended.') }}
{% endif %}
