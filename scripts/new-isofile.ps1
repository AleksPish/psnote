# Name: new-isofile
# Tags: tools,iso
# Saved: 2026-03-03T13:59:49.0557292+00:00
function New-IsoFile
{
  <#
   .SYNOPSIS
    Creates a new .iso file from files and folders.

   .DESCRIPTION
    The New-IsoFile cmdlet creates an ISO image using IMAPI2.
    You can pass source paths through the pipeline, provide them directly, or use items from the clipboard.

   .PARAMETER Source
    File system path(s), FileInfo object(s), or DirectoryInfo object(s) to include in the ISO image.

   .PARAMETER Path
    Output .iso path. Defaults to a timestamped file under $env:TEMP.

   .PARAMETER BootFile
    Optional boot image file to create a bootable ISO.

   .PARAMETER Media
    IMAPI media type used to select default image settings.

   .PARAMETER Title
    Volume label for the ISO image.

   .PARAMETER Force
    Overwrites the target ISO if it already exists.

   .PARAMETER FromClipboard
    Uses Explorer clipboard file-drop entries as source input.

   .EXAMPLE
    New-IsoFile -Source 'C:\Tools','C:\Downloads\Utils'

   .EXAMPLE
    New-IsoFile -FromClipboard -Verbose

   .EXAMPLE
    Get-ChildItem C:\WinPE | New-IsoFile -Path C:\Temp\WinPE.iso -BootFile "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\efisys.bin" -Media DVDPLUSR -Title WinPE

   .OUTPUTS
    System.IO.FileInfo

   .NOTES
    Original script by Chris Wu:
    https://github.com/wikijm/PowerShell-AdminScripts/blob/master/Miscellaneous/New-IsoFile.ps1

    Script modified by Aleks Pace to add compatibility with newer PowerShell versions, support for additional media types, and improved error handling.
 #>

  [CmdletBinding(DefaultParameterSetName='Source')]
  Param(
    [Parameter(Position=0, Mandatory=$true, ValueFromPipeline=$true, ParameterSetName='Source')]
    [object[]]$Source,

    [Parameter(Position=1)]
    [ValidateNotNullOrEmpty()]
    [string]$Path = "$env:TEMP\$((Get-Date).ToString('yyyyMMdd-HHmmss.ffff')).iso",

    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$BootFile = $null,

    [ValidateSet('CDR','CDRW','DVDRAM','DVDPLUSR','DVDPLUSRW','DVDPLUSR_DUALLAYER','DVDDASHR','DVDDASHRW','DVDDASHR_DUALLAYER','DISK','DVDPLUSRW_DUALLAYER','BDR','BDRE')]
    [string]$Media = 'DVDPLUSRW_DUALLAYER',

    [string]$Title = (Get-Date).ToString('yyyyMMdd-HHmmss.ffff'),

    [switch]$Force,

    [Parameter(Mandatory=$true, ParameterSetName='Clipboard')]
    [switch]$FromClipboard
  )

  Begin {
    if (-not $IsWindows) {
      throw 'New-IsoFile requires Windows because it depends on IMAPI2 COM components.'
    }

    $hadInput = $false
    $hadAddErrors = $false
    $isoCreated = $false
    $Stream = $null
    $Boot = $null
    $Image = $null
    $Target = $null

    if (-not ('ISOFile' -as [type])) {
      Add-Type -TypeDefinition @'
public class ISOFile
{
  public static void Create(string path, object stream, int blockSize, int totalBlocks)
  {
    byte[] buf = new byte[blockSize];
    var input = stream as System.Runtime.InteropServices.ComTypes.IStream;
    if (input == null) {
      throw new System.ArgumentException("Stream must be IStream", "stream");
    }

    System.IntPtr bytesRead = System.Runtime.InteropServices.Marshal.AllocHGlobal(sizeof(int));
    try {
      using (var output = System.IO.File.Open(path, System.IO.FileMode.Create, System.IO.FileAccess.Write, System.IO.FileShare.None)) {
        while (totalBlocks-- > 0) {
          System.Runtime.InteropServices.Marshal.WriteInt32(bytesRead, 0);
          input.Read(buf, blockSize, bytesRead);
          int bytes = System.Runtime.InteropServices.Marshal.ReadInt32(bytesRead);
          if (bytes <= 0) { break; }
          output.Write(buf, 0, bytes);
        }
        output.Flush();
      }
    }
    finally {
      System.Runtime.InteropServices.Marshal.FreeHGlobal(bytesRead);
    }
  }
}
'@
    }

    if ($BootFile) {
      if ('BDR','BDRE' -contains $Media) {
        Write-Warning "Bootable image does not reliably work with media type '$Media'."
      }

      $Stream = New-Object -ComObject ADODB.Stream -Property @{ Type = 1 } # adFileTypeBinary
      $Stream.Open()
      $Stream.LoadFromFile((Get-Item -LiteralPath $BootFile).FullName)
      $Boot = New-Object -ComObject IMAPI2FS.BootOptions
      $Boot.AssignBootImage($Stream)
    }

    $MediaType = @(
      'UNKNOWN','CDROM','CDR','CDRW','DVDROM','DVDRAM','DVDPLUSR','DVDPLUSRW','DVDPLUSR_DUALLAYER',
      'DVDDASHR','DVDDASHRW','DVDDASHR_DUALLAYER','DISK','DVDPLUSRW_DUALLAYER','HDDVDROM','HDDVDR',
      'HDDVDRAM','BDROM','BDR','BDRE'
    )

    $mediaValue = $MediaType.IndexOf($Media)
    Write-Verbose -Message "Selected media type is $Media with value $mediaValue"

    $Image = New-Object -ComObject IMAPI2FS.MsftFileSystemImage -Property @{ VolumeName = $Title }
    $Image.ChooseImageDefaultsForMediaType($mediaValue)

    $parent = Split-Path -Path $Path -Parent
    if ([string]::IsNullOrWhiteSpace($parent)) {
      $parent = (Get-Location).Path
    }

    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
      throw "Cannot create file '$Path' because parent directory '$parent' does not exist."
    }

    try {
      $Target = New-Item -Path $Path -ItemType File -Force:$Force -ErrorAction Stop
    }
    catch {
      throw "Cannot create file '$Path': $($_.Exception.Message)"
    }
  }

  Process {
    if ($FromClipboard) {
      if ($PSVersionTable.PSVersion.Major -lt 5) {
        throw 'The -FromClipboard parameter is only supported on PowerShell v5 or higher.'
      }

      $Source = Get-Clipboard -Format FileDropList
      if (-not $Source) {
        throw 'Clipboard does not contain any files or folders.'
      }
    }

    foreach ($entry in $Source) {
      if ($null -eq $entry) {
        continue
      }

      $hadInput = $true
      try {
        $item = $entry
        if ($item -isnot [System.IO.FileSystemInfo]) {
          $item = Get-Item -LiteralPath $item -ErrorAction Stop
        }

        Write-Verbose -Message "Adding item to target image: $($item.FullName)"

        if ($item -is [System.IO.DirectoryInfo]) {
          $Image.Root.AddTree($item.FullName, $true)
        }
        elseif ($item -is [System.IO.FileInfo]) {
          $fileStream = New-Object -ComObject ADODB.Stream -Property @{ Type = 1 } # adFileTypeBinary
          try {
            $fileStream.Open()
            $fileStream.LoadFromFile($item.FullName)
            $Image.Root.AddFile($item.Name, $fileStream)
          }
          finally {
            try { $fileStream.Close() } catch { }
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject($fileStream)
          }
        }
        else {
          throw "Unsupported item type '$($item.GetType().FullName)'."
        }
      }
      catch {
        $hadAddErrors = $true
        Write-Error -Message ("Failed to add '{0}': {1}" -f $entry, $_.Exception.Message)
      }
    }
  }

  End {
    try {
      if (-not $hadInput) {
        throw 'No source files or folders were provided.'
      }

      if ($hadAddErrors) {
        throw 'One or more input items could not be added. ISO creation aborted.'
      }

      if ($Boot) {
        $Image.BootImageOptions = $Boot
      }

      $Result = $Image.CreateResultImage()
      [ISOFile]::Create($Target.FullName, $Result.ImageStream, $Result.BlockSize, $Result.TotalBlocks)
      $isoCreated = $true

      Write-Verbose -Message "Target image '$($Target.FullName)' has been created."
      $Target
    }
    finally {
      if (-not $isoCreated -and $Target -and (Test-Path -LiteralPath $Target.FullName -PathType Leaf)) {
        Remove-Item -LiteralPath $Target.FullName -Force -ErrorAction SilentlyContinue
      }

      if ($Stream) {
        try { $Stream.Close() } catch { }
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($Stream)
      }

      if ($Boot) {
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($Boot)
      }

      if ($Image) {
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($Image)
      }
    }
  }
}

# When run directly as a script, execute the function.
# When dot-sourced/imported, only define the function.
if ($MyInvocation.InvocationName -ne ".") {
    New-IsoFile
}
