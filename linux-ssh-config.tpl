mkdir -p ~/.ssh
chmod 700 ~/.ssh

cat << EOF >> ~/.ssh/config

Host ${hostname}
  HostName ${hostname}
  User ${user}
  IdentityFile ${identityfile}
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  LogLevel ERROR
EOF

chmod 600 ~/.ssh/config