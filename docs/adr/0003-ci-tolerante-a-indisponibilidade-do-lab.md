# ADR 0003: CI tolerante à indisponibilidade do ambiente AWS Academy

## Status

Aceito — 2026-09-07

## Contexto

A conta AWS Academy Learner Lab não fica disponível 24/7 — a sessão de laboratório expira e as credenciais temporárias (`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`AWS_SESSION_TOKEN`) ficam inválidas até alguém reiniciar a sessão manualmente. Um push numa branch `feature/**`/`fix/**` pode acontecer a qualquer momento, inclusive quando ninguém reiniciou o laboratório — e o workflow de CI (`ci.yml`) precisa decidir o que fazer quando as credenciais AWS simplesmente não funcionam nesse momento.

## Decisão

Estruturar o job `tf-validate` do CI para **nunca falhar por causa da indisponibilidade do ambiente**, separando o que pode ser validado sem credenciais AWS do que depende delas:

1. `terraform fmt -check`, `terraform init -backend=false` e `terraform validate` rodam sempre — não dependem de credenciais AWS válidas.
2. O passo `Configure AWS Credentials` roda com `continue-on-error: true`, registrando o resultado em `steps.aws_creds.outcome`.
3. `terraform plan` só roda **se** as credenciais funcionaram (`if: steps.aws_creds.outcome == 'success'`).
4. Se as credenciais falharem, um passo dedicado escreve um aviso no job summary do GitHub Actions ("Terraform plan — skipped ⏭️ (...) Isso não bloqueia o CI") em vez de deixar o workflow simplesmente vermelho sem explicação.

## Alternativas consideradas

### CI falha se as credenciais AWS não funcionarem

Seria o comportamento padrão de qualquer pipeline Terraform contra uma conta sempre disponível. Descartado porque, neste ambiente específico, uma falha de credenciais **não indica um erro no código** — indica que o laboratório está fora do ar, uma condição normal e recorrente, fora do controle de quem abriu o PR. Bloquear o CI nessa situação obrigaria reiniciar o laboratório só para conseguir validar `fmt`/`validate`, que já teriam passado de qualquer forma.

### Não rodar `terraform plan` nunca no CI, só no CD

Evitaria por completo a necessidade de lidar com credenciais instáveis no CI. Descartado porque o `plan` é o mecanismo de revisão mais importante de um PR de infraestrutura — ver o preview do que vai mudar antes do merge é o ponto central de um PR de Terraform; removê-lo do CI eliminaria a revisão prévia, empurrando a primeira visibilidade real das mudanças para o momento do `apply` no CD.

### Um step de retry com espera fixa antes de desistir

Tentaria mitigar indisponibilidades momentâneas com novas tentativas. Descartado porque a indisponibilidade aqui não é transitória (alguns segundos) — é a sessão de laboratório inteira estar fora até alguém reiniciá-la manualmente, o que pode levar minutos ou horas; um retry com espera curta não resolveria isso, só atrasaria o feedback do CI sem necessidade.

## Consequências

### Positivas

- **CI nunca fica vermelho por um motivo fora do controle do autor do PR**: uma sessão de laboratório expirada não é tratada como falha de código.
- **Ainda valida o que é possível sem credenciais** (`fmt`, `validate`), então um erro de sintaxe ou de referência continua sendo pego imediatamente, independente do estado do laboratório.
- **Comunicação explícita no job summary**: quem revisa o PR entende imediatamente por que o `plan` não rodou, em vez de precisar investigar logs.

### Negativas / Trade-offs

- **Um PR pode ser aprovado e mergeado sem nunca ter visto um `terraform plan` real**, se o laboratório esteve fora do ar durante toda a janela de revisão — a validação de sintaxe passa, mas o preview do que realmente mudaria na infraestrutura fica ausente até o CD rodar de fato.
- **Depende de disciplina humana para re-rodar o CI** quando o laboratório voltar, já que o skip não é automaticamente revisitado — fica a cargo de quem está revisando notar o aviso e pedir um re-run.

### Riscos mitigados

- **CI bloqueando desenvolvimento por uma condição de ambiente que ninguém pode controlar no momento do PR**: mitigado por nunca falhar o job por esse motivo, mantendo o restante da validação estática ativa.

## Referências

- [ADR 0001 — Escolha da nuvem e criação da infraestrutura de rede base](0001-escolha-de-nuvem-e-infra-base.md) — contexto do orçamento e das sessões de laboratório AWS Academy.
- `.github/workflows/ci.yml` — implementação do `continue-on-error` e do aviso condicional no job summary.
