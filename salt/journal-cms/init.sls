journal-cms-localhost:
    host.present:
        - ip: 127.0.0.2
        - names:
            - journal-cms.local

journal-cms-repository:
    builder.git_latest:
        - name: git@github.com:elifesciences/journal-cms.git
        - identity: {{ pillar.elife.projects_builder.key or '' }}
        - rev: {{ salt['elife.rev']() }}
        - branch: {{ salt['elife.branch']() }}
        - target: /srv/journal-cms/
        - force_fetch: True
        - force_checkout: True
        - force_reset: True

    # file.directory can be a bit slow when recurring over many files
    cmd.run:
        - name: chown -R {{ pillar.elife.deploy_user.username }}:{{ pillar.elife.deploy_user.username }} .
        - cwd: /srv/journal-cms
        - require:
            - builder: journal-cms-repository

# this should have the fix https://github.com/puli/composer-plugin/pull/46
puli-master:
    cmd.run:
        # install 1.0.0-beta10 at the moment
        - name: |
            composer global remove puli/cli
            curl https://puli.io/installer | php
        - cwd: /srv/journal-cms
        - user: {{ pillar.elife.deploy_user.username }}
        - require:
            - cmd: install-composer
            - journal-cms-repository


web-sites-file-permissions:
    cmd.run:
        - name: |
            chmod -f 755 web/sites/default || true
            # shouldn't this be 644? This files does not seem executable
            chmod -f 755 web/sites/default/settings.php || true
        - cwd: /srv/journal-cms
        - require:
            - journal-cms-repository

composer-install:
    cmd.run:
        - name: composer --no-interaction install
        - cwd: /srv/journal-cms
        - user: {{ pillar.elife.deploy_user.username }}
        - env:
            - COMPOSER_DISCARD_CHANGES: 1
        - require:
            - install-composer
            - web-sites-file-permissions
            - journal-cms-localhost
            - puli-master

#composer-drupal-scaffold:
#    cmd.run:
#        - name: composer drupal-scaffold
#        - cwd: /srv/journal-cms
#        - user: {{ pillar.elife.deploy_user.username }}
#        - require:
#            - composer-install

site-settings:
    file.managed:
        - name: /srv/journal-cms/config/local.settings.php
        - source: salt://journal-cms/config/srv-journal-config-local.settings.php
        - template: jinja
        - user: {{ pillar.elife.deploy_user.username }}
        - group: {{ pillar.elife.deploy_user.username }}
        - require:
            - composer-install
            #- composer-drupal-scaffold
        - require_in:
            - site-install
            
{% for key in ['db', 'legacy_db'] %}
{% set db = pillar.journal_cms[key] %}
journal-cms-{{ key }}:
    mysql_database.present:
        - name: {{ db.name }}
        - connection_pass: {{ pillar.elife.db_root.password }}
        - require:
            - mysql-ready
        - require_in:
            - site-install

journal-cms-{{ key }}-user:
    mysql_user.present:
        - name: {{ db.user }}
        - password: {{ db.password }}
        - connection_pass: {{ pillar.elife.db_root.password }}
        - host: localhost
        - require:
            - mysql-ready
        - require_in:
            - site-install

journal-cms-{{ key }}-access:
    mysql_grants.present:
        - user: {{ db.user }}
        - database: {{ db.name }}.*
        - grant: all privileges
        - connection_pass: {{ pillar.elife.db_root.password }}
        - require:
            - mysql_user: journal-cms-{{ key }}-user
            - mysql_database: journal-cms-{{ key }}
        - require_in:
            - cmd: site-install
{% endfor %}

journal-cms-vhost:
    file.managed:
        - name: /etc/nginx/sites-enabled/journal-cms.conf
        - source: salt://journal-cms/config/etc-nginx-sites-enabled-journal-cms.conf
        - template: jinja
        - require_in:
            - site-install
        - listen_in:
            - service: nginx-server-service
            - service: php-fpm

# when more stable, maybe this should be extended to the fpm one?
php-cli-ini-with-fake-sendmail:
    file.managed:
        - name: /etc/php/7.0/cli/conf.d/20-sendmail.ini
        - source: salt://journal-cms/config/etc-php-7.0-cli-conf.d-20-sendmail.ini
        - require:
            - php
        - require_in:
            - site-install

site-install:
    cmd.run:
        - name: ../vendor/bin/drush si config_installer -y
        - cwd: /srv/journal-cms/web
        - user: {{ pillar.elife.deploy_user.username }}
        # always execute for now
        #- unless:  ../vendor/bin/drush cget system.site name

aws-credentials-cli:
    file.managed:
        - name: /home/{{ pillar.elife.deploy_user.username }}/.aws/credentials
        - source: salt://journal-cms/config/home-user-.aws-credentials
        - user: {{ pillar.elife.deploy_user.username }}
        - group: {{ pillar.elife.deploy_user.username }}
        - makedirs: True
        - template: jinja
        - require:
            - site-install

aws-credentials-www-data:
    file.managed:
        - name: /var/www/.aws/credentials
        - source: salt://journal-cms/config/home-user-.aws-credentials
        - user: www-data
        - group: www-data
        - makedirs: True
        - template: jinja
        - require:
            - site-install

# populates data into the labs and subjects until they will be created through the user interface
migrate-content:
    cmd.run:
        - name: |
            ../vendor/bin/drush mi jcms_labs_experiments_json
            ../vendor/bin/drush mi jcms_subjects_json
        #- name: ../vendor/bin/drush mi --all
        - cwd: /srv/journal-cms/web
        - user: {{ pillar.elife.deploy_user.username }}
        - require:
            - site-install

