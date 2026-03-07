<#
Get-ThunderboltInfo
Version 0.1 - Beta

.Synopsis
   Returns Thunderbolt controller information.

.DESCRIPTION
   Returns info, such as driver and FW (nvm) versions for the Thunderbolt controller. 
   If a Thunderbolt controller is detected but if a dock isn't connected this script also tries to turn on the controller's power.
   Should be working no matter if the computer uses a standard or a DCH (UWP) driver or not.
   
   
.NOTES
    Set-ForceTbtPowerState, Detect-TbtDrvType and Get-TbtControllerInfo are verified on:
                                    *Dell UWP (DCH) and Dell normal TB drivers.
                                    *HP (G5) UWP (DCH) and Dell normal TB drivers.
#>

Function Get-ThunderboltSupport
{
    [array]$TBSupport=Get-PnpDevice -InstanceId "PCI*" | Get-PnpDeviceProperty -KeyName "DEVPKEY_Device_CompatibleIds" | where {$_.data -like "*CC_0C0A*"}
    [array]$NhiService=Get-Service -Name nhi -ErrorAction SilentlyContinue
    $Model=(Get-wmiObject Win32_ComputerSystem).Model
    if ($TBSupport.Count -gt 0)
    {
	    write-host "$Model supports TB"
	    Return $TBSupport
    }
    else{
	    write-host "$Model doesn't support TB"
	    Return $False
    }
}

Function Detect-TbtDrvType
{
    $UWPBusPath='HKLM:\SYSTEM\CurrentControlSet\Control\DeviceClasses\{b101923a-e86e-4f98-b22f-84360f2ea5b7}'
    $UWPBusExists=Test-Path $UWPBusPath
    if ($UWPBusExists -eq $true)
    {
        $UWPBusChilds=Get-ChildItem $UWPBusPath
        if ($UWPBusChilds -ne $null)
        {
            return "UWP"
        }
    }

    $TbtController=Get-PnpDevice |Where -Property Service -like "*nhi*"
    if ($TbtController -ne $null)
    {
        return "Normal"
    }
    else{
	    return "No TBController"
    }
    
}

Function Get-TbtControllerInfo
{
    #Set-ForceTbtPowerState will throw a memory violation error on the 2nd run if this isn't triggered as a job.

    Param(
	[Parameter(ValueFromPipelineByPropertyName,Mandatory=$True)]
    [ValidateSet("UWP","Normal")]
	[String]$DrvType="UWP"
	)
    
    $job = Start-Job -Name GetInfo -ScriptBlock {param($DrvType)
    function Get-DecompressedBytes {
    
    #Based on https://gist.github.com/marcgeld/bfacfd8d70b34fdf1db0022508b02aca
	[CmdletBinding()]
    Param (
		[Parameter(Mandatory,ValueFromPipeline,ValueFromPipelineByPropertyName)]
        [String]$base64str = $(Throw("-Base64str is required"))
    )
	Process {
        $byteArray=[System.Convert]::FromBase64String($base64str)
        $input = New-Object System.IO.MemoryStream( , $byteArray )
	    $output = New-Object System.IO.MemoryStream
        $gzipStream = New-Object System.IO.Compression.GzipStream $input, ([IO.Compression.CompressionMode]::Decompress)
	    $gzipStream.CopyTo( $output )
        $gzipStream.Close()
		$input.Close()
		[byte[]] $byteOutArray = $output.ToArray()
        Write-Output $byteOutArray
        }
    }


    Wait-Job -Job $job | Out-Null
    Receive-Job -Job $job
    $joboutput
    return $joboutput
}

Function Set-ForceTbtPowerState()
{
    Param(
    [Parameter(ParameterSetName="Disable")]
    [switch]$Off,
    [Parameter(ParameterSetName="Enable")]
    [switch]$On
	)

    
    $strClassName="ForceTBPower"
    $Return=$false

    $Mof='
    #pragma namespace("\\\\.\\Root\\Wmi")

    [WMI, dynamic: ToInstance, provider("WmiProv"), Locale("MS\\0x409"), Description("Class used to operate method on a TBT_ForcePower"), guid("{86CCFD48-205E-4A77-9C48-2021CBEDE341}")]
    class xxTempNamexx
    {
    [key, read] string InstanceName;
    [read] boolean Active;
    [WmiMethodId(1), Implemented, read, write, Description("Set TBT Force Power")] void SetForcePower([in, Description("FP Data")] boolean Data);
    };
    '

    $DelMof='
    #pragma namespace("\\\\.\\Root\\Wmi")
    #pragma deleteclass("xxTempNamexx", fail)
    '

    $Mof=$Mof.Replace("xxTempNamexx",$strClassName)
    $DelMof=$DelMof.Replace("xxTempNamexx",$strClassName)

    $MofPath="$Env:temp\add.mof"
    $Mof |Out-File $MofPath

    $DelMofPath="$Env:temp\del.mof"
    $DelMof |Out-File $DelMofPath

    $mofCompExe="$Env:SystemRoot\System32\wbem\mofcomp.exe"

    if (!(Test-Path $mofCompExe))
    {
        write-host "$mofCompExe wasn't found, probably a bug in the script."
        break
    }

    if (Test-Path $MofPath)
    {
        $out=Invoke-Expression "$($mofCompExe.ToString()) $($MofPath.ToString())" | Out-Null
        Start-Sleep -Milliseconds 700
    }

    $strClassName="ForceTBPower"

    $WmiClass=([WmiClass]"root\WMI:$strClassName")
    [array]$WmiClassInstances=$WMiClass.GetInstances()

    if ($WmiClassInstances.Count -gt 0)
    {
        $WmiClassInstances=$null
        $WmiClass=$null
        Write-Verbose "Imported the WMI-class and instances were found."
        try{
            $wmiInstance=Get-WmiObject -Namespace root\wmi -Class $strClassName
            $wmiInstance.SetForcePower($On.ToBool()) | Out-Null
            $wmiInstance=$null
            $Return=$true
        }
        catch
        {
            Write-Host "Error setting forcepower"
        }

    }
    else{
        Write-Host "Couldn't find the wmiclass:'root\WMI:$strClassName'"
        break
    }

    
    if (Test-Path $DelMofPath)
    {
        Write-Verbose "Removing the imported WMI-class."
        Invoke-Expression "$($mofCompExe.ToString()) $($DelMofPath.ToString())" | Out-Null
        Start-Sleep -Milliseconds 700
        $Removed=$true
        try
        {
            $RemoveClass=([WmiClass]"root\WMI:$strClassName")
            $Removed=$false
        }
        catch
        {
            #expecting this to happen.
        }
        if ($Removed -eq $false)
        {
            Write-host "Failed to remove the WmiClass"
            $Return=$false
        }
        
    }
Remove-Item @($MofPath,$DelMofPath) -Force -Confirm:$false
Start-Sleep -Milliseconds 200
[System.GC]::Collect()
return $Return
}


################# MAIN #################

Function Get-ThunderboltInfo
{
    $SupportsThunderBolt=Get-ThunderboltSupport

    if ($SupportsThunderBolt -eq $false)
    {
        Return "No Thunderbolt Support"
    }

    $TBinitStateOff=$false
    [Array]$TBDevControllers=Get-PnpDevice -Class system | Where-Object {$_.Service -EQ "nhi" -and $_.Status -eq "OK"}
 
    [Array]$OffLineTBDevControllers=Get-PnpDevice -Class system | Where-Object {$_.Service -EQ "nhi" -and $_.Status -ne "OK"}
    $NoDrvTBDevControllersFound=Get-PnpDevice | Where {$_.class -eq $null -and $_.Status -ne "OK"} | Get-PnpDeviceProperty -KeyName 'DEVPKEY_Device_Parent' | % {if($_.Data -in $SupportsThunderBolt.InstanceID){return $true}}

    If ($NoDrvTBDevControllersFound)
    {
        return "Found devices supporting TB but no thunderbolt controller. Please verify that drivers are installed."
    }

    If ($TBDevControllers -eq $null)
    {
        $TBinitStateOff=$true
        if (($OffLineTBDevControllers -eq $null) -and ($SupportsThunderBolt -eq $false))
        {
           return "No thunderbolt controllers were found online nor offline. Exiting."
        }
    }

    switch ($TBinitStateOff)
    {
     $false {$initPwrState="On"}
     $true  {$initPwrState="Off"}

    }
    Write-Host "TB controller initial powerstate: $initPwrState"


    if ($TBinitStateOff -eq $true)
    {
        Write-Verbose "Powering the TB-controller..."
        $OnSucceeded=Set-ForceTbtPowerState -On


        [Array]$OkControllers=Get-PnpDevice -Class system | Where-Object {$_.Service -EQ "nhi" -and $_.Status -eq "OK"}
        $Loops=0
        While (($OkControllers.Count -eq 0) -and ($Loops -lt 15))
        {
            Start-Sleep -Seconds 1
            [Array]$OkControllers=Get-PnpDevice -Class system | Where-Object {$_.Service -EQ "nhi" -and $_.Status -eq "OK"}
            $Loops++
        }
        write-host "OK Controllers:" $($OkControllers.Count)
        Start-Sleep -Milliseconds 400
        if ($OkControllers.Count -eq 0)
        {
            write-host "Error, no TB-controllers found after forcing power on."
            break
        }
    }

    $TbtDrvType=Detect-TbtDrvType
    Write-Host "ThunderBolt Driver Type: $TbtDrvType"

    $info=Get-TbtControllerInfo -DrvType $TbtDrvType
							  
    $info= ($info | Select-Object -ExcludeProperty GetNeedPowerDownMessage,RTD3State,ControllerID,RunspaceId -Property * | Select-Object)

    if ($TBinitStateOff -eq $true)
    {
        Write-Verbose "Initial state of the TB-controller was 'Off'. Shutting it down..."
        $OffSucceeded=Set-ForceTbtPowerState -Off
    
    }
    else{
            Write-Verbose "Initial state of the controller was 'On'. Won't be turning it off."
        }
return $info
}
Get-ThunderboltInfo

