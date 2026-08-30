# Central constants for registry paths (reg.exe vs PowerShell provider), backup file names, and defaults.
# Dot-sourced first by the module so all Private/Public scripts can reference them.

# Registry paths for PowerShell provider (with colon)
$script:NetworkTuningRegistryPathSystemProfile = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
$script:NetworkTuningRegistryPathAfdParameters = 'HKLM:\SYSTEM\CurrentControlSet\Services\AFD\Parameters'
$script:NetworkTuningRegistryPathQos = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\QoS'

# Default backup folder, exposed through Get-NetworkLanternDefaultBackupFolder.
# On non-Windows (e.g. tests on macOS) avoid C: drive so Join-Path does not fail
$script:NetworkTuningDefaultBackupFolderBase = if ([string]::IsNullOrWhiteSpace($env:ProgramData)) {
  if ($env:OS -eq 'Windows_NT') { 'C:\ProgramData' } else { [System.IO.Path]::GetTempPath().TrimEnd([System.IO.Path]::DirectorySeparatorChar) }
} else {
  $env:ProgramData
}
$script:NetworkTuningDefaultBackupFolder = Join-Path -Path $script:NetworkTuningDefaultBackupFolderBase -ChildPath 'NetworkLantern'
$script:NetworkTuningLegacyDefaultBackupFolder = Join-Path -Path $script:NetworkTuningDefaultBackupFolderBase -ChildPath 'NetworkDiagnosticsSuite'
$script:NetworkTuningToolName = 'network-lantern'
$script:NetworkTuningCompatibleToolNames = @($script:NetworkTuningToolName, 'network-diagnostics-suite')

# Backup file names (child names under BackupFolder)
$script:NetworkTuningBackupFileManifest = 'backup_manifest.json'
$script:NetworkTuningBackupFileSystemProfile = 'SystemProfile.reg'
$script:NetworkTuningBackupFileAfdParameters = 'AFD_Parameters.reg'
$script:NetworkTuningBackupFileQosOurs = 'qos_ours.xml'
$script:NetworkTuningBackupFileNicAdvanced = 'nic_advanced_backup.csv'
$script:NetworkTuningBackupFileRsc = 'rsc_backup.csv'
$script:NetworkTuningBackupFilePowerplan = 'powerplan.txt'
$script:NetworkTuningBackupSchemaVersion = 3
$script:NetworkTuningMaxManifestBytes = 1MB
$script:NetworkTuningMaxRegistryBackupBytes = 1MB
$script:NetworkTuningMaxCsvBackupBytes = 1MB
$script:NetworkTuningMaxQosBackupBytes = 4MB
$script:NetworkTuningMaxBackupRows = 512
$script:NetworkTuningMaxBackupJsonDepth = 32

# Default DSCP value for QoS policies (EF / Expedited Forwarding)
$script:NetworkTuningDefaultDscp = 46

# Windows power plan GUIDs
$script:NetworkTuningPowerPlanGuidBalanced        = '381b4222-f694-41f0-9685-ff5bb260df2e'
$script:NetworkTuningPowerPlanGuidHighPerformance = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
$script:NetworkTuningPowerPlanGuidUltimate        = 'e9a42b02-d5df-448d-aa00-03f14749eb61'

# QoS naming ownership boundaries managed by this module.
# Only these prefixes are treated as removable/restorable managed policies.
$script:NetworkTuningQosPortPrefix = 'NETWORK_LANTERN_QOS_PORT_'
$script:NetworkTuningQosAppPrefix = 'NETWORK_LANTERN_QOS_APP_'
$script:NetworkTuningManagedQosNamePrefixes = @(
  $script:NetworkTuningQosPortPrefix,
  $script:NetworkTuningQosAppPrefix,
  'NDS_QOS_PORT_',
  'NDS_QOS_APP_',
  'QoS_UDP_TS_',
  'QoS_UDP_CS2_',
  'QoS_APP_'
)

# Maximum number of per-port QoS policies (cap for large port ranges)
$script:NetworkTuningMaxPortPolicies = 100

# Standardized Registry Keywords (Microsoft specification) for NIC properties.
# These are locale-independent and driver-agnostic.
$script:NetworkTuningNicKeywordMap = @{
  'Energy Efficient Ethernet'      = '*EEE'
  'Interrupt Moderation'           = '*InterruptModeration'
  'Flow Control'                   = '*FlowControl'
  'Jumbo Packet'                   = '*JumboPacket'
  'Large Send Offload v2 (IPv4)'   = '*LsoV2IPv4'
  'Large Send Offload v2 (IPv6)'   = '*LsoV2IPv6'
  'UDP Checksum Offload (IPv4)'    = '*UDPChecksumOffloadIPv4'
  'UDP Checksum Offload (IPv6)'    = '*UDPChecksumOffloadIPv6'
  'TCP Checksum Offload (IPv4)'    = '*TCPChecksumOffloadIPv4'
  'TCP Checksum Offload (IPv6)'    = '*TCPChecksumOffloadIPv6'
  'ARP Offload'                    = '*ARPOffload'
  'NS Offload'                     = '*NSOffload'
  'Wake on Magic Packet'           = '*WakeOnMagicPacket'
  'Wake on pattern match'          = '*WakeOnPattern'
  'ITR'                            = '*InterruptModerationRate'
  'Receive Buffers'                = '*ReceiveBuffers'
  'Transmit Buffers'               = '*TransmitBuffers'
  # Additional standardized keywords for NIC power and link properties
  'Green Ethernet'                 = '*GreenEthernet'
  'Power Saving Mode'              = '*PowerSavingMode'
  'WOL & Shutdown Link Speed'      = '*WakeOnLink'
}

# NIC keywords classified by evidence strength and impact tier.
# Tier 1 (Safe): Zero-risk, no tradeoffs. Power-saving disables.
$script:NetworkTuningNicKeywordsTier1 = @('*EEE', '*GreenEthernet', '*PowerSavingMode')

# Tier 2 (Moderate): Proven with small documented tradeoffs (slightly higher CPU).
$script:NetworkTuningNicKeywordsTier2 = @('*InterruptModeration', '*FlowControl')

# Tier 3 (Aggressive): Maximum UDP optimization, measurable tradeoffs.
$script:NetworkTuningNicKeywordsTier3 = @('*UDPChecksumOffloadIPv4', '*UDPChecksumOffloadIPv6', '*InterruptModerationRate')

# Experimental: TCP-only, WoL/sleep-only, or unproven settings.
# These have zero proven impact on UDP jitter during active use.
$script:NetworkTuningNicKeywordsExperimental = @(
  '*TCPChecksumOffloadIPv4', '*TCPChecksumOffloadIPv6',
  '*LsoV2IPv4', '*LsoV2IPv6',
  '*ARPOffload', '*NSOffload',
  '*WakeOnMagicPacket', '*WakeOnPattern', '*WakeOnLink',
  '*JumboPacket',
  '*ReceiveBuffers', '*TransmitBuffers'
)

# Reverse lookup: keyword -> display name (for logging)
$script:NetworkTuningNicKeywordReverseMap = @{}
foreach ($entry in $script:NetworkTuningNicKeywordMap.GetEnumerator()) {
  $script:NetworkTuningNicKeywordReverseMap[$entry.Value] = $entry.Key
}
