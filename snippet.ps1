<#
.SYNOPSIS
    Power off / on vSAN cluster.

.DESCRIPTION
    This PowerShell script enables the powering on or off of a vSAN cluster, and is supported by PowerCLI 13.1.
    It supports both vc not on vSAN and vc on vSAN cases.
    The cmdlets Start-VsanCluster and Stop-VsanCluster were newly added to PowerCLI 13.1 and provide the same functionality.
    This script serves as an additional sample for customers to utilize.
    (Before running this script, please remember to connect to VIServer)
    

.EXAMPLE
    PS C:\> .\vsan_cluster_shut_down.ps1 -ClusterName 'cluster-1' -Action 'poweroff'
    PS C:\> .\vsan_cluster_shut_down.ps1 -ClusterName 'cluster-1' -Action 'poweron'

.NOTES
    Author                                    : Nichole Yang
    Version                                   : 0.1
    Requires                                  : PowerCLI 13.1 or higher
    Date                                      : Mar 2023
#>

Param(
    [Parameter(Mandatory=$true)][String]$ClusterName,
    [Parameter(Mandatory=$true)][String]$Action
)

$VsanClusterPowerView = Get-VsanView -Id "VsanClusterPowerSystem-vsan-cluster-power-system"
$VsanClusterHealthView = Get-VsanView -Id "VsanVcClusterHealthSystem-vsan-cluster-health-system"
$VsanClusterConfigView = Get-VsanView -Id "VsanVcClusterConfigSystem-vsan-cluster-config-system"

$Cluster = Get-Cluster -Name $ClusterName
$global:VcOnVsan = $false

# A healthy vSAN cluster status is the prerequisite of powering off cluster.
# For vc on vSAN case, one of health test result is yellow. It will remind users of the orchestration host.
function Test-VsanHealth {
    param (
        [Parameter(Mandatory=$true)]
        [VMware.VimAutomation.ViCore.Impl.V1.Inventory.InventoryItemImpl]$Cluster
    )

    $healthData = $VsanClusterHealthView.VsanQueryVcClusterHealthSummary(
        $Cluster.ExtensionData.MoRef, $null, $null, $true, $null, $null, "clusterPowerOffPrecheck"
    )

    if ((($healthData | ConvertTo-Json -Depth 100) | ConvertFrom-Json).groups.Count -eq 0) {
        Write-Host "Groups are None"
        return 1
    }

    foreach ($group in (($healthData | ConvertTo-Json -Depth 100) | ConvertFrom-Json).groups) {
        $groupHealth = $group.groupHealth
        #Write-Host "Group health:" $groupHealth
        if ($groupHealth -ne "green") {
            foreach ($test in $group.groupTests) {
                $testHealth = $test.testHealth
                if ($testHealth -ne "green") {
                    $testId = $test.testId
                    $testName = $test.testName
                    Write-Host "FAIL: $testName"
                    if ($groupHealth -eq "yellow" -and $testHealth -eq "yellow" -and $testId -eq "com.vmware.vsan.health.test.vconvsan") {
                        $global:VcOnVsan = $true
                        $testHealthDetail = $test.testDetails
                        $refStr = $test.testDetails[0].rows[0].values[0]
                        # the value of refStr is like "mor:ManagedObjectReference:HostSystem:host-21"
                        $tokens = $refStr.split(':')
                        $obj_type = $tokens[2]
                        $obj_value = $tokens[3]
                        if ($obj_type -eq 'HostSystem') {
                            # Get the host system object
                            $host_id = 'HostSystem-' + $obj_value
                            $hostSystem = Get-VMHost -Id $host_id
                            Write-Host "The vCenter Server VM is hosted on this cluster and will be powered off.  You can monitor the shutdown process from host $($hostSystem.Name) while the vCenter server is unavailable"
                        } else {
                            Write-Host "This is vc on vSAN case, but it has error with fetching right orchestration host"
                            return 1
                        }              
                    } else {
                        return 1
                    }
                }
            }
        }
    }
    return 0
}

# Action supports "poweroff" and "poweron".
function powerActionCluster($VsanClusterPowerView, $Cluster, $Action) {
    
    $cspec = New-Object  VMware.Vsan.Views.PerformClusterPowerActionSpec

    if ($Action -eq "clusterPoweredOn") {
        $cspec.targetPowerStatus = "clusterPoweredOn"
    }
    elseif ($Action -eq "clusterPoweredOff") {
        $cspec.targetPowerStatus = "clusterPoweredOff"
        $cspec.powerOffReason = "Scheduled maintenance"
    }

    $vsanTask = $VsanClusterPowerView.PerformClusterPowerAction($Cluster.ExtensionData.MoRef, $cspec)
    Write-Host "Start $($cspec.targetPowerStatus)..."
    # vc on vsan case will shut down the vc, so we cannot get task status from vc api.

    while ($true) {
        try {
            $vcTask = Get-Task -Id $vsanTask
            Write-Progress -Activity "Power off $Cluster" -Status $vcTask.State -PercentComplete $vcTask.PercentComplete
            Start-Sleep -Milliseconds 250
            if ($vcTask.PercentComplete -eq 100) {
                break
            }
            if ($vcTask.State -eq 'Error') {
                Write-Host "The cluster, $Cluster, encountered an error when powering off." -foregroundcolor red -backgroundcolor white
                Exit
            } 
        } catch {
            Write-Host "Error occurred: $_. Exiting loop." -foregroundcolor red -backgroundcolor white
            if ($global:VcOnVsan -eq $true) {
                Write-Host "This is vc on vSAN case. After the power off task starts, please check status from orchestration host."
            }       
            break
        }          
    } 

    Write-Host "Finish."
}

# All hosts are connected is the prerequisite of powering on vSAN Cluster.
function precheckHostConnection($VsanClusterConfigView, $Cluster) {
    Write-Host "Start cluster shutdown power on precheck"
    $stats = $VsanClusterConfigView.VsanClusterGetRuntimeStats($Cluster.ExtensionData.MoRef, $null)
    $disconnectedHosts = @()
    foreach ($host_in_cluster in $stats) {
        if ($null -eq $host_in_cluster.stats -or !$host_in_cluster.stats) {
            $disconnectedHosts += $host_in_cluster.host
        }
    }
    if ($disconnectedHosts.Count -gt 0) {
        Write-Host "Disconnected hosts:" $disconnectedHosts
        return $false
    }
    return $true
}

# Main logic
if ($Action -eq "poweroff") {
    $result = Test-VsanHealth -Cluster $Cluster
    if ($result -eq 0) {
        Write-Host "Cluster health is good"
        powerActionCluster -VsanClusterPowerView $VsanClusterPowerView -cluster $Cluster -Action "clusterPoweredOff"
    } else {
        Write-Host "Cluster health is bad. You cannot power off the cluster. Please fix issues in health first."
    }
}
elseif ($Action -eq "poweron") {
    $result = precheckHostConnection -VsanClusterConfigView $VsanClusterConfigView -Cluster $Cluster
    if ($result) {
        powerActionCluster -VsanClusterPowerView $VsanClusterPowerView -Cluster $Cluster -Action "clusterPoweredOn"
    } else {
        Write-Host "Precheck failed due to disconnected hosts."
    }    
} else {
    Write-Host "Invalid power action."
}
