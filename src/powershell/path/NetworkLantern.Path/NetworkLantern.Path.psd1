@{
  RootModule        = 'NetworkLantern.Path.psm1'
  ModuleVersion     = '1.1.0'
  GUID              = 'dc2f47dc-8da4-4fec-867b-a3392370a881'
  Author            = 'Network Lantern contributors'
  CompanyName       = ''
  Copyright         = 'Copyright (c) 2025 sebastianspicker'
  Description       = 'Windows path diagnostics with dry-run planning and JSON/CSV result persistence.'
  PowerShellVersion = '7.0'
  CompatiblePSEditions = @('Core')
  FunctionsToExport = @('Invoke-NetworkPathDiagnostics')
  CmdletsToExport   = @()
  VariablesToExport = @()
  AliasesToExport   = @()
  PrivateData       = @{
    PSData = @{
      Tags = @('network', 'diagnostics', 'pathping', 'tracert')
      ReleaseNotes = 'Extracted the Path diagnostics implementation into an explicit PowerShell module.'
    }
  }
}
