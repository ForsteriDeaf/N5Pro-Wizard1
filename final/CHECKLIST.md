# CHECKLIST - revisão minuciosa

## Host Proxmox
- Web UI acessível
- `NVMe-Containers` existe
- IOMMU ativa
- `n5pro` funciona
- `n5pro-post` funciona

## Unraid VM
- VM criada
- passthrough SATA/NVMe/USB validado
- IP esperado confirmado

## PBS VM
- VM criada
- ISO associado corretamente
- datastore em disco externo direto
- storage PBS adicionado ao Proxmox
- jobs automáticos criados
