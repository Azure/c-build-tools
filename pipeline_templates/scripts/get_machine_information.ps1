# Copyright (C) Microsoft Corporation. All rights reserved.
# Comprehensive machine information diagnostic script for Azure DevOps pipelines.
# Collects hardware, OS, drive (with NVMe mapping), and software details.

Write-Host "=============================================="
Write-Host "  Machine Information Diagnostic Report"
Write-Host "=============================================="
Write-Host ""

# --- OS and System ---
Write-Host "--- OS and System Information ---"
try {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    Write-Host "Computer Name   : $($os.CSName)"
    Write-Host "OS              : $($os.Caption) $($os.Version)"
    Write-Host "Build Number    : $($os.BuildNumber)"
    Write-Host "Architecture    : $($os.OSArchitecture)"
    Write-Host "Install Date    : $($os.InstallDate)"
    Write-Host "Last Boot       : $($os.LastBootUpTime)"
    $uptimeSpan = (Get-Date) - $os.LastBootUpTime
    Write-Host "Uptime          : $([int]$uptimeSpan.TotalDays)d $($uptimeSpan.Hours)h $($uptimeSpan.Minutes)m"
    Write-Host "Total Memory    : $([math]::Round($os.TotalVisibleMemorySize / 1MB, 2)) GB"
    Write-Host "Free Memory     : $([math]::Round($os.FreePhysicalMemory / 1MB, 2)) GB"
} catch {
    Write-Host "Failed to get OS information: $_"
}
Write-Host ""

# --- Processor ---
Write-Host "--- Processor Information ---"
try {
    Get-CimInstance -ClassName Win32_Processor | ForEach-Object {
        Write-Host "Name            : $($_.Name)"
        Write-Host "Cores           : $($_.NumberOfCores)"
        Write-Host "Logical CPUs    : $($_.NumberOfLogicalProcessors)"
        Write-Host "Max Clock       : $($_.MaxClockSpeed) MHz"
        Write-Host "Architecture    : $($_.Architecture)"
        Write-Host "L2 Cache        : $($_.L2CacheSize) KB"
        Write-Host "L3 Cache        : $($_.L3CacheSize) KB"
    }
} catch {
    Write-Host "Failed to get processor information: $_"
}
Write-Host ""

# --- Memory ---
Write-Host "--- Physical Memory ---"
try {
    Get-CimInstance -ClassName Win32_PhysicalMemory | ForEach-Object {
        $sizeGB = [math]::Round($_.Capacity / 1GB, 2)
        Write-Host "  Slot: $($_.DeviceLocator) | Size: ${sizeGB} GB | Speed: $($_.Speed) MHz | Type: $($_.MemoryType)"
    }
} catch {
    Write-Host "Failed to get memory information: $_"
}
Write-Host ""

# --- Drive Information with NVMe Mapping ---
Write-Host "--- Physical Disks ---"
try {
    $physicalDisks = Get-PhysicalDisk | Sort-Object DeviceId
    foreach ($disk in $physicalDisks) {
        $sizeGB = [math]::Round($disk.Size / 1GB, 2)
        Write-Host "  Disk $($disk.DeviceId): $($disk.FriendlyName)"
        Write-Host "    Media Type  : $($disk.MediaType)"
        Write-Host "    Bus Type    : $($disk.BusType)"
        Write-Host "    Size        : ${sizeGB} GB"
        Write-Host "    Health      : $($disk.HealthStatus)"
        Write-Host "    Op Status   : $($disk.OperationalStatus)"

        if ($disk.BusType -eq 'NVMe') {
            Write-Host "    [NVMe Drive Detected]"
            # Get NVMe-specific details from CIM if available
            try {
                $storageAdapter = Get-CimInstance -Namespace root\Microsoft\Windows\Storage -ClassName MSFT_PhysicalDisk |
                    Where-Object { $_.DeviceId -eq $disk.DeviceId }
                if ($storageAdapter.FirmwareVersion) {
                    Write-Host "    Firmware    : $($storageAdapter.FirmwareVersion)"
                }
            } catch {
                # Silently continue if NVMe detail query fails
            }
        }
    }
} catch {
    Write-Host "Failed to get physical disk information: $_"
}
Write-Host ""

# --- Disk to Volume Mapping ---
Write-Host "--- Disk to Volume Mapping ---"
try {
    $diskToPartition = Get-CimInstance -ClassName Win32_DiskDriveToDiskPartition
    $partitionToLogical = Get-CimInstance -ClassName Win32_LogicalDiskToPartition

    foreach ($d2p in $diskToPartition) {
        $diskIndex = if ($d2p.Antecedent.DeviceID -match 'PHYSICALDRIVE(\d+)') { $Matches[1] } else { '?' }
        $partId = $d2p.Dependent.DeviceID

        $volumes = $partitionToLogical | Where-Object { $_.Antecedent.DeviceID -eq $partId }
        foreach ($vol in $volumes) {
            $driveLetter = $vol.Dependent.DeviceID
            Write-Host "  PhysicalDrive${diskIndex} -> $partId -> $driveLetter"
        }
    }
} catch {
    Write-Host "Failed to get disk-to-volume mapping: $_"
}
Write-Host ""

# --- Logical Volumes ---
Write-Host "--- Logical Volumes ---"
try {
    Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
        $totalGB = [math]::Round($_.Size / 1GB, 2)
        $freeGB = [math]::Round($_.FreeSpace / 1GB, 2)
        $usedPct = if ($_.Size -gt 0) { [math]::Round((1 - $_.FreeSpace / $_.Size) * 100, 1) } else { 0 }
        Write-Host "  $($_.DeviceID) | Total: ${totalGB} GB | Free: ${freeGB} GB | Used: ${usedPct}%"
    }
} catch {
    Write-Host "Failed to get logical volume information: $_"
}
Write-Host ""

# --- Key Software Versions ---
Write-Host "--- Software Versions ---"

$tools = @(
    @{ Name = "CMake";       Cmd = "cmake";       Args = "--version" },
    @{ Name = "Git";         Cmd = "git";         Args = "--version" },
    @{ Name = "Visual Studio"; Cmd = "";           Args = "" },
    @{ Name = "dotnet";      Cmd = "dotnet";      Args = "--version" },
    @{ Name = "PowerShell";  Cmd = "pwsh";        Args = "-Version" }
)

foreach ($tool in $tools) {
    if ($tool.Name -eq "Visual Studio") {
        try {
            $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
            if (Test-Path $vswhere) {
                $vsInfo = & $vswhere -latest -products * -format json | ConvertFrom-Json
                if ($vsInfo) {
                    Write-Host "  Visual Studio : $($vsInfo[0].displayName) ($($vsInfo[0].installationVersion))"
                    Write-Host "    Path        : $($vsInfo[0].installationPath)"
                }
            } else {
                Write-Host "  Visual Studio : vswhere not found"
            }
        } catch {
            Write-Host "  Visual Studio : detection failed"
        }
        continue
    }

    if ($tool.Name -eq "PowerShell") {
        Write-Host "  PowerShell    : $($PSVersionTable.PSVersion)"
        continue
    }

    try {
        $output = & $tool.Cmd $tool.Args 2>&1 | Select-Object -First 1
        Write-Host "  $($tool.Name.PadRight(14)) : $output"
    } catch {
        Write-Host "  $($tool.Name.PadRight(14)) : not found"
    }
}
Write-Host ""

# --- Environment Variables (build-relevant) ---
Write-Host "--- Build Environment Variables ---"
$buildVars = @(
    'BUILD_BINARIESDIRECTORY',
    'BUILD_SOURCESDIRECTORY',
    'AGENT_MACHINENAME',
    'AGENT_OS',
    'AGENT_OSARCHITECTURE',
    'VCPKG_ROOT',
    'VCPKG_DEFAULT_TRIPLET'
)
foreach ($var in $buildVars) {
    $val = [Environment]::GetEnvironmentVariable($var)
    if ($val) {
        Write-Host "  ${var} = ${val}"
    }
}
Write-Host ""

Write-Host "=============================================="
Write-Host "  End of Machine Information Report"
Write-Host "=============================================="
