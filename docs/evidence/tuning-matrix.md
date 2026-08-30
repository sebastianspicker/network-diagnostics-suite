# Windows tuning scope

The public Windows tuning profiles include a limited set of settings. Inclusion
means the setting is implemented and covered by automated unit or dry-run tests.
It does not establish that the setting improves a specific workload.

| Setting | Profile | Apply behavior |
| --- | --- | --- |
| Local QoS marking registry value | `Safe`, `Measured` | Sets `Do not use NLA` under the Windows TCP/IP QoS key |
| UDP port DSCP policies | `Safe`, `Measured` | Creates one managed `NetQosPolicy` per requested UDP port |
| Application DSCP policies | `Safe`, `Measured` | Creates managed policies only when `-IncludeAppPolicies` and `-AppPaths` are supplied |
| Energy Efficient Ethernet | `Measured` | Attempts to disable standardized NIC keyword `*EEE` |
| Green Ethernet | `Measured` | Attempts to disable standardized NIC keyword `*GreenEthernet` |
| Power Saving Mode | `Measured` | Attempts to disable standardized NIC keyword `*PowerSavingMode` |
| High Performance power plan | `Measured` | Selected by default for the profile |

The public Apply path does not change these settings:

- interrupt moderation
- flow control
- UDP, TCP, or large-send offload
- `NetworkThrottlingIndex`
- AFD thresholds
- MMCSS audio task values
- Game DVR state
- arbitrary registry tuning bundles

Retired historical mutation and reset paths are not loaded by the module and
are not part of any current profile.

## Mutation controls

- Apply must produce and validate a complete backup before mutation.
- The backup manifest records schema and component metadata plus artifact
  digests.
- Restore validates manifest structure, compatibility, component state,
  artifacts, digests, registry content, and backup path trust.
- Restore consumes a protected staged copy and revalidates it before each
  component.
- Managed QoS cleanup is limited to known Network Lantern and compatibility
  prefixes.
- `-DryRun` performs no backup or Windows configuration write.

## Verification status

| Evidence | Status |
| --- | --- |
| `Safe` and `Measured` direct dry runs | Verified on Windows without elevation |
| Umbrella Windows tuning dry run | Verified on Windows without elevation |
| Backup refusal before mutation | Covered by Pester |
| Manifest shape, schema, digest, path, registry-content, and staging checks | Covered by Pester |
| Managed QoS ownership boundaries | Covered by Pester |
| Native elevated apply, injected failure, and restore | Not verified for this revision |

Do not treat real Windows mutation as a supported recovery workflow until the
last item is exercised on a disposable VM with an independent recovery method.
