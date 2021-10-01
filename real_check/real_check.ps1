#Copyright (c) Microsoft. All rights reserved.
#Licensed under the MIT license. See LICENSE file in the project root for full license information.
function Check-Symbols {
    param(
        [string] $lib
    )   
        try {
            [string]$output = cmd.exe /c dumpbin /ALL $lib
        }
        catch {
            Write-Error  "Unable to run dumpbin on given lib"
            return 2
        }
        $start_token = "public symbols"
        $end_token = "Archive member name"
        try {
            [int] $start = $output.IndexOf($start_token)
            [int] $end = $output.IndexOf($end_token, $start)
            $symbol_text = ($output.Substring($start + $start_token.Length+1, $end-$start-$start_token.Length-1))
            $split_symbols = $symbol_text.Split('',[StringSplitOptions]::RemoveEmptyEntries)
        }
        catch {
            Write-Error  "Unable to parse dumpbin output"
            return 2
        }
        if($split_symbols.Length -lt 2) {
            Write-Error  "Unable to parse dumpbin output"
            return 2
        }
        
        $real_prefix = "real_"
        $symbol_table = New-Object -TypeName "System.Collections.Generic.HashSet[string]"
        $duplicate_symbols = New-Object -TypeName "System.Collections.ArrayList"
    
        $return_code = 0
        for($i=0; $i -lt $split_symbols.Length; $i++){
            if($i % 2 -ne 0) {
                if($split_symbols[$i].StartsWith($real_prefix)) {
                    $real_symbol = $split_symbols[$i]
                    $symbol = $split_symbols[$i].Substring($real_prefix.Length)
                } else {
                    $symbol = $split_symbols[$i]
                    $real_symbol = $real_prefix + $symbol
                }
                if(-not ($symbol_table.Add($symbol) -and $symbol_table.Add($real_symbol))){
                    $return_code = 1
                    [void]$duplicate_symbols.Add($symbol)
                }
            }
        }
        if($duplicate_symbols.Count -gt 0){
            Write-Error ("The following symbols are duplicate:`n"+($duplicate_symbols -join "`n"))
        }
        return $return_code
}

exit (Check-Symbols -lib $args[0])
