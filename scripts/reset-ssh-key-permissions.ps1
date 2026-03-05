function Reset-SshKeyPermissions {
# Name: reset-ssh-key-permissions
# Tags: ssh
# Saved: 2026-03-02T18:45:14.9905172+00:00
<#
.SYNOPSIS
Resets NTFS permissions on a private SSH key file.

.DESCRIPTION
Removes inherited ACLs, grants full control to the specified identity, and
removes broad group permissions commonly rejected by SSH clients.

.PARAMETER KeyPath
Path to the private key file. Defaults to $HOME\.ssh\id_rsa.

.PARAMETER Identity
Account to grant full control (DOMAIN\User or Machine\User format).

.EXAMPLE
Reset-SshKeyPermissions

.EXAMPLE
Reset-SshKeyPermissions -KeyPath $HOME\.ssh\id_ed25519 -Identity 'CONTOSO\alice'

.OUTPUTS
PSCustomObject
#>
[OutputType([PSCustomObject])]
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$KeyPath = "$env:USERPROFILE\.ssh\id_rsa",

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$Identity = "${env:USERDOMAIN}\${env:USERNAME}"
)

if (-not (Test-Path -LiteralPath $KeyPath -PathType Leaf)) {
    throw "Key file '$KeyPath' was not found."
}

if (-not $PSCmdlet.ShouldProcess($KeyPath, "Reset SSH private key ACL for $Identity")) {
    return
}

& icacls $KeyPath /inheritance:r | Out-Null
& icacls $KeyPath /grant:r "$Identity`:(F)" | Out-Null
& icacls $KeyPath /remove:g 'Everyone' 'BUILTIN\Users' 'NT AUTHORITY\Authenticated Users' | Out-Null

[pscustomobject]@{
    KeyPath  = $KeyPath
    Identity = $Identity
    Updated  = $true
}
}

# When run directly as a script, execute the function.
# When dot-sourced/imported, only define the function.
if ($MyInvocation.InvocationName -ne ".") {
    Reset-SshKeyPermissions
}
