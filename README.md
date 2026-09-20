# Duindorp platform

## Branches

- `main`: ontwikkeling en standaardbranch.
- `staging`: versie voor deployment naar de staging-VPS.
- `production`: versie voor deployment naar de productie-VPS.

Alle drie de branches beginnen op dezelfde commit. Ontwikkeling vindt plaats op
`main`; geteste wijzigingen worden daarna naar `staging` en vervolgens naar
`production` gepromoveerd.

De GitHub Actions-workflows en VPS-configuratie moeten nog worden toegevoegd.
