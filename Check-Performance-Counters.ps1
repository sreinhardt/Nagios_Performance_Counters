# Get-Performance-Counters.ps1
#
# A script to collect performance counters and return nagios based statuses for them. This is written with NCPA in mind, however could be used for any agent or without one.
# Spenser Reinhardt
# Nagios Enterprises LLC
# Copyright 2014
# License GPLv2 -  I reserve the right to change the licensing at any time without prior notification, past versions maintain the licensing at that point in time.
# I also extend all usage, duplication, and modification rights to Nagios Enterprises LLC, without the forceful inclusion of GPL licensing.

# Send to: http://support.nagios.com/forum/viewtopic.php?t=26199#92717

# TODO:
# Filter all input for |, `, `n, and ;

# Counter "struct" to store values in a single object as we progress through the script and functions. (far easier to 
# pass function to function, and it's not c so no pointers afaik)
$CounterStruct = @{}
    [string]$CounterStruct.Hostname = ""
    [string]$CounterStruct.Counter = ""
    [int]$CounterStruct.Time = "1"
    [Int]$CounterStruct.ExitCode = 3
    [String]$CounterStruct.OutputString = "Critical: There was an error processing performance counter data"
    [String]$CounterStruct.OkString = "ABCD123"
    [String]$CounterStruct.WarnString = "ABCD123"
    [String]$CounterStruct.CritString = "ABCD123"
    [Int]$CounterStruct.WarnHigh = -99
    [Int]$CounterStruct.CritHigh = -99
    [Int]$CounterStruct.WarnLow = -99
    [Int]$CounterStruct.CritLow = -99
    $CounterStruct.Result 

# Function to write output and exit properly per nagios guidelines.
Function Write-Output-Message {
    
    Param ( [Parameter(Mandatory=$true)]$Return )

    # Begin output message
    Switch ( $Return.ExitCode ) {
        0 { $Return.OutputString = "OK: " }
        1 { $Return.OutputString = "Warning: " }
        2 { $Return.OutputString = "Critical: " }
        3 { $Return.OutputString = "Unknown: " }
        default { $Return.OutputString = "Unknown: Failed to process exit code"; Exit 3 }
    }

    $Return.OutputString += "Counter $($Return.Counter.ToString()) returned results"
    
    # Process result
    $Return.Result | ForEach-Object {
        $Return.OutputString += " $($_.CookedValue.ToString())"
    }

    $Return.OutputString += " | "
    
    [int]$c = 0

    $Return.Result | ForEach-Object {

        If ( ($_.CookedValue.GetType().Name -eq "Int") -or ($_.CookedValue.GetType().Name -eq "Double") ) {
            $Return.OutputString += "`'Counter$c`'=$($_.CookedValue.ToInt32($test));"
            
            If ($Return.WarnHigh.ToInt32($test) -ne -99) { $Return.OutputString += "$($Return.WarnHigh.ToInt32($test));" }
            ElseIf ($Return.WarnLow.ToInt32($test) -ne -99) { $Return.OutputString += "$($Return.WarnLow.ToInt32($test));" }
            Else { $Return.OutputString += ";" }

            If ($Return.CritHigh -ne -99) { $Return.OutputString += "$($Return.CritHigh.ToInt32($test));" }
            Else { $Return.OutputString += ";" }

            $Return.OutputString += "; "
        }
        $c++;
    }

    Write-Output $Return.OutputString
    Exit $Return.ExitCode

} # End Write-Output-Message    

# Function Get-Counter-List - For getting a listing of performance counters on this or a remote system, also possible to filter based on fuzzy matching.
# Mostly for future use cases. Not in use presently.

Function Get-Counter-List {
    
    Param ( 
        [Parameter(Mandatory=$false)][String]$ComputerName,
        [Parameter(Mandatory=$false)][String]$CounterType
    )

    # Create initial command
    $Command = "Get-Counter -ListSet *"

    # If a computer name was provided
    If ( $CounterType ) { $Command += "$CounterType*" }
    ElseIf ( $ComputerName ) { $Command += " -ComputerName $ComputerName" }

    # Append select to command before execution
    $Command += " | Select-Object -ExpandProperty Counter"

    # Invoke command and store result
    $Return = Invoke-Expression $Command

    # Validate $Return was set and return with it if it was.
    If ( $Return ) { Return $Return }

    # Fallthrough
    Return "Failed"

} # End Get-Counter-List

# Function to get performance counters from the system and clobber them into our structure and use case, $Return should be $CounterStruct
Function Get-PerfCounter {

    Param (
        [Parameter(Mandatory=$true)]$Return
    )

    $Command = "Get-Counter -Counter `'$($Return.Counter.tostring())`'"

    # If any additional params were provided add to command string with flag.
    If ( $Return.HostName ) { $Command += " -ComputerName `'$([string]$Return.HostName)`'" }
    If ( $Return.Time -ne 1 ) { $Command += " -SampleInterval $([int]$Return.Time)" }
    
    # Push counter samples into return.result, as they contain all(?) relevant data opposed to the whole counter
    $Return.Result = $(Invoke-Expression $Command).CounterSamples

    Return $Return

} # End Get-PerfCounter

# Function to check results against provided warning and critical values and determine exit code\output message
# Note: By absolutely no means, is this a completed fully fledged thresholds compliant function. 
# It will be replaced with a future include that will be much more comprehensive.

Function Get-ExitCode {

    Param ( [Parameter(Mandatory=$True)]$Return )

    # Defualt settings for warning\crit strings. Need to see if I can leave them blank unless set and verify if they exist instead of default valules
    [String]$DefaultString = "ABCD123"
    [Int]$DefaultInt = -99
    [Boolean]$ExitSet = $false
    
    # Determine exit code by checking cooked values from counter
    $Return.Result | ForEach-Object {

        $Type = $_.CookedValue.GetType().name

        # Start with type of cooked value
        # TODO - Look into doing a for\foreach-object loop for this, but it gets tricky when we may not know the object name of what we are checking against
        If ( $Type -eq "String" ) {

            # Check OK string
            If ( ($Return.OkString -ne $DefaultString) -and ($_ -eq $Return.OkString) ) {
                # Only need to check if exitset is not true, otherwise we may have warning or critical already set
                If ( $ExitSet -eq $false ) {
                    $Return.ExitCode = 0
                    $ExitSet = $true
                }
            } 
            # Check warning string
            ElseIf ( ($Return.WarnString -ne $DefaultString) -and ($_ -eq $Return.WarnString) ) {
                # Check exitset and if so, check if greater than previously set code
                If ($Return.ExitCode -lt 1) {
                    $Return.ExitCode = 1
                    $ExitSet = $true
                }
            } 
            # Check critical string
            ElseIf ( ($Return.CritString -ne $DefaultString) -and ($_ -eq $Return.CritString) ) {
                #Check exitset and if so, check if greater than previously set code
                If ($Return.ExitCode -lt 2) {
                    $Return.ExitCode = 2
                    $ExitSet = $true
                }
            } 
            #Else if no string is set for checking, and exitset is false
            ElseIf ( ($Return.OkString -eq $DefaultString) -and ($Return.WarnString -eq $DefaultString) -and ($Return.CritString -eq $DefaultString) -and ($ExitSet -eq $false) ) {
                $Return.ExitCode = 0
                $ExitSet = $true
            }
        } # end string statements and begin int\double statements
        ElseIf ( ($Type -like "Double") -or ($Type -like "Int") ) {

            # Check OK - These are GROSS... but without the include there isn't a better way of handling it.
            # Checking if low and high values are default still and if not then should fit result < low || high < result, then we can use this as status as is outside
            # the give range. We should expect that a single value for thresholds will currently be set as a high counter not low.

            #value.compareto($lesserVal) = 1 (value > lesserval)
            #value.compareto($equalVal) = 0 (value == equalval)
            #value.compareto($greaterVal) = -1 (value < greaterval)
            # if we are lower than warnlow or higher than warn high, warn
            If ( (($Return.WarnLow.CompareTo($DefaultInt) -ne 0) -and ($_.CookedValue.ToInt32($test).CompareTo($Return.WarnLow) -le 0)) -or (($Return.WarnHigh.CompareTo($DefaultInt) -ne 0) -and ($_.CookedValue.ToInt32($test).CompareTo($return.WarnHigh) -ge 0)) ) {
                If ( $Return.ExitCode -lt 1 ) {
                    $Return.ExitCode = 1
                    $ExitSet = $true
                }
            } 
            # if we are lower than critlow or higher than crit high, crit
            ElseIf ( (($Return.CritLow -ne $DefaultInt) -or ($_.CookedValue.ToInt32($test) -lt $Return.CritLow)) -and (($Return.CritHigh -ne $DefaultInt) -or ($Return.CritHigh -lt $_.CookedValue.ToInt32($test))) ) {
                If ( $Return.ExitCode -lt 2 ) {
                    $Return.ExitCode = 2
                    $ExitSet = $true
                }
            }
            # if all thresholds are still default, OK
            ElseIf ( ($Return.WarnLow -eq $DefaultInt) -and ($Return.WarnHigh -eq $DefaultInt) -and ($Return.CritLow -eq $DefaultInt) -and ($Return.CritHigh -eq $DefaultInt) ) {
                If ( $ExitSet -eq $false ) {
                    $Return.ExitCode = 0
                    $ExitSet = $true
                }
            }
            # If none of these were caught, we must be within OK range, and not using default thresholds
            Else {
                If ( $ExitSet -eq $false ) {
                    $Return.ExitCode = 0
                    $ExitSet = $true
                } 
            }

        } # End ifelse for double\int
    } # End for loop on cooked counters

    #Return $return as we are done
    Return $Return

} # End Function Get-ExitCode

# Function to check strings for invalid and potentially malicious chars. Since we are creating and executing commands dynamically with "eval", we need to be sure
# nothing funky can happen.... ie executing unintentional\multiple commands from a single string. Sorry users, I don't trust you. :)

Function Check-Strings {

    Param ( [Parameter(Mandatory=$True)][string]$String )

    # `, `n, |, ; are bad, I think we can leave {}, @, and $ at this point.
    $BadChars=@("``", "|", ";", "`n")

    $BadChars | ForEach-Object {

        If ( $String.Contains("$_") ) {
            Write-Host "Unknown: String contains illegal characters."
            Exit 3
        }

    } # end for

    Return $true
} # end check-strings

# Function to handle args in a nagios style fasion.

Function Process-Args {
    
    Param ( 
        [Parameter(Mandatory=$True)]$Args,
        [Parameter(Mandatory=$True)]$Return
    )

        For ( $i = 0; $i -lt $Args.count-1; $i++ ) {
            
            $CurrentArg = $Args[$i].ToString()
            $Value = $Args[$i+1]

            write-host "beginning for $CurrentArg - $Value"

                If ($CurrentArg -cmatch "-H") {
                    If (Check-Strings $Value) {
                        $Return.Hostname = $Value  
                    }
                }
                ElseIf ($CurrentArg -match "--Hostname") {
                    If (Check-Strings $Value) {
                        $Return.Hostname = $Value
                    }
                }
                ElseIf ($CurrentArg -cmatch "-n") { 
                    If (Check-Strings $Value) {
                        $Return.Counter = $Value
                    }
                }
                ElseIf ($CurrentArg -match "--Counter-Name") { 
                ElseIf (Check-Strings $Value) {
                        $Return.Counter = $Value
                    }
                }
                ElseIf ($CurrentArg -cmatch "-t") { 
                    If (Check-Strings $Value) {
                        $Return.Time = $Value
                    }
                }
                ElseIf ($CurrentArg -match "--Time") { 
                    If (Check-Strings $Value ){
                        $Return.Time = $Value
                    }
                }
                ElseIf ($CurrentArg -cmatch "-w") {
                    If (Check-Strings $Value) {
                        If ( $Value.GetType().Name -like "String" ) {
                            If ( $Value.Contains(":") ) {
                                $Value = $Value.Split(":")
                                $Return.WarnHigh = $Value[1]
                                $Return.WarnLow = $Value[2]
                            }
                            Else { $Return.WarnString = $Value }
                        }
                        ElseIf ( ($Value.GetType().Name -like "Int32" ) -or ($Value.GetType().Name -eq "Double") ) {
                            $Return.WarnHigh = $Value.toInt32($test)
                        }
                    }
                }                
                ElseIf ($CurrentArg -match "--Warning") {
                    If (Check-Strings $Value) {
                        If ( $Value.GetType().Name -like "String" ) {
                            If ( $Value.Contains(":") ) {
                                $Value = $Value.Split(":")
                                $Return.WarnHigh = $Value[1]
                                $Return.WarnLow = $Value[2]
                            }
                            Else { $Return.WarnString = $Value }
                        }
                        ElseIf ( ($Value.GetType().Name -like "Int32" ) -or ($Value.GetType().Name -eq "Double") ) {
                            $Return.WarnHigh = $Value.toInt32($test)
                        }
                    }
                }
                ElseIf ($CurrentArg -cmatch "-c") {  
                    If (Check-Strings $Value) {
                        If ( $Value.GetType().Name -eq "String" ) {
                            If ( $Value.Contains(":") ) {
                                $Value = $Value.Split(":")
                                $Return.CritHigh = $Value[1]
                                $Return.CritLow = $Value[2]
                            }
                            Else { $Return.CritString = $Value }
                        }
                        ElseIf ( ($Value.GetType().Name -like "Int32" ) -or ($Value.GetType().Name -like "Double") ) {
                            $Return.CritHigh = $Value.toInt32($test)
                        }
                    }
                }
                ElseIf ($CurrentArg -match "--Critical") {
                    If (Check-Strings $Value) {
                        If ( $Value.GetType().Name -eq "String" ) {
                            If ( $Value.Contains(":") ) {
                                $Value = $Value.Split(":")
                                $Return.CritHigh = $Value[1]
                                $Return.CritLow = $Value[2]
                            }
                            Else { $Return.CritString = $Value }
                        }
                        ElseIf ( ($Value.GetType().Name -like "Int32" ) -or ($Value.GetType().Name -like "Double") ) {
                            $Return.CritHigh = $Value.toInt32($test)
                        }
                    }
                }
                ElseIf ($CurrentArg -cmatch "-h") { Write-Help }
                ElseIf ($CurrentArg -match "--help") { Write-Help }

        } # End for loop

    Return $Return

} # End Process Args

# Function to write help output
Function Write-Help {

    Write-Output "Check-Performance-Counters.ps1:`n`tThis script is designed to check performance counters and return them in a nagios style output."
    Write-Output "Arguments:"
    write-output "`t-H | --Hostname ) Optional hostname of remote system."
    Write-Output "`t-n | --Counter-Name) Name of performance counter to collect."
    Write-Output "`t-t | --Time ) Time in seconds for sample interval."
    Write-Output "`t-w | --Warning ) Warning string or number to check against. Somewhat matches plugins threshold guidelines"
    Write-Output "`t-c | --Critial ) Critical string or number to check against. Somewhat matches plugins threshold guidelines"
    Write-Output "`t-h | --Help ) Print this help output."
    Exit 3

} # end Write-Help

# Main function to kick off functionality

Function Check-Performance-Counters {
    
    Param ( 
        [Parameter(Mandatory=$True)]$Args,
        [Parameter(Mandatory=$True)]$CounterStruct
     )
    
    # Process arguments and insert into counter struct
    $CounterStruct = Process-Args $Args $CounterStruct

    # Attempt to get performance counter information
    $CounterStruct = Get-PerfCounter $CounterStruct

    $CounterStruct = Get-ExitCode $CounterStruct

    Write-Output-Message $CounterStruct

    # If we somehow get here, something is wrong
    Write-Output "Unknown: Something happened with the script."
    Exit 3
}

# Execute main block
Check-Performance-Counters $args $CounterStruct