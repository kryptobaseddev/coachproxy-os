#!/bin/bash
#
# File: roles/coachproxy/files/bin/apply_remote_access_settings.sh

log=/coachproxy/bin/cplog.sh
script=$(basename $0 .sh)
conf_ngrok=/coachproxy/etc/ngrok.conf
conf_duckdns=/coachproxy/etc/duckdns.conf

log () {
  if [[ "$silent" = false ]]; then
    $log "$script $1"
  fi
}

send_message () {
  /usr/local/bin/mqtt-simple -h localhost -p "CP/MESSAGE/REMOTEACCESS" -m "$1"
}

disable () {
  result=$(echo "INSERT OR REPLACE INTO settings2 (key, value) VALUES('remote_access', 'false')" | sqlite3 /coachproxy/node-red/coachproxy.sqlite)
}

abort () {
  send_message "$1"
  echo "$1"
  log "$script $1 Stopping remote access."
  if [[ $remote_access_method == "ngrok" ]]; then
    sudo killall ngrok
  fi
  disable
  exit 0
}

silent=false
if [[ $1 == "--silent" ]]; then
  silent=true
else
  send_message "Applying remote access settings..."
fi

# Wait a second to ensure node-red finishes updating the database
sleep 1

# Get the settings from the database
remote_access_method=$(echo "select value from settings2 where key='remote_access_method';" | sqlite3 /coachproxy/node-red/coachproxy.sqlite)
user=$(echo "select value from settings2 where key='remote_username';" | sqlite3 /coachproxy/node-red/coachproxy.sqlite)
pass=$(echo "select value from settings2 where key='remote_password';" | sqlite3 /coachproxy/node-red/coachproxy.sqlite)
auth=$(echo "select value from settings2 where key='ngrok_auth';" | sqlite3 /coachproxy/node-red/coachproxy.sqlite)
enabled=$(echo "select value from settings2 where key='remote_access';" | sqlite3 /coachproxy/node-red/coachproxy.sqlite)
domain=$(echo "select value from settings2 where key='remote_subdomain';" | sqlite3 /coachproxy/node-red/coachproxy.sqlite)

if [[ $enabled != 'true' ]]; then
  abort "Remote access is disabled."
fi

if [[ $remote_access_method == "ngrok" ]]; then
  if [[ ${#auth} -lt 5 ]]; then
    abort "ERROR: ngrok Authtoken is missing."
  fi

  if [[ ${#user} -lt 1 ]]; then
    abort "ERROR: Username is missing."
  fi

  if [[ ${#pass} -lt 1 ]]; then
    abort "ERROR: Password is missing."
  fi

  # If a custom subdomain is used, bind the main tunnel to https only.
  bind_tls=true
  if [[ ${#domain} -lt 1 ]]; then
    bind_tls=both
  fi

  # Rebuild config file for ngrok
  log "$script updating ngrok.conf with latest user settings"
  sed "${conf_ngrok}-TEMPLATE" -e "s/AUTHTOKEN/$auth/" -e "s/USERNAME/$user/" -e "s/PASSWORD/$pass/" -e "s/BIND_TLS/$bind_tls/" -e "s/SUBDOMAIN/$domain/" > $conf_ngrok

  # Restart ngrok tunnel
  log "$script restarting ngrok tunnel."
  send_message "Restarting remote access system. See above for URL."
  sudo killall ngrok
  sleep 2
  /usr/local/bin/ngrok start -config $conf_ngrok --all &

elif [[ $remote_access_method == "duckdns" ]]; then
  if [[ ${#domain} -lt 1 ]]; then
    abort "ERROR: DuckDNS domain is missing."
  fi
  if [[ ${#auth} -lt 1 ]]; then
    abort "ERROR: DuckDNS token is missing."
  fi

  # Write DuckDNS config
  log "$script updating DuckDNS..."
  echo "url=\"https://www.duckdns.org/update?domains=$domain&token=$auth&ip=\"" > $conf_duckdns
  curl -k -o /var/log/duck.log -K $conf_duckdns
  send_message "DuckDNS updated with domain $domain."
fi
