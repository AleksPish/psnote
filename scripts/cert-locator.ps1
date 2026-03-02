# Name: cert-locator
# Tags: certs
# Saved: 2026-03-02T18:45:14.9905172+00:00
﻿$servers = get-ADComputer -Filter 'operatingsystem -like "*server*" -and enabled -eq "true"' | Select-Object -expandproperty name
 
# Input file
#$Servers = Get-Content "C:\users\$env:username\desktop\servers.txt"
$ErrorActionPreference = 'Stop'
 
# Searching phrase
$CertificateName = Read-Host "Enter in the certificate name you need to find: eg domain.co.uk"
 
# Looping each server 
foreach($Server in $Servers)
{   
    Write-Host Processing $Server -ForegroundColor yellow
     
    Try
    {
        # Checking hostname of a server provided in input file 
        $hostname = ([System.Net.Dns]::GetHostByName("$Server")).hostname
   
        # Querying for certificates
        $Certs = Invoke-Command $Server -ScriptBlock{ Get-ChildItem Cert:\LocalMachine\My }
    }
    Catch
    {
        $_.Exception.Message
        Continue
    }
      
    If($hostname -and $Certs)
    {
        Foreach($Cert in $Certs)
        {
            $Object = ($Cert | Select-Object Subject,PSComputerName,Issuer,NotAfter,Thumbprint | where-object {$_.Subject -Like "*$CertificateName*"})
            
            $Object | Export-CSV -Path C:\temp\results.csv -Append -NoTypeInformation

            if($null -ne $Object ){
                Write-host $Object
                }
        }
    } 
    Else
    {
        Write-Warning "An Error has occurred!"
    }
}
