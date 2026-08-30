function Get-ToolIpSwitch {
  <#
  .SYNOPSIS
    Return the IP-version CLI switches for tracert and pathping.
  .PARAMETER Protocol
    IPv4 or IPv6.
  .OUTPUTS
    [hashtable] Keys: Tracert and Pathping. Each value is a string flag (e.g. '-4', '/6').
  #>
  param([ValidateSet('IPv4', 'IPv6')]$Protocol)
  if ($Protocol -eq 'IPv6') {
    return @{ Tracert = '-6'; Pathping = '/6' }
  }
  return @{ Tracert = '-4'; Pathping = '/4' }
}
