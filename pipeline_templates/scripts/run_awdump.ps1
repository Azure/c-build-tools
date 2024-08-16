function Run-Awdump {
    param (
        [Parameter(Mandatory = $true)]
        [string]$ProcessName
    )

    #find awdump.exe (from https://eng.ms/docs/products/azure-watson/azurewatson/dumpcreationwithawdump)
    $output = wmic process where "name='MonAgentCore.exe'" get ExecutablePath

    Write-Output $output

    # Split the output into lines
    $lines = $output -split "`n"
    
    # Capture the second line (index 1 since PowerShell is 0-based)
    $secondLine = $lines[1].Trim()
    
    Write-Output $secondLine

    # Extract the directory from the full path
    $directory = [System.IO.Path]::GetDirectoryName($secondLine)
    
    # Define the new executable name
    $awdumpExecutable = "awdump.exe"
    
    # Combine the directory with the new executable name
    $fullAwdumpPath = [System.IO.Path]::Combine($directory, $newExecutable)

    # Get the process ID of the specified process name
    $processId = (Get-Process -Name $ProcessName).Id

    # Run awdump on the process
    Write-Output running now Start-Process -FilePath fullAwdumpPath -ArgumentList "create $processId -bypass"
    Start-Process -FilePath fullAwdumpPath -ArgumentList "create $processId -bypass"
    Write-Output done running Start-Process -FilePath fullAwdumpPath -ArgumentList "create $processId -bypass"
}