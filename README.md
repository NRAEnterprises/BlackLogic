# BlackLogic

BlackLogic is a Bash-based Arch Linux installation and recovery toolkit designed for systems using LVM thin provisioning and Btrfs. It automates the creation of a resilient, bootable root filesystem with a fallback recovery workflow so the system can still boot and be repaired if a partitioning or mount issue occurs.

The project focuses on:

- automated Arch Linux installation
- LVM thin-pool root volume setup
- Btrfs root filesystem construction
- EFI + boot partition management
- recovery and repair helpers for failed installs
- staged orchestration for safer preparation and installation

## Project goals

BlackLogic aims to keep a system bootable by creating a structured installation flow that separates:

- environment preparation
- drive formatting and partition setup
- installation of the base OS
- post-install recovery and verification

This is especially useful when working with a custom Arch installation layout that includes a dedicated recovery or surgery volume, thin-provisioned root storage, and persistent boot/EFI partitions.

## Repository layout

- `blacklogic.sh` — main orchestrator that runs the full pipeline
- `blacklogic-01-env.sh` — environment validation and setup
- `blacklogic-02-format.sh` — disk formatting and LVM/Btrfs preparation
- `blacklogic-03-install.sh` — Arch bootstrap, package install, GRUB setup
- `blacklogic-04-aftermath.sh` — final post-install cleanup and verification
- `blacklogic-fix-drives.sh` — repair helper for drive/partition problems
- `blacklogic-fix-mount.sh` — remount and recovery helper
- `blacklogic-fix-network.sh` — network configuration recovery helper
- `black_build.sh` — standalone build script for creating the base architecture manually
- `black_surgery.sh` — surgical recovery/maintenance helper
- `black_aftermath.sh` — legacy aftermath workflow

## Typical workflow

1. Boot into a live Arch environment as root.
2. Verify that the target disks are correct and writable.
3. Run the orchestrator:

```bash
bash /path/to/blacklogic.sh
```

This will run the install stages in sequence and automatically invoke recovery helpers if a stage fails.

## Manual/advanced usage

If you want to run the build process directly instead of using the staged orchestrator, use the build script:

```bash
bash black_build.sh
```

The helper scripts can also be used individually when debugging or recovering from install failures:

```bash
bash blacklogic-fix-drives.sh
bash blacklogic-fix-mount.sh
bash blacklogic-fix-network.sh
```

## Notes on the installation model

This project assumes a custom, Arch-focused layout with:

- GPT partitioning
- EFI System Partition
- Btrfs root volume
- LVM volume groups and thin pools
- boot and recovery separation
- optional `surgery_vg` and `black_vg` layout for resilient recovery workflows

Because the scripts write and modify partition tables, LVM metadata, and boot configuration, they are destructive by design and should only be run against test systems or systems you explicitly intend to reformat.

## Prerequisites

- Arch Linux live environment or equivalent bootable installer system
- root privileges
- compatible UEFI system
- target disks identified in advance
- understanding that the scripts will erase and recreate partitions and LVM structures

## Disclaimer

Use this project at your own risk. These scripts are intentionally aggressive with disk operations. Always back up important data before running them.

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.

## Contributing

Contributions, fixes, and improvements are welcome. If you extend the project, keep the tools conservative, document assumptions, and preserve the recovery-oriented behavior of the installation flow.
