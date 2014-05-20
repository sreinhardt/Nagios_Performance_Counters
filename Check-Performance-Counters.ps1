# Get-Performance-Counters.ps1
#
# A script to collect performance counters and return nagios based statuses for them. This is written with NCPA in mind, however could be used for any agent or without one.
# Spenser Reinhardt
# Nagios Enterprises LLC
# Copyright 2014
# License GPLv2 -  I reserve the right to change the licensing at any time without prior notification, past versions maintain the licensing at that point in time.
# I also extend all usage, duplication, and modification rights to Nagios Enterprises LLC, without the forceful inclusion of GPL licensing.

# Send to: http://support.nagios.com/forum/viewtopic.php?t=26199#92717

# Default settings for warning\crit strings. Need to see if I can leave them blank unless set and verify if they exist instead of default valules
[String]$DefaultString = "ABCD123"
[Int64]$DefaultInt = -99
[Int64]$State_OK = 0
[Int64]$State_Warn = 1
[Int64]$State_Crit = 2
[Int64]$State_Unknown = 3

# Counter "struct" to store values in a single object as we progress through the script and functions. (far easier to 
# pass function to function, and it's not c so no pointers afaik)
$CounterStruct = @{}
    [String]$CounterStruct.Hostname = ""
    [String]$CounterStruct.Counter = ""
    [String]$CounterStruct.Label = ""
    [Int]$CounterStruct.Time = 1
    [Int64]$CounterStruct.ExitCode = $State_Unknown
    [String]$CounterStruct.OutputString = "Unknown: There was an error processing performance counter data"
    [String]$CounterStruct.OkString = $DefaultString
    [String]$CounterStruct.WarnString = $DefaultString
    [String]$CounterStruct.CritString = $DefaultString
    [Int64]$CounterStruct.WarnHigh = $DefaultInt.ToInt64($null)
    [Int64]$CounterStruct.CritHigh = $DefaultInt.ToInt64($null)
    [Int64]$CounterStruct.WarnLow = $DefaultInt.ToInt64($null)
    [Int64]$CounterStruct.CritLow = $DefaultInt.ToInt64($null)
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
        default { $Return.OutputString = "Unknown: Failed to process exit code"; Exit $State_Unknown }
    }

    If ( $Return.Label -eq "" ) {
        $Return.OutputString += "Counter $($Return.Counter.ToString()) returned results"
    } Else {
        $Return.OutputString += "$($Return.Label.ToString()) returned results"
    }
    
    # Process result
    $Return.Result | ForEach-Object {
        $Return.OutputString += " $($_.CookedValue.ToString())"
    }

    $Return.OutputString += " | "
    
    [int]$c = 0

    $Return.Result | ForEach-Object {

        # Handle counters or labels
        If ( $Return.Label -eq "" ) {
            $Return.OutputString += "`'Counter $c`'="
        } Else {
            $Return.OutputString += "`'$($Return.Label.ToString()) $c`'="
        }

        # Handle adding counter values and warn\crit values for perfdata
        If ( ($_.CookedValue.GetType().Name -eq "Int") -or ($_.CookedValue.GetType().Name -eq "Double") ) {
            $Return.OutputString += "$($_.CookedValue.ToInt64($null));"
            
            If ($Return.WarnHigh.ToInt64($null) -ne $DefaultInt) { $Return.OutputString += "$($Return.WarnHigh.ToInt64($null));" }
            ElseIf ($Return.WarnLow.ToInt64($null) -ne $DefaultInt) { $Return.OutputString += "$($Return.WarnLow.ToInt64($null));" }
            Else { $Return.OutputString += ";" }

            If ($Return.CritHigh -ne $DefaultInt) { $Return.OutputString += "$($Return.CritHigh.ToInt64($null));" }
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
                    $Return.ExitCode = $State_OK
                    $ExitSet = $true
                }
            } 
            # Check warning string
            ElseIf ( ($Return.WarnString -ne $DefaultString) -and ($_ -eq $Return.WarnString) ) {
                # Check exitset and if so, check if greater than previously set code
                If ($Return.ExitCode -lt $State_Warn) {
                    $Return.ExitCode = $State_Warn
                    $ExitSet = $true
                }
            } 
            # Check critical string
            ElseIf ( ($Return.CritString -ne $DefaultString) -and ($_ -eq $Return.CritString) ) {
                #Check exitset and if so, check if greater than previously set code
                If ($Return.ExitCode -lt $State_Crit) {
                    $Return.ExitCode = $State_Crit
                    $ExitSet = $true
                }
            } 
            #Else if no string is set for checking, and exitset is false
            ElseIf ( ($Return.OkString -eq $DefaultString) -and ($Return.WarnString -eq $DefaultString) -and ($Return.CritString -eq $DefaultString) -and ($ExitSet -eq $false) ) {
                $Return.ExitCode = $State_OK
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

            # if we are lower than critlow or higher than crit high, crit
            If ( (($Return.CritLow.CompareTo($DefaultInt) -ne 0) -and ($_.CookedValue.ToInt64($null).CompareTo($Return.CritLow) -le 0)) -or (($Return.CritHigh.CompareTo($DefaultInt) -ne 0) -and ($_.CookedValue.ToInt64($null).CompareTo($Return.CritHigh) -ge 0)) ) {
                If ( (($Return.ExitCode.ToInt64($null).CompareTo($State_Crit) -gt 0) -and ($ExitSet -eq $true)) -or ($ExitSet -eq $false)  ) {
                    $Return.ExitCode = $State_Crit
                    $ExitSet = $true
                }
            }
            # if we are lower than warnlow or higher than warn high, warn
            ElseIf ( (($Return.WarnLow.CompareTo($DefaultInt) -ne 0) -and ($_.CookedValue.ToInt64($null).CompareTo($Return.WarnLow) -le 0)) -or (($Return.WarnHigh.CompareTo($DefaultInt) -ne 0) -and ($_.CookedValue.ToInt64($null).CompareTo($return.WarnHigh) -ge 0)) ) {
                If ( (($Return.ExitCode.ToInt64($null).CompareTo($State_Warn) -gt 0) -and ($ExitSet -eq $true)) -or ($ExitSet -eq $false) ) {
                    $Return.ExitCode = $State_Warn
                    $ExitSet = $true
                }
            } 
            # if all thresholds are still default, OK
            ElseIf ( ($Return.WarnLow.CompareTo($DefaultInt) -eq 0) -and ($Return.WarnHigh.CompareTo($DefaultInt) -eq 0) -and ($Return.CritLow.CompareTo($DefaultInt) -eq 0) -and ($Return.CritHigh.CompareTo($DefaultInt) -eq 0) ) {
                If ( $ExitSet -eq $false ) {
                    $Return.ExitCode = $State_OK
                    $ExitSet = $true
                }
            }
            # If none of these were caught, we must be within OK range, and not using default thresholds
            ElseIf ( $ExitSet -eq $false ) {
                $Return.ExitCode = $State_OK
                $ExitSet = $true
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
            Exit $State_Unknown
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

        If ( $Args.Count -lt 2 ) {
            Write-Help
        }

        For ( $i = 0; $i -lt $Args.count-1; $i++ ) {
            
            $CurrentArg = $Args[$i].ToString()
            $Value = $Args[$i+1]

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
                ElseIf ($CurrentArg -cmatch "-l") {
                    If (Check-Strings $Value) {
                        $Return.Label = $Value
                    }
                }
                ElseIf ($CurrentArg -match "--Label") {
                    If (Check-Strings $Value) {
                        $Return.Label = $Value
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
                                If (!$Value[0].Equals("")) { $Return.WarnLow = $Value[0].ToInt64($null) }
                                If (!$Value[1].Equals("")) { $Return.WarnHigh = $Value[1].ToInt64($null) }
                            }
                            Else { $Return.WarnString = $Value }
                        }
                        ElseIf ( ($Value.GetType().Name -like "Int32" ) -or ($Value.GetType().Name -like "Int64" ) -or ($Value.GetType().Name -eq "Double") ) {
                            $Return.WarnHigh = $Value.ToInt64($null)
                        }
                    }
                }                
                ElseIf ($CurrentArg -match "--Warning") {
                    If (Check-Strings $Value) {
                        If ( $Value.GetType().Name -like "String" ) {
                            If ( $Value.Contains(":") ) {
                                $Value = $Value.Split(":")
                                If (!$Value[0].Equals("")) { $Return.WarnLow = $Value[0].ToInt64($null) }
                                If (!$Value[1].Equals("")) { $Return.WarnHigh = $Value[1].ToInt64($null) }
                            }
                            Else { $Return.WarnString = $Value }
                        }
                        ElseIf ( ($Value.GetType().Name -like "Int32" ) -or ($Value.GetType().Name -like "Int64" ) -or ($Value.GetType().Name -eq "Double") ) {
                            $Return.WarnHigh = $Value.ToInt64($null)
                        }
                    }
                }
                ElseIf ($CurrentArg -cmatch "-c") {  
                    If (Check-Strings $Value) {
                        If ( $Value.GetType().Name -eq "String" ) {
                            If ( $Value.Contains(":") ) {
                                $Value = $Value.Split(":")
                                If (!$Value[0].Equals("")) { $Return.CritLow = $Value[0] }
                                If (!$Value[1].Equals("")) { $Return.CritHigh = $Value[1] }
                            }
                            Else { $Return.CritString = $Value }
                        }
                        ElseIf ( ($Value.GetType().Name -like "Int32" ) -or ($Value.GetType().Name -like "Int64" ) -or ($Value.GetType().Name -like "Double") ) {
                            $Return.CritHigh = $Value.ToInt64($null)
                        }
                    }
                }
                ElseIf ($CurrentArg -match "--Critical") {
                    If (Check-Strings $Value) {
                        If ( $Value.GetType().Name -eq "String" ) {
                            If ( $Value.Contains(":") ) {
                                $Value = $Value.Split(":")
                                If (!$Value[0].Equals("")) { $Return.CritLow = $Value[0] }
                                If (!$Value[1].Equals("")) { $Return.CritHigh = $Value[1] }
                            }
                            Else { $Return.CritString = $Value }
                        }
                        ElseIf ( ($Value.GetType().Name -like "Int32" ) -or ($Value.GetType().Name -like "Int64" ) -or ($Value.GetType().Name -like "Double") ) {
                            $Return.CritHigh = $Value.ToInt64($null)
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
    Write-Output "`tPresently this script only supports Powershell v3 and newer. Additions for older variants may be included in the future.`n"
    Write-Output "Arguments:"
    write-output "`t-H | --Hostname ) Optional hostname of remote system."
    Write-Output "`t-n | --Counter-Name) Name of performance counter to collect."
    Write-Output "`t-l | --Label) Name of label for counters, opposed to Counter[n], in output message"
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

    # If older than PS v3 write help and exit.
    If ( $PSVersionTable.PSVersion.Major -lt 3 ) { Write-Help }

    # Process arguments and insert into counter struct
    $CounterStruct = Process-Args $Args $CounterStruct

    # Attempt to get performance counter information
    $CounterStruct = Get-PerfCounter $CounterStruct

    $CounterStruct = Get-ExitCode $CounterStruct

    Write-Output-Message $CounterStruct

    # If we somehow get here, something is wrong
    Write-Output "Unknown: Something happened with the script."
    Exit $State_Unknown
}

# Execute main block
Check-Performance-Counters $args $CounterStruct