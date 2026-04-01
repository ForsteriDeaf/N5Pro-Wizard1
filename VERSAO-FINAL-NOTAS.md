# Versão final consolidada

Inclui:
- ordem nova: 02 = PBS, 03 = Unraid, 06 = backup jobs
- IPs corrigidos para 192.168.50.x
- wizard PBS com pausa assistida, wait online, remoção automática da ISO e injeção do `n5pro-post`
- `04-PBServer_PBS-PostInstall.sh` com deteção/menu de discos USB e criação segura do datastore
- melhorias de reinstall-safe básicas: VMs/datastores/storages existentes são detetados e o script evita refazer trabalho sem confirmação
