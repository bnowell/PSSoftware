﻿<#	
===========================================================================
 Created on:   	6/23/2014 4:18 PM
 Created by:   	Adam Bertram
 Filename:     	SoftwareInstallManager.psm1
 Version:		0.2
 Changelog:		08/11/2014
					- Added MSI module import if not found for the 
					Uninstall-WindowsInstallerPackage function.
					- Changed Get-MsiProduct cmdlet to correct
					Get-MsiProductInfo cmdlet reference in the 
					Uninstall-WindowsInstallerPackage function
					- Changed references to Get-InstalledSoftware to just
					test for software installed to the new
					Validate-IsSoftwareInstalled function.
					- Added automatic sub-module loading
					- Modified various log output strings
				08/28/2014
					- Added the Set-InstalledSoftware function which included
					the InstallFolderACL parameter set
				08/29/2014
					- Modified Stop-MyProcess to accept multiple process names
					- Removed all Export-ModuleMember lines to enable all
					functions to be available
					- Modified the Get-UserProfile function to search by
					SID and by username.  It will also get all profiles now.
					- Added the Remove-ItemFromAllUserProfiles function
					- Modifed the Write-Log function so that functions called
					interactively or without Start-Log will work.
					- Fixed multiple bugs in the MSI installer part of 
					Install-Software function.
				09/02/2014 - Created the GUID conversion functions.
				09/03/2014 - Created the Set-MyFileSystemAcl function
				09/05/2014 
					- Added the ALLUSERS=1 switch for all MSI installers
					in the Install-Software function.
				09/08/2014 
					- Made the Set-RegistryValueForAllUsers function advanced.
					- Made the reg unload outside of the hash table loop
				09/09/201
					- Added the KillProcess param to Install-Software
					
-------------------------------------------------------------------------
 Module Name: SoftwareInstallManager
===========================================================================
#>

function Get-OperatingSystem {
	(Get-WmiObject -Query "SELECT Caption,CSDVersion FROM Win32_OperatingSystem").Caption
}

## When SoftwareInstallManager module is imported, it requires other modules
## to use some functions.
## TODO: This needs to point to a single parent directory and import all
## modules within
$ChildModulesPath = '\\configmanager\deploymentmodules'
if (!(Test-Path "$ChildModulesPath\MSI")) {
	Write-Log -Message "Required MSI module is not available" -LogLevel '3'
	exit
} elseif ((Get-OperatingSystem) -notmatch 'XP') {
	Import-Module "$ChildModulesPath\MSI"
}


function Write-Log {
	<#
	.SYNOPSIS
		This function creates or appends a line to a log file

	.DESCRIPTION
		This function writes a log line to a log file in the form synonymous with 
		ConfigMgr logs so that tools such as CMtrace and SMStrace can easily parse 
		the log file.  It uses the ConfigMgr client log format's file section
		to add the line of the script in which it was called.

	.PARAMETER  Message
		The message parameter is the log message you'd like to record to the log file

	.PARAMETER  LogLevel
		The logging level is the severity rating for the message you're recording. Like ConfigMgr
		clients, you have 3 severity levels available; 1, 2 and 3 from informational messages
		for FYI to critical messages that stop the install. This defaults to 1.

	.EXAMPLE
		PS C:\> Write-Log -Message 'Value1' -LogLevel 'Value2'
		This example shows how to call the Write-Log function with named parameters.

	.NOTES

	#>
	[CmdletBinding()]
	param (
		[Parameter(
				   Mandatory = $true)]
		[string]$Message,
		[Parameter()]
		[ValidateSet(1, 2, 3)]
		[int]$LogLevel = 1
	)
	
	try {
		$TimeGenerated = "$(Get-Date -Format HH:mm:ss).$((Get-Date).Millisecond)+000"
		## Build the line which will be recorded to the log file
		$Line = '<![LOG[{0}]LOG]!><time="{1}" date="{2}" component="{3}" context="" type="{4}" thread="" file="">'
		$LineFormat = $Message, $TimeGenerated, (Get-Date -Format MM-dd-yyyy), "$($MyInvocation.ScriptName | Split-Path -Leaf):$($MyInvocation.ScriptLineNumber)", $LogLevel
		$Line = $Line -f $LineFormat
		
		## Record the line to the log file if it's declared.  If not, just write to Verbose stream
		## This is helpful when using these functions interactively when you don't preface a function
		## with a Write-Log entry with Start-Log to create the $ScriptLogFilePath variable
		if (Test-Path variable:\ScriptLogFilePath) {
			Add-Content -Value $Line -Path $ScriptLogFilePath
		} else {
			Write-Verbose $Line	
		}
	} catch {
		Write-Error $_.Exception.Message
	}
}

function Start-Log {
	<#
	.SYNOPSIS
		This function creates the initial log file and sets a few global variables
		that are common among the session.  Call this function at the very top of your
		installer script.

	.PARAMETER  FilePath
		The file path where you'd like to place the log file on the file system.  If no file path
		specified, it will create a file in the system's temp directory named the same as the script
		which called this function with a .log extension.

	.EXAMPLE
		PS C:\> Start-Log -FilePath 'C:\Temp\installer.log

	.NOTES

	#>
	[CmdletBinding()]
	param (
		[ValidateScript({ Split-Path $_ -Parent | Test-Path })]
		[string]$FilePath = "$([environment]::GetEnvironmentVariable('TEMP','Machine'))\$((Get-Item $MyInvocation.ScriptName).Basename + '.log')"
	)
	
	try {
		if (!(Test-Path $FilePath)) {
			## Create the log file
			New-Item $FilePath -Type File | Out-Null
		}
		
		## Set the global variable to be used as the FilePath for all subsequent Write-Log
		## calls in this session
		$global:ScriptLogFilePath = $FilePath
	} catch {
		Write-Error $_.Exception.Message
	}
}

function Validate-IsSoftwareInstalled ($ProductName) {
	if (!(Get-InstalledSoftware $ProductName)) {
		Write-Log -Message "'$ProductName' is NOT installed."
		$false
	} else {
		Write-Log -Message "'$ProductName' IS installed."
		$true
	}
}

function Validate-IsIssFileValid($IssFilePath, $Guid) {
	## The ISS file is valid for the GUID if the GUID is anywhere in the ISS file
	## This isn't the best way to do it but it's better than nothing
	if ((Get-Content $IssFilePath) -match $Guid) {
		$true
	} else {
		$false	
	}
}

function Get-RootUserProfileFolderPath {
	(Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -Name ProfilesDirectory).ProfilesDirectory
}

function Get-AllUsersProfileFolderPath {
	$env:ALLUSERSPROFILE
}

function Get-AllUsersDesktopFolderPath {
	$Shell = New-Object -ComObject "WScript.Shell"
	$Shell.SpecialFolders.Item('AllUsersDesktop')
}

function Get-InstallerType ($UninstallString) {
	Write-Debug "Initiating the $($MyInvocation.MyCommand.Name) function...";
	if ($UninstallString -imatch 'msiexec.exe') {
		'Windows Installer'
	} elseif ($UninstallString -imatch 'InstallShield Installation') {
		'InstallShield'
	} else {
		$false	
	}
}

function Get-32BitProgramFilesPath {
	if ((Get-Architecture) -eq 'x64') {
		${env:ProgramFiles(x86)}
	} else {
		$env:ProgramFiles
	}
}

function Get-InstallLocation ($ProductName) {
	Write-Verbose "Initiating the $($MyInvocation.MyCommand.Name) function...";
	Write-Log -Message "Checking WMI for install location for $ProductName..."
	$SoftwareInstance = Get-InstalledSoftware -Name $Productname
	if ($SoftwareInstance.InstalledLocation) {
		$SoftwareInstance.InstalledLocation
	} else {
		Write-Log -Message 'Install location not found in WMI.  Checking registry...'
		Write-Log -Message "Checking for installer reg keys for $ProductName..."
		$UninstallRegKey = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall'
		$InstallerRegKeys = Get-ChildItem $UninstallRegKey | where { $_.GetValue('DisplayName') -imatch $ProductName }
		if (!$InstallerRegKeys) {
			Write-Log -Message "No matches for $ProductName in registry"
		} else {
			Write-Log -Message "Found $($InstallerRegKeys.Count) installer registry keys..."
			$Processes = @()
			Write-Log -Message "Checking for processes in install folder...."
			foreach ($Key in $InstallerRegKeys) {
				$InstallFolderPath = $Key.GetValue('InstallLocation')
				if (!$InstallFolderPath -and (($Key.GetValue('UninstallString') -match '\w:\\([a-zA-Z0-9 _.(){}-]+\\)+'))) {
					Write-Log -Message 'No install location found but did find a file path in the uninstall string...'
					($Matches.Values | select -Unique | where { Test-Path $_ }).TrimEnd('\')
				} elseif ($InstallFolderPath) {
					$InstallFolderPath
				} else {
					Write-Log -Message "Could not find the install folder path" -LogLevel '2'
				}
			}
		}
	}
}

function Import-Certificate {
	<#
	.SYNOPSIS
		This function imports a certificate into any certificate store on a local computer
	.NOTES
		Created on: 	8/6/2014
		Created by: 	Adam Bertram
		Filename:		Import-Certificate.ps1
	.EXAMPLE
		PS> .\Import-Certificate.ps1 -Location LocalMachine -StoreName My -FilePath C:\certificate.cer

		This example will import the certificate.cert certificate into the Personal store for the 
		local computer
	.EXAMPLE
		PS> .\Import-Certificate.ps1 -Location CurrentUser -StoreName TrustedPublisher -FilePath C:\certificate.cer

		This example will import the certificate.cer certificate into the Trusted Publishers store for the 
		currently logged on user
	.PARAMETER Location
	 	This is the location (either CurrentUser or LocalMachine) where the store is located which the certificate
		will go into
	.PARAMETER StoreName
		This is the certificate store that the certificate will be placed into
	.PARAMETER FilePath
		This is the path to the certificate file that you'd like to import
	#>
	[CmdletBinding()]
	[OutputType()]
	param (
		[Parameter(Mandatory=$true)]
		[ValidateSet('CurrentUser', 'LocalMachine')]
		[string]$Location,
		[Parameter(Mandatory=$true)]
		[ValidateScript({
			if ($Location -eq 'CurrentUser') {
				(Get-ChildItem Cert:\CurrentUser | select -ExpandProperty name) -contains $_
			} else {
				(Get-ChildItem Cert:\LocalMachine | select -ExpandProperty name) -contains $_
			}
		})]
		[string]$StoreName,
		[Parameter(Mandatory=$true)]
		[ValidateScript({ Test-Path $_ -PathType Leaf })]
		[string]$FilePath
	)
	
	begin {
		$ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop
		Set-StrictMode -Version Latest
		try {
			[void][System.Reflection.Assembly]::LoadWithPartialName("System.Security")
		} catch {
			Write-Error $_.Exception.Message
		}
	}
	
	process {
		try {
			$Cert = Get-Item $FilePath
			$Cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $Cert
			foreach ($Store in $StoreName) {
				$X509Store = New-Object System.Security.Cryptography.X509Certificates.X509Store $Store, $Location
				$X509Store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
				$X509Store.Add($Cert)
				$X509Store.Close()
			}
		} catch {
			Write-Error $_.Exception.Message
		}
	}
}

function Get-Architecture {
	if ([System.Environment]::Is64BitOperatingSystem) {
		'x64'
	} else {
		'x86'
	}
}

function Get-ProfileSids {
	(Get-Childitem 'HKLM:\Software\Microsoft\Windows NT\CurrentVersion\ProfileList' | Where { ($_.Name -match 'S-\d-\d+-(\d+-){1,14}\d+$') }).PSChildName
}

function Get-UserProfilePath {
	<#
	.SYNOPSIS
		This function find the folder path of a user profile based off of a number of different criteria.  If no criteria is
		used, it will return all user profile paths.
	.EXAMPLE
		PS> .\Get-UserProfilePath -Sid 'S-1-5-21-350904792-1544561288-1862953342-32237'
	
		This example finds the user profile path based on the user's SID
	.EXAMPLE
		PS> .\Get-UserProfilePath -Username 'bob'
	
		This example finds the user profile path based on the username
	.PARAMETER Sid
	 	The user SID
	.PARAMETER Username
		The username
	#>
	[CmdletBinding(DefaultParameterSetName = 'None')]
	param (
		[Parameter(ParameterSetName = 'SID')]
		[string]$Sid,
		[Parameter(ParameterSetName = 'Username')]
		[string]$Username
	)
	
	process {
		if ($Sid) {
			$WhereBlock = { $_.PSChildName -eq $Sid }
		} elseif ($Username) {
			$WhereBlock = { $_.GetValue('ProfileImagePath').Split('\')[-1] -eq $Username }
		} else {
			$WhereBlock = { $_.PSChildName -ne $null }
		}
		Get-ChildItem 'HKLM:\Software\Microsoft\Windows NT\CurrentVersion\ProfileList' | where $WhereBlock | % { $_.GetValue('ProfileImagePath') }
	}
}

function Get-LoggedOnUserSID {
	New-PSDrive -Name HKU -PSProvider Registry -Root Registry::HKEY_USERS | Out-Null
	(Get-ChildItem HKU: | where { $_.Name -match 'S-\d-\d+-(\d+-){1,14}\d+$' }).PSChildName
}

function Set-RegistryValueForDefaultUser {
	[CmdletBinding()]
	param (
		[hashtable[]]$RegistryInstance
	)
	try {
		New-PSDrive -Name HKU -PSProvider Registry -Root Registry::HKEY_USERS | Out-Null
		
		foreach ($instance in $RegistryInstance) {
			if (Get-ItemProperty -Path "HKU:\.DEFAULT\$($instance.Path)" -Name $instance.Name -ea SilentlyContinue) {
				Set-ItemProperty -Path "HKU:\.DEFAULT\$($instance.Path)" -Name $instance.Name -Value $instance.Value -Force
			} else {
				Write-Log -Message "Registry value $($instance.name) does not exist in HKU:\.DEFAULT\$($instance.Path)" -LogLevel '2'
			}
		}
	} catch {
		Write-Log -Message $_.Exception.Message -LogLevel '3'
	}
}

function Set-RegistryValueForAllUsers {
    <#
	.SYNOPSIS
		This function finds all of the user profile registry hives, mounts them and changes (or adds) a registry value for each user.
	.EXAMPLE
		PS> Set-RegistryValueForAllUsers -RegistryInstance @{'Name' = 'Setting'; 'Type' = 'String'; 'Value' = 'someval'; 'Path' = 'SOFTWARE\Microsoft\Windows\Something'}
	
		This example would modify the string registry value 'Type' in the path 'SOFTWARE\Microsoft\Windows\Something' to 'someval'
		for every user registry hive.
	.PARAMETER RegistryInstance
	 	A hash table containing key names of 'Name' designating the registry value name, 'Type' to designate the type
		of registry value which can be 'String,Binary,Dword,ExpandString or MultiString', 'Value' which is the value itself of the
		registry value and 'Path' designating the parent registry key the registry value is in.
	#>
	[CmdletBinding()]
	param (
		[Parameter(Mandatory=$true)]
		[hashtable[]]$RegistryInstance
	)
	try {
		Start-Log
		New-PSDrive -Name HKU -PSProvider Registry -Root Registry::HKEY_USERS | Out-Null
		
		## Change the registry values for the currently logged on user
		$LoggedOnSids = Get-LoggedOnUserSID
		Write-Log -Message "Found $($LoggedOnSids.Count) logged on user SIDs"
		foreach ($sid in $LoggedOnSids) {
			Write-Log -Message "Loading the user registry hive for the logged on SID $sid"
			foreach ($instance in $RegistryInstance) {
				if (Get-ItemProperty -Path "HKU:\$sid\$($instance.Path)" -Name $instance.Name -ea SilentlyContinue) {
					Write-Log -Message "Key name '$($instance.name)' exists at 'HKU:\$sid\$($instance.Path)'"
					Set-ItemProperty -Path "HKU:\$sid\$($instance.Path)" -Name $instance.Name -Value $instance.Value -Type $instance.Type -Force
				} else {
					Write-Log -Message "Registry value $($instance.name) does not exist in HKU:\$sid\$($instance.Path)" -LogLevel '2'
				}
			}
		}

		## Modify registry hives for all user profiles
		## Read all ProfileImagePath values from all reg keys that match a SID pattern in the ProfileList key
		## Exclude all SIDs from the users that are currently logged on.  Those have already been processed.
		$ProfileSids = Get-ProfileSids
		Write-Log -Message "Found $($ProfileSids.Count) SIDs for profiles"
		$ProfileSids = $ProfileSids | where { $LoggedOnSids -notcontains $_ }
		
		$ProfileFolderPaths = $ProfileSids | foreach { Get-UserProfilePath -Sid $_ }
		
		if ((Get-Architecture) -eq 'x64') {
			$RegPath = 'syswow64'
		} else {
			$RegPath = 'System32'
		}
		Write-Log -Message "Reg.exe path is $RegPath"
		
		## Load each user's registry hive into the HKEY_USERS\TempUserLoad key
		foreach ($prof in $ProfileFolderPaths) {
			Write-Log -Message "Loading the user registry hive in the $prof profile"
			$Process = Start-Process "$($env:Systemdrive)\Windows\$RegPath\reg.exe" -ArgumentList "load HKEY_USERS\TempUserLoad `"$prof\NTuser.dat`"" -Wait -NoNewWindow -PassThru
			if (Check-Process $Process) {
				foreach ($instance in $RegistryInstance) {
					Write-Log -Message "Setting property in the HKU\$($instance.Path) path to `"$($instance.Name)`" and value `"$($instance.Value)`""
					if (Get-ItemProperty -Path "HKU:\TempUserLoad\$($instance.Path)" -Name $instance.Name -ea SilentlyContinue) {
						Set-ItemProperty -Path "HKU:\TempUserLoad\$($instance.Path)" -Name $instance.Name -Value $instance.Value -Type $instance.Type -Force
					} else {
						Write-Log -Message "Registry value $($instance.name) does not exist in HKU:\TempUserLoad\$($instance.Path)" -LogLevel '2'
					}
				}
				$Process = Start-Process "$($env:Systemdrive)\Windows\$RegPath\reg.exe" -ArgumentList "unload HKEY_USERS\TempUserLoad" -Wait -NoNewWindow -PassThru
				Check-Process $Process | Out-Null
			} else {
				Write-Log -Message "Failed to load registry hive for the '$prof' profile" -LogLevel '3'
			}
		}
	} catch {
		Write-Log -Message $_.Exception.Message -LogLevel '3'
	}
}

function Get-RegistryValueForAllUsers {
    <#
	.SYNOPSIS
		This function finds all of the user profile registry hives, mounts them and retrieves a registry value for each user.
	.EXAMPLE
		PS> Get-RegistryValueForAllUsers -RegistryInstance @{'Name' = 'Setting'; 'Path' = 'SOFTWARE\Microsoft\Windows\Something'}
	
		This example would get the string registry value 'Type' in the path 'SOFTWARE\Microsoft\Windows\Something'
		for every user registry hive.
	.PARAMETER RegistryInstance
	 	A hash table containing key names of 'Name' designating the registry value name and 'Path' designating the parent 
		registry key the registry value is in.
	#>
	[CmdletBinding()]
	param (
		[Parameter(Mandatory=$true)]
		[hashtable[]]$RegistryInstance
	)
	try {
		Start-Log
		New-PSDrive -Name HKU -PSProvider Registry -Root Registry::HKEY_USERS | Out-Null
		
		## Find the registry values for the currently logged on user
		$LoggedOnSids = Get-LoggedOnUserSID
		Write-Log -Message "Found $($LoggedOnSids.Count) logged on user SIDs"
		foreach ($sid in $LoggedOnSids) {
			Write-Log -Message "Loading the user registry hive for the logged on SID $sid"
			foreach ($instance in $RegistryInstance) {
				$Value = Get-ItemProperty -Path "HKU:\$sid\$($instance.Path)" -Name $instance.Name -ea SilentlyContinue
				if (!$Value) {
					Write-Log -Message "Registry value $($instance.name) does not exist in HKU:\$sid\$($instance.Path)" -LogLevel '2'	
				} else {
					$Value
				}
			}
		}
		
		## Read all ProfileImagePath values from all reg keys that match a SID pattern in the ProfileList key
		## Exclude all SIDs from the users that are currently logged on.  Those have already been processed.
		$ProfileSids = Get-ProfileSids
		Write-Log -Message "Found $($ProfileSids.Count) SIDs for profiles"
		$ProfileSids = $ProfileSids | where { $LoggedOnSids -notcontains $_ }
		
		$ProfileFolderPaths = $ProfileSids | foreach { Get-UserProfilePath -Sid $_ }
		
		if ((Get-Architecture) -eq 'x64') {
			$RegPath = 'syswow64'
		} else {
			$RegPath = 'System32'
		}
		Write-Log -Message "Reg.exe path is $RegPath"
		
		## Load each user's registry hive into the HKEY_USERS\TempUserLoad key
		foreach ($prof in $ProfileFolderPaths) {
			Write-Log -Message "Loading the user registry hive in the $prof profile"
			$Process = Start-Process "$($env:Systemdrive)\Windows\$RegPath\reg.exe" -ArgumentList "load HKEY_USERS\TempUserLoad `"$prof\NTuser.dat`"" -Wait -NoNewWindow -PassThru
			if (Check-Process $Process) {
				foreach ($instance in $RegistryInstance) {
					Write-Log -Message "Finding property in the HKU\$($instance.Path) path"
					$Value = Get-ItemProperty -Path "HKU:\TempUserLoad\$($instance.Path)" -Name $instance.Name -ea SilentlyContinue
					if (!$Value) {
						Write-Log -Message "Registry value $($instance.name) does not exist in HKU:\TempUserLoad\$($instance.Path)" -LogLevel '2'
					} else {
						$Value
					}
				}
				$Process = Start-Process "$($env:Systemdrive)\Windows\$RegPath\reg.exe" -ArgumentList "unload HKEY_USERS\TempUserLoad" -Wait -NoNewWindow -PassThru
				Check-Process $Process | Out-Null
			} else {
				Write-Log -Message "Failed to load registry hive for the '$prof' profile" -LogLevel '3'
			}
		}
	} catch {
		Write-Log -Message $_.Exception.Message -LogLevel '3'
	}
}

function Check-Error($MyError, $SuccessString) {
	Write-Debug "Initiating the $($MyInvocation.MyCommand.Name) function...";
	if ($MyError) {
		Write-Log -Message $MyError.Exception.Message -LogLevel '2'
	} else {
		Write-Log -Message $SuccessString
	}
}

function Check-Process ([System.Diagnostics.Process]$Process) {
	if ($Process.ExitCode -ne 0) {
		Write-Log -Message "Process ID $($Process.Id) failed. Return value was $($Process.ExitCode)" -LogLevel '2'
		$false
	} else {
		Write-Log -Message "Successfully ran process ID $($Process.Id)."
		$true
	}
}

function Convert-ToUncPath($LocalFilePath, $Computername) {
	Write-Debug "Initiating the $($MyInvocation.MyCommand.Name) function...";
	$RemoteFilePathDrive = ($LocalFilePath | Split-Path -Qualifier).TrimEnd(':')
	"\\$Computername\$RemoteFilePathDrive`$$($LocalFilePath | Split-Path -NoQualifier)"
}

function Import-RegistryFile {
	[CmdletBinding(SupportsShouldProcess=$true)]
	[OutputType()]
	param (
		[Parameter()]
		[ValidateScript({ Test-Path -Path $_ -PathType 'Leaf'})]
		[string]$FilePath
	)
	process {
		try {
			if ($PSCmdlet.ShouldProcess($Path,'File Import')) {
				if ((Get-Architecture) -eq 'x64') {
					$RegPath = 'syswow64'
				} else {
					$RegPath = 'System32'
				}
				$Result = Start-Process "$($env:Systemdrive)\Windows\$RegPath\reg.exe" -Args "import $FilePath" -Wait -NoNewWindow -PassThru
				Check-Process -Process $Result
			}
		} catch {
			Write-Error $_.Exception.Message
		}
	}
}

function Import-RegistryFileForAllUsers {
	<#
	.SYNOPSIS
		
	.EXAMPLE
		PS>
	
		
	.PARAMETER FilePath
	 	
	#>
	[CmdletBinding(SupportsShouldProcess=$true)]
	[OutputType()]
	param (
		[Parameter()]
		[ValidateScript({ Test-Path -Path $_ -PathType 'Leaf' })]
		[string]$FilePath
	)
	begin {
		$LoggedOnUserTempRegFilePath = "$(Get-SystemTempFilePath)\loggedontempregfile.reg"
		$PerUserTempRegFile = "$(Get-SystemTempFilePath)\perusertempregfile.reg"
		Write-Log "Using the file path '$LoggedOnUserTempRegFilePath"
		Find-InTextFile -FilePath $FilePath -Find 'HKEY_LOCAL_MACHINE' -Replace "HKEY_USERS\TempUserLoad" -NewFilePath $PerUserTempRegFile
		Find-InTextFile -FilePath $PerUserTempRegFile -Find 'HKEY_CURRENT_USER' -Replace "HKEY_USERS\TempUserLoad"
	}
	process {
		try {
			Start-Log
			New-PSDrive -Name HKU -PSProvider Registry -Root Registry::HKEY_USERS | Out-Null
			
			##Import the registry settings for the currently logged on user
			$LoggedOnSids = Get-LoggedOnUserSID
			Write-Log -Message "Found $($LoggedOnSids.Count) logged on user SIDs"
			foreach ($sid in $LoggedOnSids) {
				Write-Log -Message "Processing logged on user SID $sid."
				## Remove the temp file if exists.  Each file needs to be unique for the
				## user's particular SID
				Remove-Item -Path $LoggedOnUserTempRegFilePath -ea 'SilentlyContinue'
				## Replace the HKLM refernces with HKU\$sid to match the path
				Find-InTextFile -FilePath $FilePath -Find 'HKEY_LOCAL_MACHINE' -Replace "HKEY_USERS\$sid" -NewFilePath $LoggedOnUserTempRegFilePath
				Find-InTextFile -FilePath $LoggedOnUserTempRegFilePath -Find 'HKEY_CURRENT_USER' -Replace "HKEY_USERS\$sid"
				## Once the file has the correct paths then just import like usual
				Import-RegistryFile -FilePath $LoggedOnUserTempRegFilePath
				Write-Log -Message "Finished processing logged on user SID $sid"
			}
			
			Write-Log -Message "Finding all profile SIDs"
			$ProfileSids = Get-ProfileSids
			Write-Log -Message "Found $($ProfileSids.Count) SIDs for profiles"
			$ProfileSids = $ProfileSids | where { $LoggedOnSids -notcontains $_ }
			
			$ProfileFolderPaths = $ProfileSids | foreach { Get-UserProfilePath -Sid $_ }
			
			if ((Get-Architecture) -eq 'x64') {
				$RegPath = 'syswow64'
			} else {
				$RegPath = 'System32'
			}
			Write-Log -Message "Reg.exe path is $RegPath"
			
			## Load each user's registry hive temporarily into the HKEY_USERS\TempUserLoad key
			foreach ($prof in $ProfileFolderPaths) {
				Write-Log -Message "Loading the user registry hive in the $prof profile"
				$Process = Start-Process "$($env:Systemdrive)\Windows\$RegPath\reg.exe" -ArgumentList "load HKEY_USERS\TempUserLoad `"$prof\NTuser.dat`"" -Wait -NoNewWindow -PassThru
				if (Check-Process $Process) {
					Import-RegistryFile -FilePath $PerUserTempRegFile
					$Process = Start-Process "$($env:Systemdrive)\Windows\$RegPath\reg.exe" -ArgumentList "unload HKEY_USERS\TempUserLoad" -Wait -NoNewWindow -PassThru
					Check-Process $Process | Out-Null
				} else {
					Write-Log -Message "Failed to load registry hive for the '$prof' profile" -LogLevel '3'
				}
			}
		} catch {
			Write-Log -Message $_.Exception.Message -LogLevel '3'
		}
	}
	end {
		## Clean up all temporary files created
		Remove-Item -Path $LoggedOnUserTempRegFilePath -ea 'SilentlyContinue'
		Remove-Item -Path $PerUserTempRegFile -ea 'SilentlyContinue'
	}
}

function Uninstall-ViaMsizap {
	<#
	.SYNOPSIS
		This function runs the MSIzap utility to forcefully remove and cleanup MSI-installed software
	.NOTES
		Created on:   	6/4/2014
		Created by:   	Adam Bertram
		Requirements:   The msizap utility
		Todos:			
	.DESCRIPTION
		This function runs msizap to remove software.
	.EXAMPLE
		Uninstall-ViaMsizap -MsizapFilePath C:\msizap.exe -Guid {XXXX-XXX-XXX}
		This example would attempt to remove the software registered with the GUID {XXXX-XXX-XXX}.
	.PARAMETER MsizapFilePath
		The file path where the msizap utility exists.  This can be a local or UNC path.
	.PARAMETER Guid
		The GUID of the registered software you'd like removed
	.PARAMETER Params
		Non-default params you'd like passed to msizap.  By default, "TW!" is used to remove in all user
		profiles.  This typicall doesn't need to be changed.
	.PARAMETER
		The file path where all activity will be written.
	#>
	[CmdletBinding()]
	param (
		[ValidateScript({ Test-Path $_ -PathType 'Leaf' })]
		[string]$LogFilePath,
		[ValidatePattern('\b[A-F0-9]{8}(?:-[A-F0-9]{4}){3}-[A-F0-9]{12}\b')]
		[Parameter(Mandatory = $true)]
		[string]$Guid,
		[string]$Params = 'TW!',
		[ValidateScript({ Test-Path $_ -PathType 'Leaf' })]
		[string]$MsizapFilePath = '\\deploymentshare\deploymentmodules\softwareinstallmanager\msizap.exe'
	)
	Write-Debug "Initiating the $($MyInvocation.MyCommand.Name) function...";
	Write-Log -Message "Copying $($MsizapFilePath | Split-Path -Leaf) to C:\..."
	Copy-Item $MsizapFilePath C:\ -Force
	Write-Log -Message "-Starting the process `"$MsiZapFilePath $Params $Guid`"..."
	$NewProcess = Start-Process $MsiZapFilePath -ArgumentList "$Params $Guid > $LogFilePath" -Wait -NoNewWindow
	Write-Log -Message "-Waiting for process ID $($NewProcess.ProcessID)..."
	while (Get-Process -Id $NewProcess.ProcessID -ErrorAction 'SilentlyContinue') {
		sleep 1
	}
	if ($NewProcess.ExitCode -ne 0) {
		Write-Log -Message "Msizap process ID $($NewProcess.ProcessId) failed. Return value was $($NewProcess.ExitCode)" -LogLevel '2'
	} else {
		Write-Log -Message "Successfully ran msizap process ID $($NewProcess.ProcessId)."
	}
	Write-Log -Message "Removing $MsiZapFilePath..."
	Remove-Item "C:\$($MsizapFilePath | Split-Path -Leaf)" -Force
}

function Uninstall-WindowsInstallerPackage($ProductName,$RunMsizap,$MsizapFilePath,$MsizapParams) {
	$UninstallParams = @{
		'Log' = $script:LogFilePath
		'Chain' = $true
		'Force' = $true
	}
	Write-Log -Message "Attempting to uninstall MSI package '$ProductName'..."
	Get-MSIProductInfo -Name $ProductName | Uninstall-MsiProduct @UninstallParams
	if (!(Validate-IsSoftwareInstalled $ProductName)) {
		Write-Log -Message "Successfully uninstalled MSI package '$ProductName'"
		$true
	} else {
		Write-Log -Message "Failed to uninstall MSI pacage '$ProductName'..." -LogLevel '3'
		$false
	}
}

function Uninstall-InstallShieldPackage([string[]]$ProductName, $IssFilePath, $SetupFilePath) {
	try {
		foreach ($Product in $ProductName) {
			## Find the uninstall string to find the cached setup.exe
			$Products = Get-InstalledSoftware $Product
			## If multiple products are found, remove them all
			foreach ($p in $Products) {
				$Title = $p.ARPDisplayName
				## Check to ensure anything is in the UninstallString property
				if (!$p.UninstallString) {
					Write-Log -Message "No uninstall string found for product $Title" -LogLevel '2'
				} elseif ($p.UninstallString -match '(\w:\\[a-zA-Z0-9 _.() { }-]+\\.*.exe)+') {
					## Test to ensure the cached setup.exe exists
					if (!(Test-Path $Matches[0])) {
						Write-Log -Message "Installer file path not found in $($p.UninstallString) or cannot be found on the file system" -LogLevel '2'
					} else {
						$InstallerFilePath = $Matches[0]
						Write-Log -Message "Valid installer file path is $InstallerFilePath"
					}
				}
				if (!$InstallerFilePath) {
					if (!$SetupFilePath) {
						Write-Log -Message "No setup folder path specified. This software cannot be removed" -LogLevel '2'
						continue
					} else {
						$InstallerFilePath = $SetupFilePath	
					}
				}
				## Run the setup.exe passing the ISS file to uninstall
				Write-Log -Message "Running the install syntax `"$InstallerFilePath`" /s /f1`"$IssFilePath`" /f2`"$script:LogFilePath`""
				$Process = Start-Process "`"$InstallerFilePath`"" -ArgumentList "/s /f1`"$IssFilePath`" /f2`"$script:LogFilePath`"" -Wait -NoNewWindow -PassThru
				$x = Check-Process $Process
				if (!(Validate-IsSoftwareInstalled $Title)) {
					Write-Log -Message "The product $Title was successfully removed!"
				} else {
					Write-Log -Message "The product $Title was not removed!" -LogLevel '2'
				}
			}
		}
	} catch {
		Write-Log -Message $_.Exception.Message -LogLevel '3'
		return
	}
}

function Get-SystemTempFilePath {
	[environment]::GetEnvironmentVariable('TEMP', 'Machine')
}

function Find-InTextFile {
	<#
	.SYNOPSIS
		Performs a find (or replace) on a string in a text file or files.
	.EXAMPLE
		PS> Find-InTextFile -FilePath 'C:\MyFile.txt' -Find 'water' -Replace 'wine'
	
		Replaces all instances of the string 'water' into the string 'wine' in
		'C:\MyFile.txt'.
	.EXAMPLE
		PS> Find-InTextFile -FilePath 'C:\MyFile.txt' -Find 'water'
	
		Finds all instances of the string 'water' in the file 'C:\MyFile.txt'.
	.PARAMETER FilePath
		The file path of the text file you'd like to perform a find/replace on.
	.PARAMETER Find
		The string you'd like to replace.
	.PARAMETER Replace
		The string you'd like to replace your 'Find' string with.
	.PARAMETER NewFilePath
		If a new file with the replaced the string needs to be created instead of replacing
		the contents of the existing file use this param to create a new file.
	.PARAMETER Force
		If the NewFilePath param is used using this param will overwrite any file that
		exists in NewFilePath.
	#>
	[CmdletBinding(DefaultParameterSetName = 'NewFile')]
	[OutputType()]
	param (
		[Parameter(Mandatory = $true)]
		[ValidateScript({
			(Test-Path -Path $_ -PathType 'Leaf') -and
			((Get-Content $_ -Encoding Byte -TotalCount 1024) -notcontains 0)
		})]
		[string[]]$FilePath,
		[Parameter(Mandatory = $true)]
		[string]$Find,
		[Parameter()]
		[string]$Replace,
		[Parameter(ParameterSetName = 'NewFile')]
		[ValidateScript({ Test-Path -Path ($_ | Split-Path -Parent) -PathType 'Container' })]
		[string]$NewFilePath,
		[Parameter(ParameterSetName = 'NewFile')]
		[switch]$Force
	)
	begin {
		$SystemTempFolderPath = Get-SystemTempFilePath
		$Find = [regex]::Escape($Find)
	}
	process {
		try {
			foreach ($File in $FilePath) {
				if ($Replace) {
					if ($NewFilePath) {
						if ((Test-Path -Path $NewFilePath -PathType 'Leaf') -and $Force.IsPresent) {
							Remove-Item -Path $NewFilePath -Force
							(Get-Content $File) -replace $Find, $Replace | Add-Content $NewFilePath -Force
						} elseif ((Test-Path -Path $NewFilePath -PathType 'Leaf') -and !$Force.IsPresent) {
							Write-Warning "The file at '$NewFilePath' already exists and the -Force param was not used"
						} else {
							(Get-Content $File) -replace $Find, $Replace | Add-Content $NewFilePath -Force
						}
					} else {
						$FileName = $File | Split-Path -Leaf
						(Get-Content $File) -replace $Find, $Replace | Add-Content "$SystemTempFolderPath\$FileName" -Force
						Move-Item -Path "$SystemTempFolderPath\$FileName" -Destination $File -Force
					}
				} else {
					Select-String -Path $File -Pattern $Find
				}
			}
		} catch {
			Write-Error $_.Exception.Message
		}
	}
}

function Stop-MyProcess ([string[]]$ProcessName) {
	Write-Debug "Initiating the $($MyInvocation.MyCommand.Name) function...";
	foreach ($Process in $ProcessName) {
		$ProcessesToStop = Get-Process $ProcessName -ErrorAction 'SilentlyContinue'
		if (!$ProcessesToStop) {
			Write-Log -Message "-No processes to be killed found..."
		} else {
			foreach ($process in $ProcessName) {
				Write-Log -Message "-Process $process is running. Attempting to stop..."
				$WmiProcess = Get-WmiObject -Class Win32_Process -Filter "name='$process.exe'" -ea 'SilentlyContinue' -ev WMIError
				if ($WmiError) {
					Write-Log -Message "Unable to stop process $process. WMI query errored with `"$($WmiError.Exception.Message)`"" -LogLevel '2'
				} elseif ($WmiProcess) {
					$WmiResult = $WmiProcess.Terminate()
					if ($WmiResult.ReturnValue -ne 0) {
						Write-Log -Message "-Unable to stop process $process. Return value was $($WmiResult.ReturnValue)" -LogLevel '2'
					} else {
						Write-Log -Message "-Successfully stopped process $process..."
					}
				}
			}
		}
	}
}

function Remove-MyService {
	<#
	.SYNOPSIS
		This function stops and removes a Windows service
	.EXAMPLE
		Remove-MyService -Name bnpagent
	.PARAMETER ServiceName
	 	The service name you'd like to stop and remove
	#>
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true)]
		[ValidateScript({ Get-Service -Name $_ -ea 'SilentlyContinue' })]
		[string]$Name
	)
	Write-Debug "Initiating the $($MyInvocation.MyCommand.Name) function...";
	$ServicesToRemove = Get-Service $Name -ea 'SilentlyContinue' -ev MyError
	Check-Error $MyError "Found $($ServicesToRemove.Count) services to remove"
	if (!$ServicesToRemove) {
		Write-Log -Message "-No services to be removed found..."
	} else {
		foreach ($Service in $ServicesToRemove) {
			Write-Log -Message "-Found service $($Service.DisplayName)."
			if ($Service.Status -ne 'Stopped') {
				Write-Log -Message "-Service $($Service.Displayname) is not stopped."
				Stop-Service $Service -ErrorAction 'SilentlyContinue' -Force -ev ServiceError
				Check-Error $ServiceError "-Successfully stopped $($Service.Displayname)"
			} else {
				Write-Log -Message "-Service $($Service.Displayname) is already stopped."
			}
			Write-Log -Message "-Attempting to remove service $($Service.DisplayName)..."
			$WmiService = Get-WmiObject -Class Win32_Service -Filter "Name='$($Service.ServiceName)'" -ea 'SilentlyContinue' -ev WMIError
			if ($WmiError) {
				Write-Log -Message "-Unable to remove service $($Service.DisplayName). WMI query errored with `"$($WmiError.Exception.Message)`"" -LogLevel '2'
			} else {
				$DeleteService = $WmiService.Delete()
				if ($DeleteService.ReturnValue -ne 0) {
					## Delete method error codes http://msdn.microsoft.com/en-us/library/aa389960(v=vs.85).aspx
					Write-Log -Message "-Service $($Service.DisplayName) failed to remove. Delete error code was $($DeleteService.ReturnValue).." -LogLevel '2'
				} else {
					Write-Log -Message "-Service $($Service.DisplayName) successfully removed..."
				}
			}
		}
	}
}

function Get-InstalledSoftware {
	<#
	.SYNOPSIS
		Retrieves a list of all software installed	
	.DESCRIPTION
		Retrieves a list of all software installed via the specified method
	.EXAMPLE
		Get-InstalledSoftware -Name adobe* -Publisher adobe -ComputerName COMPUTER
		This example retrieves all software installed on COMPUTER matching the string starting with 'adobe' and
		with a publisher equal to 'adobe'.
	.EXAMPLE
		Get-InstalledSoftware
		This example retrieves all software installed on the local computer
	.PARAMETER Name
		The software title you'd like to limit the query to.  Wildcards are permitted.
	.PARAMETER Publisher
		The software publisher you'd like to limit the query to. Wildcards are permitted.
	.PARAMETER Version
		The software version you'd like to limit the query to. Wildcards are permitted.
	.PARAMETER Computername
		The computer you'd like to query.  It defaults to the local machine if no computer specified. 
		Multiple computer names are allowed.
	.PARAMETER Method
		This is the place where we look for the installed software.  You have the option of choosing SCCMClient or
		UninstallRegKey here.  This defaults to using the SMS_InstalledSoftware WMI class with the SCCMClient.
	#>
	[CmdletBinding()]
	param (
		[string]$Name,
		[string]$Publisher,
		[string]$Version,
		[string[]]$Computername = 'localhost',
		[ValidateSet('SCCMClient','UninstallRegKey')]	
		[string]$Method = 'SCCMClient'
	)
	begin {
		Write-Verbose "Initiating the $($MyInvocation.MyCommand.Name) function...";
		$WhereQuery = "SELECT * FROM SMS_InstalledSoftware"
		
		if ($PSBoundParameters.Count -ne 0) {
			## Add any new parameters added here to match with the WMI property name
			$QueryBuild = @{
				'Name' = 'ProductName';
				'Publisher' = 'Publisher';
				'Version' = 'ProductVersion';
			}
			$QueryParams = $PSBoundParameters.GetEnumerator() | where { $QueryBuild.ContainsKey($_.Key) }
			if ($QueryParams) {
				$WhereQuery += ' WHERE'
				$BuiltQueryParams = { @() }.Invoke()
				foreach ($Param in $QueryParams) {
					## Allow asterisks in cmdlet but WQL requires percentage and double backslashes
					$ParamValue = $Param.Value | foreach { $_.Replace('*', '%').Replace('\','\\') }
					$Operator = @{ $true = 'LIKE'; $false = '=' }[$ParamValue -match '\%']
					$BuiltQueryParams.Add("$($QueryBuild[$Param.Key]) $Operator '$($ParamValue)'")
				}
			}
		}
		$WhereQuery = "$WhereQuery $($BuiltQueryParams -join ' AND ')"
		Write-Verbose "Using WMI query $WhereQuery..."
		
		$Params = @{
			'Namespace' = 'root\cimv2\sms';
			'Query' = $WhereQuery;
			'ErrorAction' = 'SilentlyContinue';
			'ErrorVariable' = 'MyError'
		}
	}
	process {
		try {
			foreach ($Computer in $Computername) {
				$Params['ComputerName'] = $Computer;
				$Software = Get-WmiObject @Params
				Check-Error $MyError "Successfully queried computer $Computer for installed software"
				$Software | Sort-Object ARPDisplayname;
			}
		} catch [System.Exception] {
			Write-Log -Message $_.Exception.Message -LogLevel '3'
		}##endtry
	}
}##endfunction

function New-ValidationDynamicParam {
	[CmdletBinding()]
	[OutputType('System.Management.Automation.RuntimeDefinedParameter')]
	param (
		[Parameter(Mandatory=$true)]
		[ValidateNotNullOrEmpty()]
		[string]$Name,
		[ValidateNotNullOrEmpty()]
		[Parameter(Mandatory=$true)]
		[array]$ValidateSetOptions,
		[Parameter()]
		[switch]$Mandatory = $false,
		[Parameter()]
		[string]$ParameterSetName = '__AllParameterSets',
		[Parameter()]
		[switch]$ValueFromPipeline = $false,
		[Parameter()]
		[switch]$ValueFromPipelineByPropertyName = $false
	)
	
	$AttribColl = New-Object System.Collections.ObjectModel.Collection[System.Attribute]
	$ParamAttrib = New-Object System.Management.Automation.ParameterAttribute
	$ParamAttrib.Mandatory = $Mandatory.IsPresent
	$ParamAttrib.ParameterSetName = $ParameterSetName
	$ParamAttrib.ValueFromPipeline = $ValueFromPipeline.IsPresent
	$ParamAttrib.ValueFromPipelineByPropertyName = $ValueFromPipelineByPropertyName.IsPresent
	$AttribColl.Add($ParamAttrib)
	$AttribColl.Add((New-Object System.Management.Automation.ValidateSetAttribute($Param.ValidateSetOptions)))
	$RuntimeParam = New-Object System.Management.Automation.RuntimeDefinedParameter($Param.Name, [string], $AttribColl)
	$RuntimeParam
	
}

function Set-MyFileSystemAcl {
	[CmdletBinding()]
	param (
		[Parameter(Mandatory=$true)]
		[ValidateScript({ Test-Path -Path $_ })]
		[string]$Path,
		[Parameter(Mandatory=$true)]
		[string]$Identity,
		[Parameter(Mandatory=$true)]
		[string]$Right,
		[Parameter(Mandatory=$true)]
		[string]$InheritanceFlags,
		[Parameter(Mandatory=$true)]
		[string]$PropagationFlags,
		[Parameter(Mandatory=$true)]
		[string]$Type
	)
	
	process {
		try {
			$Acl = Get-Acl $Path
			$Ar = New-Object System.Security.AccessControl.FileSystemAccessRule($Identity, $Right, $InheritanceFlags, $PropagationFlags, $Type)
			$Acl.SetAccessRule($Ar)
			Set-Acl $Path $Acl
		} catch {
			Write-Error $_.Exception.Message
		}
	}
}

function Convert-GuidToCompressedGuid {
	<#
	.SYNOPSIS
		This converts a GUID to a compressed GUID also known as a product code.	
	.DESCRIPTION
		This function will typically be used to figure out the product code
		that matches up with the product code stored in the 'SOFTWARE\Classes\Installer\Products'
		registry path to a MSI installer GUID.
	.EXAMPLE
		Convert-GuidToCompressedGuid -Guid '{7C6F0282-3DCD-4A80-95AC-BB298E821C44}'
	
		This example would output the compressed GUID '2820F6C7DCD308A459CABB92E828C144'
	.PARAMETER Guid
		The GUID you'd like to convert.
	#>
	[CmdletBinding()]
	[OutputType()]
	param (
		[Parameter(ValueFromPipeline=$true, ValueFromPipelineByPropertyName=$true, Mandatory=$true)]
		[string]$Guid
	)
	begin {
		$Guid = $Guid.Replace('-', '').Replace('{', '').Replace('}', '')
	}
	process {
		try {
			$Groups = @(
				$Guid.Substring(0, 8).ToCharArray(),
				$Guid.Substring(8, 4).ToCharArray(),
				$Guid.Substring(12, 4).ToCharArray(),
				$Guid.Substring(16, 16).ToCharArray()
			)
			$Groups[0..2] | foreach {
				[array]::Reverse($_)
			}
			$CompressedGuid = ($Groups[0..2] | foreach { $_ -join '' }) -join ''
			
			$chararr = $Groups[3]
			for ($i = 0; $i -lt $chararr.count; $i++) {
				if (($i % 2) -eq 0) {
					$CompressedGuid += ($chararr[$i+1] + $chararr[$i]) -join ''
				}
			}
			$CompressedGuid
		} catch {
			Write-Error $_.Exception.Message	
		}
	}
}

function Convert-CompressedGuidToGuid {
	<#
	.SYNOPSIS
		This converts a compressed GUID also known as a product code into a GUID.	
	.DESCRIPTION
		This function will typically be used to figure out the MSI installer GUID
		that matches up with the product code stored in the 'SOFTWARE\Classes\Installer\Products'
		registry path.
	.EXAMPLE
		Convert-CompressedGuidToGuid -CompressedGuid '2820F6C7DCD308A459CABB92E828C144'
	
		This example would output the GUID '{7C6F0282-3DCD-4A80-95AC-BB298E821C44}'
	.PARAMETER CompressedGuid
		The compressed GUID you'd like to convert.
	#>
	[CmdletBinding()]
	[OutputType([System.String])]
	param (
		[Parameter(ValueFromPipeline=$true, ValueFromPipelineByPropertyName=$true, Mandatory=$true)]
		[ValidatePattern('^[0-9a-fA-F]{32}$')]
		[string]$CompressedGuid
	)
	process {
		try {
			$Indexes = [ordered]@{
				0 = 8;
				8 = 4;
				12 = 4;
				16 = 2;
				18 = 2;
				20 = 2;
				22 = 2;
				24 = 2;
				26 = 2;
				28 = 2;
				30 = 2
			}
			$Guid = '{'
			foreach ($index in $Indexes.GetEnumerator()) {
				$part = $CompressedGuid.Substring($index.Key, $index.Value).ToCharArray()
				[array]::Reverse($part)
				$Guid += $part -join ''
			}
			$Guid = $Guid.Insert(9, '-').Insert(14, '-').Insert(19, '-').Insert(24, '-')
			$Guid + '}'
		} catch {
			Write-Error $_.Exception.Message	
		}
	}
}

function Remove-Software {
	<#
	.SYNOPSIS
		This function removes any software registered via Windows Installer from the local computer.    
	.NOTES
		Created on:   	6/4/2014
		Created by:   	Adam Bertram
		Requirements:   Installed SCCM Client for the SMS_InstalledSoftware WMI class and the 
						Win32Reg_AddRemovePrograms WMI class.
						The msizap utility (if user would like to run)
		Todos:			Add ability to remove registry values/keys
						Read the cached MSI file to get installation directory to use to find shortcuts
						Funtionalize installed software query so user doesn't need SCCM client installed
						Add ability to remove folders in the start menu
	.DESCRIPTION
		This function searches a local computer for a specified application matching a name.  Based on the
		parameters given, it can either remove services, kill proceseses and if the software is
		installed, it uses the locally cached MSI to initiate an uninstall and has the option to 
		ensure the software is completely removed by running the msizap.exe utility.
	.EXAMPLE
		Remove-Software -ProductName 'Adobe Reader' -KillProcess 'proc1','proc2'
		This example would remove any software with 'Adobe Reader' in the name and look for and stop both the proc1 
		and proc2 processes
	.EXAMPLE
	    Remove-Software -ProductName 'Adobe Reader'
		This example would remove any software with 'Adobe Reader' in the name.
	.EXAMPLE
	    Remove-Software -ProductName 'Adobe Reader' -RemoveService 'servicename' -Verbose
		This example would remove any software with 'Adobe Reader' in the name, look for, stop and remove any service with a 
		name of servicename. It will output all verbose logging as well.
	.EXAMPLE
	    Remove-Software -ProductName 'Adobe Reader' -RemoveFolder 'C:\Program Files Files\Install Folder'
		This example would remove any software with 'Adobe Reader' in the name, look for and remove the 
		C:\Program Files\Install Folder, attempt to uninstall the software cleanly via msiexec using 
		the syntax msiexec.exe /x PRODUCTMSI /qn REBOOT=ReallySuppress which would attempt to not force a reboot if needed.
		If it doesn't uninstall cleanly, it would run copy the msizap utility from the default path to 
		the local computer, execute it with the syntax msizap.exe TW! PRODUCTGUID and remove itself when done.
	.PARAMETER ProductName
		This is the name of the application to search for. This can be multiple products.  Each product will be removed in the
		order you specify.
	.PARAMETER KillProcess
		One or more process names to attempt to kill prior to software uninstall.  By default, all EXEs in the installation 
		folder are found and all matching running processes are killed.  This would be for any additional processes you'd
		like to kill.
	.PARAMETER RemoveService
		One or more services to attempt to stop and remove prior to software uninstall
	.PARAMETER MsiExecSwitches
		Specify a string of switches you'd like msiexec.exe to run when it attempts to uninstall the software. By default,
		it already uses "/x GUID /qn".  You can specify any additional parameters here.
	.PARAMETER LogFilePath
		The file path where the msiexec uninstall log will be created.  This defaults to the name of the product being
		uninstalled in the system temp directory
	.PARAMETER Shortcut
		Use this option to specify a hash table of search types and search values to match in all LNK and URL files in all 
		files/folders in all user profiles and have them removed. If the RemoveFolder param is specified, this will inherently be
		done matching the 'MatchingTargetPath' attribute on the folder specified there.
	
		The options for the keys in this hash table are MatchingTargetPath,MatchingName and MatchingFilePath.  Use each
		key along with the value of what you'd like to search for and remove.
	.PARAMETER RemoveFolder
		One or more folders to recursively remove after software uninstall. This is beneficial for those
		applications that do not clean up after themselves.  If this param is specified, all shortcuts related to this
		folder path will be removed in all user profile folders also.
	.PARAMETER RunMsizap
		Use this parameter to run the msizap.exe utility to cleanup any lingering remnants of the software
	.PARAMETER MsizapParams
		Specify the parameters to send to msizap if it is needed to cleanup the software on the remote computer. This
		defaults to "TW!" which removes settings from all user profiles
	.PARAMETER MsizapFilePath
		Optionally specify where the file msizap utility is located in order to run a final cleanup
	.PARAMETER IssFilePath
		If removing an InstallShield application, use this parameter to specify the ISS file path where you recorded
		the uninstall of the application.
	.PARAMETER
		If removing an InstallShield application, use this optional paramter to specify where the EXE installer is for
		the application you're removing.  This is only used if no cached installer is found.
	#>
	[CmdletBinding(DefaultParameterSetName = 'MSI')]
	param (
		[Parameter(Mandatory = $true,
				   ValueFromPipeline = $true,
				   ValueFromPipelineByPropertyName = $true)]
		[ValidateNotNullOrEmpty()]	
		[string[]]$ProductName,
		[Parameter()]
		[string[]]$KillProcess,
		[Parameter()]
		[string[]]$RemoveService,
		[Parameter(ParameterSetName = 'MSI')]
		[string]$MsiExecSwitches,
		[Parameter()]
		[string]$LogFilePath,
		[Parameter()]
		[string[]]$RemoveFolder,
		[Parameter()]
		[hashtable]$Shortcut,
		[Parameter(ParameterSetName = 'Msizap')]
		[switch]$RunMsizap,
		[Parameter(ParameterSetName = 'Msizap')]
		[string]$MsizapParams = 'TW!',
		[Parameter(ParameterSetName = 'Msizap')]
		[ValidateScript({ Test-Path $_ -PathType 'Leaf' })]
		[string]$MsizapFilePath = '\\configmanager\deploymentmodules\softwareinstallmanager\msizap.exe',
		[Parameter(ParameterSetName = 'ISS',
				   Mandatory = $true)]
		[ValidateScript({ Test-Path $_ -PathType 'Leaf' })]
		[ValidatePattern('\.iss$')]
		[string]$IssFilePath,
		[Parameter(ParameterSetName = 'ISS')]
		[ValidateScript({ Test-Path $_ -PathType 'Leaf' })]
		[string]$InstallShieldSetupFilePath
	)
	
	begin {
		try {
			Write-Debug "Initiating the $($MyInvocation.MyCommand.Name) function...";
			Start-Log
			$script:CmClientWmiNamespace = 'root\cimv2\sms'
			
		} catch {
			Write-Log -Message $_.Exception.Message -LogLevel '3'
			return
		}
	}
	
	process {
		try {
			if ($KillProcess) {
				Stop-MyProcess $KillProcess
			}
			
			if ($RemoveService) {
				Remove-MyService $RemoveService
			}
			
			foreach ($Product in $ProductName) {
				## Find the installation folder and all EXEs.  Stop all processes running under these EXEs
				$InstallFolderPath = Get-InstallLocation $Product
				Write-Log -Message "Checking for processes in install folder...."
				if ($InstallFolderPath) {
					Write-Log -Message  "Stopping all processes under the install folder $InstallFolderPath..."
					$Processes = (Get-Process | where { $_.Path -like "$InstallFolderPath*" } | select -ExpandProperty Name)
					if ($Processes) {
						Write-Log -Message "Sending processes: $Processes to Stop-MyProcess..."
						Stop-MyProcess $Processes
					} else {
						Write-Log -Message 'No processes running under the install folder path'	
					}
				} else {
					Write-Log -Message "Could not find the install folder path to stop open processes" -LogLevel '2'
				}
				
				$InstalledProducts = Validate-IsSoftwareInstalled $Product
				if (!$InstalledProducts) {
					Write-Log -Message "$Product already uninstalled"
				} else {
					$InstalledProducts = Get-InstalledSoftware $Product
					foreach ($InstalledProduct in $InstalledProducts) {
						$Title = $InstalledProduct.ARPDisplayname
						if ($InstalledProduct.UninstallString) {
							$InstallerType = Get-InstallerType $InstalledProduct.UninstallString
						} else {
							Write-Log -Message "Uninstall string for $Title not found..." -LogLevel '3'
							continue
						}
						if (!$PsBoundParameters['LogFilePath']) {
							$WmiParams = @{
								'Class' = 'Win32_Environment';
								'Filter' = "Name = 'TEMP' AND Username = '<SYSTEM>'"
							}
							$script:LogFilePath = "$((Get-WmiObject @WmiParams).VariableValue)\$Title.log"
							Write-Log -Message "No log file path specified.  Defaulting to $script:LogFilePath..."
						}
						if (!$InstallerType) {
							Write-Log -Message "Unknown installer type for $Title..." -LogLevel '3'
							continue
						} elseif ($InstallerType -eq 'InstallShield') {
							Write-Log -Message "Installer type detected as Installshield."
							if (!(Validate-IsIssFileValid -Guid $InstalledProduct.SoftwareCode -IssFilePath $IssFilePath)) {
								Write-Log -Message "ISS file at $IssFilePath is not valid for the GUID $($InstalledProduct.SoftwareCode)" -LogLevel '2'
								continue
							} else {
								Uninstall-InstallShieldPackage -IssFilePath $IssFilePath -ProductName $Title -SetupFilePath $InstallShieldSetupFilePath
							}
						} elseif ($InstallerType -eq 'Windows Installer') {
							Write-Log -Message 'Installer detected to be Windows Installer. Initiating Windows Installer package removal...'
							Uninstall-WindowsInstallerPackage -ProductName $Title
						}
						if (!(Validate-IsSoftwareInstalled $Title)) {
							Write-Log -Message "Successfully removed $Title!"
						} else {
							Write-Log -Message "$Title not uninstalled via traditional uninstall" -LogLevel '2'
							if ($RunMsizap.IsPresent) {
								Write-Log -Message "Attempting Msizap..."
								Uninstall-ViaMsizap -Guid $InstalledProduct.SoftwareCode -MsizapFilePath $MsizapFilePath -Params $MsiZapParams
							} else {
								Write-Log -Message "$Title failed to uninstall successfully" -LogLevel '3'
							}
						}
					}
				}
			}
			
			if ($RemoveFolder) {
				Write-Log -Message "Starting folder removal..."
				foreach ($Folder in $RemoveFolder) {
					Write-Log -Message "Checking for $Folder existence..."
					if (Test-Path $Folder -PathType 'Container') {
						Write-Log -Message "Found folder $Folder.  Attempting to remove..."
						Remove-Item $Folder -Force -Recurse -ea 'Continue'
						if (!(Test-Path $Folder -PathType 'Container')) {
							Write-Log -Message "Successfully removed $Folder"
						} else {
							Write-Log -Message "Failed to remove $Folder" -LogLevel '2'
						}
					} else {
						Write-Log -Message "$Folder was not found..."	
					}
					Get-Shortcut -MatchingTargetPath $Folder -ErrorAction 'SilentlyContinue' | Remove-Item -ea 'Continue' -Force
				}
			}
			
			if ($Shortcut) {
				Write-Log -Message "Removing all shortcuts in all user profile folders"
				foreach ($key in $Shortcut.GetEnumerator()) {
					$Params = @{ $key.Name = $key.value }
					Get-Shortcut $Params | Remove-Item -Force -ea 'Continue'
				}
			}
		} catch {
			Write-Log -Message $_.Exception.Message -LogLevel '3'
		}
	}
}

function Remove-ItemFromAllUserProfiles {
	<#
	.SYNOPSIS
		This function removes a file(s) or folder(s) with the same path in all user profiles including
		system profiles like SYSTEM, NetworkService and AllUsers.
	.EXAMPLE
		PS> .\Remove-ItemFromAllUserProfiles -Path 'AppData\Adobe'
	
		This example will remove the folder path 'AppData\Adobe' from all user profiles
	.PARAMETER Path
		The path(s) to the file or folder you'd like to remove.
	#>
	[CmdletBinding()]
	param (
		[Parameter(Mandatory=$true)]
		[ValidateNotNullOrEmpty()]
		[string[]]$Path
	)
	
	process {
		try {
			$AllUserProfileFolderPath = Get-AllUsersProfileFolderPath
			$UserProfileFolderPaths = Get-UserProfilePath
			
			foreach ($p in $Path) {
				if (!(Test-Path "$AllUserProfileFolderPath\$p")) {
					Write-Log -Message "The folder '$AllUserProfileFolderPath\$p' does not exist"
				} else {
					Remove-Item -Path "$AllUserProfileFolderPath\$p" -Force -Recurse
				}
				
				
				foreach ($ProfilePath in $UserProfileFolderPaths) {
					if (!(Test-Path "$ProfilePath\$p")) {
						Write-Log -Message "The folder '$ProfilePath\$p' does not exist"
					} else {
						Remove-Item -Path "$ProfilePath\$p" -Force -Recurse
					}
				}
			}
		} catch {
			Write-Error $_.Exception.Message
		}
	}
}

function Get-Shortcut {
	<#
	.SYNOPSIS
		This function searches for files matching a LNK and URL extension.
	.DESCRIPTION
		This function, by default, recursively searches for files matching a LNK and URL extensions containing
		a specific string inside the target path, name or both. If no folder path specified, it will 
		recursively search all user profiles and the all users profile.
	.NOTES
		Created on: 	6/23/2014
		Created by: 	Adam Bertram
	.EXAMPLE
		Get-Shortcut -MatchingTargetPath 'http:\\servername\local'
		This example would find all shortcuts (URL and LNK) in all user profiles that have a 
		target path that match 'http:\\servername\local'
	.EXAMPLE
		Get-Shortcut -MatchingTargetPath 'http:\\servername\local' -MatchingName 'name'
		This example would find all shortcuts (URL and LNK) in all user profiles that have a 
		target path that match 'http:\\servername\local' and have a name containing the string "name"
	.EXAMPLE
		Get-Shortcut -MatchingTargetPath 'http:\\servername\local' -MatchingFilePath 'C:\Users\abertram\Desktop'
		This example would find all shortcuts (URL and LNK) in the 'C:\Users\abertram\Desktop file path 
		that have a target path that match 'http:\\servername\local' and have a name containing the 
		string "name"
	.PARAMETER MatchingTargetPath
		The string you'd like to search for inside the shortcut's target path
	.PARAMETER MatchingName
		A string you'd like to search for inside of the shortcut's name
	.PARAMETER MatchingFilePath
		A string you'd like to search for inside of the shortcut's file path
	.PARAMETER FolderPath
		The folder path to search for shortcuts in.  You can specify multiple folder paths. This defaults to 
		the user profile root and the all users profile
	.PARAMETER NoRecurse
		This turns off recursion on the folder path specified searching subfolders of the FolderPath
	#>
	[CmdletBinding()]
	param (
		[string]$MatchingTargetPath,
		[string]$MatchingName,
		[string]$MatchingFilePath,
		[string[]]$FolderPath,
		[switch]$NoRecurse
	)
	Write-Debug "Initiating the $($MyInvocation.MyCommand.Name) function...";
	Start-Log
	if (!$FolderPath) {
		$FolderPath = (Get-RootUserProfileFolderPath),(Get-AllUsersProfileFolderPath)
	}
	
	$Params = @{
		'Include' = @('*.url', '*.lnk');
		'ErrorAction' = 'SilentlyContinue';
		'ErrorVariable' = 'MyError';
		'Force' = $true
	}
	
	if (!$NoRecurse) {
		$Params['Recurse'] = $true
	}
	
	$ShellObject = New-Object -ComObject Wscript.Shell
	[System.Collections.ArrayList]$Shortcuts = @()
	
	foreach ($Path in $FolderPath) {
		Write-Log -Message "Searching for shortcuts in $Path..."
		[System.Collections.ArrayList]$WhereConditions = @()
		$Params['Path'] = $Path
		if ($MatchingTargetPath) {
			$WhereConditions.Add('(($ShellObject.CreateShortcut($_.FullName)).TargetPath -like "*$MatchingTargetPath*")') | Out-Null
		}
		if ($MatchingName) {
			$WhereConditions.Add('($_.Name -like "*$MatchingName*")') | Out-Null
		}
		if ($MatchingFilePath) {
			$WhereConditions.Add('($_.FullName -like "*$MatchingFilePath*")') | Out-Null
		}
		if ($WhereConditions.Count -gt 0) {
			$WhereBlock = [scriptblock]::Create($WhereConditions -join ' -and ')
			## TODO: Figure out a way to make this cleanly log access denied errors and continue
			Get-ChildItem @Params | where $WhereBlock
		} else {
			Get-ChildItem @Params
		}
		if ($NewShortcuts) {
			$Shortcuts.Add($NewShortcuts) | Out-Null
		}
	}
}

function New-Shortcut {
	<#
	.SYNOPSIS
		This function creates a file shortcut   
	.NOTES
		Created on:   	07/19/2014
		Created by:   	Adam Bertram
	.EXAMPLE
		New-Shortcut -FolderPath 'C:\' -Name 'My Shortcut' -TargetFilePath 'C:\Windows\notepad.exe'
		This examples creates a shortcut in C:\ called 'My Shortcut.lnk' pointing to notepad.exe
	.EXAMPLE
		New-Shortcut -CommonLocation AllUsersDesktop -Name 'My Shortcut' -TargetFilePath 'C:\Windows\notepad.exe'
		This examples creates a shortcut on the all users desktop called 'My Shortcut.lnk' pointing to notepad.exe
	.PARAMETER FolderPath
		If a custom path is needed that's not included in the list of common locations in the CommonLocation parameter
		this parameter can be used to create a folder in the specified path.
	.PARAMETER CommonLocation
		This is a set of common locations shortcuts are typically created in.  Use this parameter if you'd like to 
		quickly specify where the shortcut needs to be created in.
	.PARAMETER Name
		The name of the shortcut (file)
	.PARAMETER TargetFilePath
		The file path of the application you'd like the shortcut to point to
	.PARAMETER
		File arguments you'd like to append to the target file path
	#>
	[CmdletBinding(DefaultParameterSetName = 'CommonLocation')]
	param (
		[Parameter(ParameterSetName = 'CustomLocation',
			Mandatory=$true)]	
		[ValidateScript({ Test-Path $_ -PathType 'Container' })]
		[string]$FolderPath,
		[Parameter(ParameterSetName = 'CommonLocation',
			Mandatory=$true)]
		[ValidateSet('AllUsersDesktop')]
		[string]$CommonLocation,
		[Parameter(Mandatory=$true)]
		[string]$Name,
		[Parameter(Mandatory=$true)]
		[ValidateScript({ Test-Path $_ -PathType 'Leaf'})]
		[string]$TargetFilePath,
		[Parameter()]
		[string]$Arguments
	)
	begin {
		try {
			$ShellObject = New-Object -ComObject Wscript.Shell
		} catch {
			Write-Log -Message $_.Exception.Message -LogLevel '3'
		}
	}
	process {
		try {
			if ($CommonLocation -eq 'AllUsersDesktop') {
				$FilePath = "$(Get-AllUsersDesktopFolderPath)\$Name.lnk"
			} elseif ($FolderPath) {
				$FilePath = "$FolderPath\$Name.lnk"
			}
			if (Test-Path $FilePath) {
				throw "$FilePath already exists. New shortcut cannot be made here."	
			}
			$Object = $ShellObject.CreateShortcut($FilePath)
			$Object.TargetPath = $TargetFilePath
			$Object.Arguments = $Arguments
			$Object.WorkingDirectory = ($TargetFilePath | Split-Path -Parent)
			Write-Log -Message "Creating shortcut at $FilePath using targetpath $TargetFilePath"
			$Object.Save()
		} catch {
			Write-Log -Message $_.Exception.Message -LogLevel '3'	
		}
	}
}

function Get-DriveFreeSpace {
	<#
	.SYNOPSIS
		This finds the total hard drive free space for one or multiple hard drive partitions
	.DESCRIPTION
		This finds the total hard drive free space for one or multiple hard drive partitions. It returns free space
		rounded to the nearest SizeOutputLabel parameter
	.PARAMETER  DriveLetter
		This is the drive letter of the hard drive partition you'd like to query. By default, all drive letters are queried.
	.PARAMETER  SizeOutputLabel
		In what size increments you'd like the size returned (KB, MB, GB, TB). Defaults to MB.
	.PARAMETER  Computername
		The computername(s) you'd like to find free space on.  This defaults to the local machine.
	.EXAMPLE
		PS C:\> Get-DriveFreeSpace -DriveLetter 'C','D'
		This example retrieves the free space on the C and D drive partition.
	#>
	[CmdletBinding()]
	[OutputType([array])]
	param
	(
		[string[]]$Computername = 'localhost',
		[Parameter(ValueFromPipeline = $true,
				   ValueFromPipelineByPropertyName = $true)]
		[ValidatePattern('[A-Z]')]
		[string]$DriveLetter,
		[ValidateSet('KB', 'MB', 'GB', 'TB')]
		[string]$SizeOutputLabel = 'MB'
		
	)
	
	Begin {
		try {
			$WhereQuery = "SELECT FreeSpace,DeviceID FROM Win32_Logicaldisk"
			
			if ($PsBoundParameters.DriveLetter) {
				$WhereQuery += ' WHERE'
				$BuiltQueryParams = { @() }.Invoke()
				foreach ($Letter in $DriveLetter) {
					$BuiltQueryParams.Add("DeviceId = '$DriveLetter`:'")
				}
				$WhereQuery = "$WhereQuery $($BuiltQueryParams -join ' OR ')"
			}
			Write-Debug "Using WQL query $WhereQuery"
			$WmiParams = @{
				'Query' = $WhereQuery
				'ErrorVariable' = 'MyError';
				'ErrorAction' = 'SilentlyContinue'
			}
		} catch {
			Write-Log -Message $_.Exception.Message -LogLevel '3'
		}
	}
	Process {
		try {
			foreach ($Computer in $Computername) {
				$WmiParams.Computername = $Computer
				$WmiResult = Get-WmiObject @WmiParams
				Check-Error $MyError "Sucessfull WMI query"
				if (!$WmiResult) {
					throw "Drive letter does not exist on target system"
				}
				foreach ($Result in $WmiResult) {
					if ($Result.Freespace) {
						[pscustomobject]@{
							'Computername' = $Computer;
							'DriveLetter' = $Result.DeviceID;
							'Freespace' = [int]($Result.FreeSpace / "1$SizeOutputLabel")
						}
					}
					#$iFreeSpace =
				}
			}
		} catch {
			Write-Log -Message $_.Exception.Message -LogLevel '3'
		}
	}
}

function Get-FileVersion ($sPc, $sPath, $sFileName) {
	try {
		Write-Debug "Initiating the $($MyInvocation.MyCommand.Name) function...";
		$sFilePath = "\\$sPc\c$\$sPath\$sFileName";
		if (!(Test-Path $sFilePath)) {
			$mResult = $false;
		} else {
			$oFile = (dir $sFilePath).VersionInfo;
		}##endif
		
		if (!(Test-Path variable:/mResult)) {
			$mResult = $oFile.FileVersion;
		}##endif
		return $mResult
		
	} catch [System.Exception] {
		Write-Log -Message $_.Exception.Message -LogLevel '3'
	}##endtry
}##endfunction

function Install-Software {
	<#
	.SYNOPSIS

	.NOTES
		Created on: 	6/23/2014
		Created by: 	Adam Bertram
		Filename:		Install-Software.ps1
		Credits:		
		Requirements:	The installers executed via this script typically need "Run As Administrator"
		Todos:			Allow multiple software products to be installed	
	.EXAMPLE
		Install-Software -InstallerFilePath install.msi -InstallArgs "/qn "	
	.EXAMPLE
		
	.PARAMETER InstallShieldInstallerFilePath
	 	This is the file path to the EXE InstallShield installer.
	.PARAMETER MsiInstallerFilePath
	 	This is the file path to the MSI installer.
	.PARAMETER OtherInstallerFilePath
	 	This is the file path to any other EXE installer.
	.PARAMETER MsiExecSwitches
		This is a string of arguments that are passed to the installer. If this param is
		not used, it will default to the standard REBOOT=ReallySuppress and the ALLUSERS=1 switches. If it's 
		populated, it will be concatenated with the standard silent arguments.  Use the -Verbose switch to discover arguments used.
	.PARAMETER InstallShieldInstallArgs
		This is a string of arguments that are passed to the InstallShield installer.  Default arguments are
		"/s /f1$IssFilePath"
	.PARAMETER OtherInstallArgs
		This is a string of arguments that are passed to any other EXE installer.  There is no default.
	.PARAMETER KillProcess
		A list of process names that will be terminated prior to attempting the install.  This is useful
		in upgrade scenarios where you need to terminate the previous version's processes.
	.PARAMETER LogFilePath
		This is the path where the installer log file will be written.  If not passed, it will default
		to being named install.log in the system temp folder.
	.PARAMETER NoDefaultLogFilePath
		Use this switch parameter to prevent the default log folder path to be applied.  This is useful
		when you have an installer that uses a proprietary format for logging specified in the installer
		arguments such as 'msiexec.exe install.msi /log logfile.log'
	.PARAMETER RequiredFreeSpace
		This is the free space required on the C drive to check prior to installation.
	#>
	[CmdletBinding(DefaultParameterSetName = 'MSI')]
	param (
		[Parameter(ParameterSetName = 'InstallShield',
				   Mandatory = $true)]
		[ValidateScript({ Test-Path $_ -PathType 'Leaf' })]
		[ValidatePattern('\.exe$')]
		[string]$InstallShieldInstallerFilePath,
		[Parameter(ParameterSetName = 'Other',
				   Mandatory = $true)]
		[ValidateScript({ Test-Path $_ -PathType 'Leaf' })]
		[ValidatePattern('\.exe$')]
		[string]$OtherInstallerFilePath,
		[Parameter(ParameterSetName = 'InstallShield',
				   Mandatory = $true)]
		[ValidatePattern('\.iss$')]
		[string]$IssFilePath,
		[Parameter(ParameterSetName = 'MSI',
				   Mandatory = $true)]
		[ValidateScript({ Test-Path $_ -PathType 'Leaf' })]
		[string]$MsiInstallerFilePath,
		[string]$MsiExecSwitches,
		[Parameter(ParameterSetName = 'InstallShield')]
		[string]$InstallShieldInstallArgs,
		[Parameter(ParameterSetName = 'Other')]
		[string]$OtherInstallArgs,
		[Parameter()]
		[string[]]$KillProcess,
		[string]$LogFilePath,
		[switch]$NoDefaultLogFilePath,
		[string]$RequiredFreeSpace
	)
	
	begin {
		Set-StrictMode -Version Latest
		Write-Debug "Initiating the $($MyInvocation.MyCommand.Name) function...";    
		try {
			Write-Log -Message "Beginning software install..."
			
			$ProcessParams = @{
				'Wait' = $true;
				'NoNewWindow' = $true;
				'Passthru' = $true
			}
			
			$SystemTempFolder = Get-SystemTempFilePath
			Write-Log -Message "Using temp folder $SystemTempFolder..."
			
		} catch {
			Write-Log -Message $_.Exception.Message -LogLevel '3'
		}
	}
	
	process {
		try {
			if ($InstallShieldInstallerFilePath) {
				$InstallerFilePath = $InstallShieldInstallerFilePath
			} elseif ($MsiInstallerFilePath) {
				$InstallerFilePath = $MsiInstallerFilePath
			} elseif ($OtherInstallerFilePath) {
				$InstallerFilePath = $OtherInstallerFilePath
			}
			if (!$LogFilePath -and !$NoDefaultLogFilePath.IsPresent) {
				$InstallerFileName = $InstallerFilePath | Split-Path -Leaf
				$LogFilePath = "$SystemTempFolder\$InstallerFileName.log"
			}
			Write-Log -Message "Using log file path '$LogFilePath'..."
			
			if ($MsiInstallerFilePath) {
				if (!$MsiExecSwitches) {
					$InstallArgs = "/i `"$InstallerFilePath`" /qn REBOOT=ReallySuppress ALLUSERS=1 /L*v`"$LogFilePath`""
				} else {
					$InstallArgs = "/i `"$InstallerFilePath`" /qn $MsiExecSwitches REBOOT=ReallySuppress ALLUSERS=1 /L*v `"$LogFilePath`""
				}
				
				$ProcessParams['FilePath'] = 'msiexec.exe'
				$ProcessParams['ArgumentList'] = $InstallArgs
			} elseif ($InstallShieldInstallerFilePath) {
				if (!$InstallShieldInstallArgs) {
					$InstallArgs = "-s -f1`"$IssFilePath`" -f2`"$LogFilePath`""
				} else {
					$InstallArgs = "-s -f1`"$IssFilePath`" $InstallShieldInstallArgs -f2`"$LogFilePath`""
				}
				$ProcessParams['FilePath'] = $InstallerFilePath
				$ProcessParams['ArgumentList'] = $InstallArgs
			} elseif ($OtherInstallerFilePath) {
				if (!$OtherInstallArgs) {
					$InstallArgs = ""
				} else {
					$InstallArgs = $OtherInstallArgs
				}
				$ProcessParams['FilePath'] = $OtherInstallerFilePath
				$ProcessParams['ArgumentList'] = $InstallArgs
			}
			if ($KillProcess) {
				Write-Log -Message 'Killing existing processes'
				$KillProcess | foreach { Stop-MyProcess -ProcessName $_ }
			}
			
			Write-Log -Message "Starting the command line process `"$($ProcessParams['FilePath'])`" $($ProcessParams['ArgumentList'])..."
			$Process = Start-Process @ProcessParams
			while (!$Process.HasExited) {
				sleep 1
			}
			Check-Process $Process
		} catch {
			Write-Log -Message $_.Exception.Message -LogLevel '3'
		}
	}
	
	end {
		Write-Log -Message "Ending software install "
	}
}