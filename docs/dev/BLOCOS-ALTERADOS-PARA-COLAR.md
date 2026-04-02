# Alterações aplicadas nesta revisão

## Ordem nova
- 01 = Proxmox host
- 02 = PBS VM
- 03 = Unraid VM
- 04 = PBS post-install
- 05 = Add PBS storage no PVE
- 07 = Create backup jobs
- legacy/06 = NFS antigo fora do fluxo

## Melhorias aplicadas
- `02-PBServer_PVE-CreateVM.sh`
  - ordem nova PBS primeiro
  - pausa assistida para instalação do PBS
  - instruções explícitas:
    - Filesystem: ZFS (RAID0)
    - resto em default
    - Hostname: pbs.forsteri.n5pro
    - IP: 192.168.1.110
  - stop automático da VM
  - remoção automática da ISO
  - start automático da PBS já sem ISO

- `03-Unraid-NAS_PVE-CreateVM.sh`
  - display alterado para VMware
  - boot order atualizado:
    - 1º NVMe passthrough
    - 2º USB
  - mensagens finais alinhadas com Unraid 7.3 beta
  - shares finais reforçadas (`apps`, `domains`, `system`, `isos`, `storage_*`)

- `01-PVE_Host-PostInstall.sh`
  - `n5pro-post` atualizado para a nova ordem
  - menus manuais trocados para refletir 02=PBS e 03=Unraid
