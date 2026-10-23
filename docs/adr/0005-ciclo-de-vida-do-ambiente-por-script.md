# ADR 0005: Ciclo de vida do ambiente por script

## Status

Aceito — 2026-10-23

## Contexto

Na Fase 4, o ambiente `prod-simulated` é composto por até 15 repositórios independentes (rede base, cluster EKS, mensageria SQS/SNS, quatro repositórios de banco de dados, quatro microsserviços, HTTP API Gateway, duas funções AWS Lambda e monitoramento Datadog), distribuídos em seis camadas com dependências de `terraform_remote_state` e de rede entre si (§22 da arquitetura).

Como a solução opera em contas do **AWS Academy Learner Lab** com orçamento limitado e sessões de 4 horas cujas credenciais temporárias (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`) precisam ser renovadas manualmente no início de cada sessão (AD-26), manter todos os recursos ativos continuamente esgotaria os créditos da turma. Ao mesmo tempo, disparar manualmente os workflows de CD de cada repositório na ordem correta de subida e na ordem inversa de derrubada seria lento, propenso a erro humano e arriscaria deixar recursos órfãos cobrando após o término da sessão ou gerar alertas falsos no Datadog com o ambiente desligado.

## Decisão

Automatizar a subida e a derrubada completa do ambiente `prod-simulated` por meio de scripts Bash versionados neste repositório (`scripts/environment-layers.sh`, `scripts/environment-up.sh` e `scripts/environment-down.sh`), apoiados nos próprios workflows `cd.yml` de cada repositório via GitHub CLI (`gh workflow run` e `gh run watch`):

1. **Tabela única de camadas em script versionado (`scripts/environment-layers.sh`)**: um único arquivo declara as seis camadas da arquitetura (§22) no formato `<repo>|<workflow>|<supports_action>` e concentra as funções de disparo em paralelo e espera por conclusão (`gh run list` + `gh run watch --exit-status`). Cada repositório de infraestrutura Terraform aceita no `workflow_dispatch` do seu `cd.yml` o input `action` (`apply` por padrão ou `destroy`), preservando o comportamento de apenas aplicar em eventos `push` na `main`.
2. **Conferência da saúde da borda no script de subida e smoke test dos serviços tolerante à ausência inicial do Gateway**: na subida do zero, a camada dos microsserviços (Camada 3) executa antes da camada do API Gateway (Camada 4), conforme a ordem fixada na §22. Enquanto o API Gateway ainda não existe na conta, o passo de smoke test via Gateway nos CDs dos microsserviços é pulado com aviso (mantendo a verificação e o rollback pelo `kubectl rollout status` no cluster); logo após o provisionamento da Camada 4 (`oficina-mecanica-api-gateway`), o `environment-up.sh` consulta `GET /health/<contexto>` dos quatro serviços pelo `api_endpoint` público com retentativa a cada 15 segundos por até 10 minutos antes de liberar a camada das Lambdas.
3. **Monitoramento no Datadog pausado (`ENVIRONMENT_ONLINE=false`) na derrubada, em vez de destruído**: ao iniciar o `environment-down.sh`, o script altera a variável `ENVIRONMENT_ONLINE` para `false` no repositório `oficina-mecanica-custom-monitoring` e dispara seu CD (que aplica `status = "paused"` nos testes sintéticos, com monitores configurados com `notify_no_data = false`), sem executar `terraform destroy` nos recursos do Datadog. Ao final do `environment-up.sh`, o script define `ENVIRONMENT_ONLINE=true` e reaplica o CD do monitoramento.
4. **Derrubada na ordem inversa com retentativa no `infra-base` e auditoria final de sobras**: o `environment-down.sh` destrói Lambdas, API Gateway e a camada de plataforma (EKS, mensageria e bancos em paralelo), repete o `destroy` do `infra-base` a cada 5 minutos por até 30 minutos caso ENIs de VPC Link ou Lambdas ainda estejam sendo liberadas pela AWS, e ao final consulta a AWS CLI (`eks`, `ec2 describe-nat-gateways`, `rds`, `elasticache`, `apigatewayv2`, `lambda`, `sqs` e `sns`) falhando caso reste qualquer recurso do projeto (exceto o bucket S3 de state).

## Alternativas consideradas

### Orquestrar via workflow reutilizável no GitHub Actions (`workflow_call`) ou Terragrunt / monorepo (Decisão 1)

Criar um workflow "orquestrador" no GitHub Actions que invocasse os CDs dos demais repositórios via `workflow_call` (ou consolidar as stacks com Terragrunt/monorepo). Descartada porque o uso de workflows reutilizáveis entre repositórios foi explicitamente postergado (*Deferred*) na arquitetura e exigiria permissões cruzadas adicionais entre repositórios e tokens; já o uso de Terragrunt ou monorepo introduziria uma ferramenta extra e violaria a decisão arquitetural AD-15 de manter um repositório independente por componente com pipeline próprio.

### Inverter a ordem da §22 para subir o API Gateway antes dos microsserviços (Decisão 3)

Posicionar o `oficina-mecanica-api-gateway` antes da camada dos microsserviços para que o endereço público do Gateway já existisse durante o primeiro deploy de cada serviço. Descartada porque contraria a ordem arquitetural da §22 fixada pela AD-26 (em que a borda pública é exposta somente após os serviços estarem implantados no cluster) e porque o NLB interno e os alvos nos namespaces são estabilizados junto aos workloads; tornar o smoke test do CD do serviço tolerante à ausência inicial do Gateway e validar a borda no `environment-up.sh` logo após a Camada 4 resolve o problema sem alterar a topologia nem a ordem de provisionamento.

### Destruir os recursos do `oficina-mecanica-custom-monitoring` com `terraform destroy` ao fim de cada sessão (Decisão 6)

Executar `terraform destroy` também no repositório `oficina-mecanica-custom-monitoring` durante o `environment-down.sh`. Descartada porque os dashboards, monitores e testes sintéticos residem na organização do Datadog (fora da conta AWS do Learner Lab, sem consumir créditos AWS) e destruí-los a cada sessão alteraria os IDs e as URLs públicas dos dashboards e monitores a cada novo bootstrap. Pausar os testes sintéticos via `ENVIRONMENT_ONLINE=false` elimina alertas falsos e execuções desnecessárias fora de sessão mantendo URLs e histórico intactos.

## Consequências

### Positivas

- **Subida e derrubada com um único comando**: `./scripts/environment-up.sh` e `./scripts/environment-down.sh` coordenam os repositórios na ordem exata de dependências, executando em paralelo as stacks independentes de uma mesma camada.
- **Proteção do orçamento do AWS Academy (V8)**: a conferência final automatizada no `environment-down.sh` garante que nenhum recurso gerador de custo (EKS, NAT Gateway, RDS, ElastiCache, VPC Link, Lambda, SQS ou SNS) passe despercebido ao encerrar a sessão.
- **Preservação de dashboards e silêncio operacional fora de sessão**: o monitoramento permanece íntegro no Datadog e não dispara alertas falsos quando a infraestrutura AWS está desligada.
- **Execução idempotente sem controle de estado local**: em caso de falha parcial (como expiração do token de sessão do Lab), basta atualizar os secrets e reexecutar o mesmo script sem necessidade de parâmetros de retomada (`--from`).

### Negativas / Trade-offs

- **Dependência de sessão ativa no terminal do operador**: como a subida completa leva cerca de 25 a 35 minutos e a derrubada cerca de 15 a 25 minutos, o operador precisa manter o terminal conectado até o término do script (ou reexecutá-lo caso a conexão caia).
- **Manutenção da lista de repositórios em `scripts/environment-layers.sh`**: cada novo repositório criado nas entregas seguintes precisa adicionar sua entrada correspondente na camada apropriada de `scripts/environment-layers.sh`.

### Riscos aceitos

- **Expiração das credenciais de 4 horas do AWS Academy durante a execução**: não é possível renovar automaticamente as credenciais do Learner Lab sem intervenção humana no painel; o risco é mitigado conferindo e atualizando os secrets no início da sessão conforme o [Runbook](../runbook.md) e pela idempotência dos CDs na retomada.

## Referências

- [ADR 0001 — Escolha da nuvem e criação da infraestrutura de rede base](0001-escolha-de-nuvem-e-infra-base.md)
- [ADR 0003 — CI tolerante à indisponibilidade do ambiente AWS Academy](0003-ci-tolerante-a-indisponibilidade-do-lab.md)
- [Runbook da Sessão — Ambiente `prod-simulated`](../runbook.md)
- [Documentação de CI/CD](../ci-cd.md)
- `scripts/environment-layers.sh`, `scripts/environment-up.sh` e `scripts/environment-down.sh`
