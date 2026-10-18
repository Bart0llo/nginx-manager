#!/bin/bash
# Example NGINX Manager plugin (docs/PLUGINS.md).
#
# location-directives: a site whose data for this plugin is {"header": true}
# gets
#     proxy_set_header X-Example-Greeting "<GREETING>";
# in its "location /". Other sites get nothing, so enabling the plugin
# changes no configuration on its own.
#
# Settings, optional: /etc/nginx-manager/plugins/example.conf
#   GREETING=hello     1-64 letters, digits, spaces, '.', '_' or '-'

hook="$1"

case "$hook" in
    location-directives)
        [[ "$(jq -r '.header == true' <<< "$NM_SITE_DATA")" == true ]] || exit 0

        greeting="${NM_SETTING_GREETING-hello}"
        if [[ ! "$greeting" =~ ^[A-Za-z0-9._\ -]{1,64}$ ]]; then
            echo "example: GREETING in $NM_PLUGIN_CONFIG must be 1-64 letters, digits, spaces, '.', '_' or '-'" >&2
            exit 1
        fi
        printf 'proxy_set_header X-Example-Greeting "%s";\n' "$greeting"
        ;;
    *)
        echo "example: unexpected hook '$hook'" >&2
        exit 1
        ;;
esac
