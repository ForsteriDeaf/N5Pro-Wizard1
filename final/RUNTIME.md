# N5pro Homelab Wizard - revisão minuciosa

Estrutura final pensada para:
- gist/raw
- github clonado
- manutenção futura sem perder contexto

## Ordem principal
1. `01-PVE_Host-PostInstall.sh`
2. reboot
3. `n5pro`
4. `n5pro-post`

## Fluxo lógico
### PVE
- `02-PBServer_PVE-CreateVM.sh`
- `03-Unraid-NAS_PVE-CreateVM.sh`

### PBS
- `04-PBServer_PBS-PostInstall.sh`

### PVE
- `05-PVE_PBS-AddStorage.sh`
- `06-PVE_PBS-CreateBackupJob.sh`

## Notas
- `final/common.sh` e `final/lib/common.sh` são iguais por opção, para manter a estrutura híbrida.
- o ficheiro real usado após o script 01 é `/etc/n5pro.conf`
- `06` ficou fora do fluxo principal e foi movido para legado
- o PBS usa disco externo direto; já não usa NFS do Unraid


## Nota importante
A base remota usada pelo `01` foi alinhada para a pasta `final/` do repositório GitHub:
`https://raw.githubusercontent.com/ForsteriDeaf/N5Pro-Wizard1/main/final`


## Atualização de ordem
A ordem foi revista para refletir a arquitetura atual:
`Proxmox -> PBS -> Unraid`

O PBS já não depende do Unraid/NFS para funcionar.


## Fusão auditada
Esta versão funde a base segura com as melhorias de automação sem retirar o que já foi construído até agora.
Inclui: PBS assistido, espera pelo PBS online, tentativa de injeção automática de n5pro-post/common.sh/config, datastore USB com menu, e wrapper 07->06 para compatibilidade.
