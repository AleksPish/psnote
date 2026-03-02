# Name: reset-ssh-key-permissions
# Tags: ssh
# Saved: 2026-03-02T18:45:14.9905172+00:00

$key = "$env:USERPROFILE\.ssh\id_rsa"
icacls $key /inheritance:r
icacls $key /grant:r "${env:USERDOMAIN}\${env:USERNAME}:(F)"
icacls $key /remove:g "Everyone" "BUILTIN\Users" "NT AUTHORITY\Authenticated Users"
