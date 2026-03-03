# Name: get-terminalserver-ssl-cert
# Tags: remotedesktop
# Saved: 2026-03-03T09:38:05.9797951+00:00
#Get terminal server SSL certificate thumbprint
#This script retrieves the SSL certificate thumbprint for the RDP connection on a terminal server.

(Get-WmiObject -class "Win32_TSGeneralSetting" -Namespace root\cimv2\terminalservices -Filter "TerminalName='RDP-tcp'").SSLCertificateSHA1Hash 
