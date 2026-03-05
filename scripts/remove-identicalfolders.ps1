# Name: remove-identicalfolders
# Tags: file
# Saved: 2026-03-03T14:16:51.5112165+00:00
function Remove-IdenticalFolders {
  <#
  .SYNOPSIS
  Removes folders in a target path when folder names match folders in a reference path.

  .DESCRIPTION
  Compares immediate child directories in ReferencePath against immediate child directories in TargetPath.
  If a matching directory name exists in TargetPath, it is removed recursively.
  Supports -WhatIf and -Confirm.

  .PARAMETER ReferencePath
  Directory whose child folder names are used as the comparison set.

  .PARAMETER TargetPath
  Directory from which matching child folders are deleted.

  .EXAMPLE
  Remove-IdenticalFolders -ReferencePath C:\Ref -TargetPath D:\Data -WhatIf

  .EXAMPLE
  Remove-IdenticalFolders -ReferencePath C:\Ref -TargetPath D:\Data -Confirm

  .OUTPUTS
  PSCustomObject
  #>
  [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High')]
  param(
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$ReferencePath,

    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$TargetPath
  )

  Set-StrictMode -Version Latest

  $resolvedReference = Resolve-Path -LiteralPath $ReferencePath -ErrorAction Stop
  $resolvedTarget = Resolve-Path -LiteralPath $TargetPath -ErrorAction Stop

  if (-not (Test-Path -LiteralPath $resolvedReference -PathType Container)) {
    throw "ReferencePath '$ReferencePath' is not a directory."
  }

  if (-not (Test-Path -LiteralPath $resolvedTarget -PathType Container)) {
    throw "TargetPath '$TargetPath' is not a directory."
  }

  $referenceFolderNames = Get-ChildItem -LiteralPath $resolvedReference -Directory -ErrorAction Stop |
    Select-Object -ExpandProperty Name

  $results = foreach ($name in $referenceFolderNames) {
    $candidate = Join-Path -Path $resolvedTarget -ChildPath $name
    if (-not (Test-Path -LiteralPath $candidate -PathType Container)) {
      [PSCustomObject]@{
        FolderName = $name
        TargetPath = $candidate
        Action     = 'NotFound'
      }
      continue
    }

    if ($PSCmdlet.ShouldProcess($candidate, 'Remove matching folder')) {
      Remove-Item -LiteralPath $candidate -Recurse -Force -ErrorAction Stop
      [PSCustomObject]@{
        FolderName = $name
        TargetPath = $candidate
        Action     = 'Removed'
      }
    }
    else {
      [PSCustomObject]@{
        FolderName = $name
        TargetPath = $candidate
        Action     = 'Skipped'
      }
    }
  }

  $results
}

# When run directly as a script, execute the function.
# When dot-sourced/imported, only define the function.
if ($MyInvocation.InvocationName -ne ".") {
    Remove-IdenticalFolders
}
