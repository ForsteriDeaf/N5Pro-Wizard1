N5Pro Wizard - auditoria e fusão final

Base: N5Pro-Wizard_safe.zip
Melhorias fundidas de: N5Pro-Wizard-FINAL-real.zip

Aplicado:
- 01 coerente com ordem PBS -> Unraid
- 02 PBS assistido + wait_for_pbs_online + tentativa de injeção automática
- 03 Unraid com display VMware e boot NVMe -> USB
- 04 datastore USB com menu e proteção básica em reinstalação
- 05 aponta para 06
- 06 consolidado como backup jobs principal
- 07 mantido como wrapper de compatibilidade

Notas:
- a injeção automática para PBS pede a password root do PBS
- se carregares ENTER nessa pergunta, a injeção é saltada sem falhar o processo
- esta versão tenta não reduzir nem retirar o que já foi feito até agora
