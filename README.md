<div align="center">

# ☁️ Oficina Mecânica — Infraestrutura Base AWS (IaC)

**Provisionamento automatizado da fundação de rede e infraestrutura na AWS com Terraform para a solução Oficina Mecânica.**

![Terraform](https://img.shields.io/badge/Terraform-%3E%3D1.11.0-844FBA?logo=terraform&logoColor=white)
![AWS](https://img.shields.io/badge/AWS-Cloud-FF9900?logo=amazon-aws&logoColor=white)
![VPC](https://img.shields.io/badge/AWS-VPC-FF9900?logo=amazon-aws&logoColor=white)

</div>

## 📋 Sobre

Este repositório contém o código de **Infraestrutura como Código (IaC)** responsável pelo provisionamento da fundação de rede em nuvem na AWS para a aplicação **Oficina Mecânica**, bem como os **scripts de ciclo de vida do ambiente** (`scripts/environment-up.sh` e `scripts/environment-down.sh`) e o [Runbook da Sessão](docs/runbook.md) que orquestram a subida e a derrubada completa de todas as camadas da solução no AWS Academy Learner Lab.

Faz parte do ecossistema de serviços e infraestrutura da pós-graduação em Arquitetura de Software da FIAP (turma 15SOAT).

A [API](https://github.com/FIAP-15SOAT/oficina-mecanica-work-order-service) é a entrada central da documentação da solução.

---

### 🏗️ Recursos Provisionados

1. **Rede e Conectividade (`networking.tf`)**:
   - **VPC** dedicada com bloco CIDR padrão `10.0.0.0/16`, com suporte a DNS interno habilitado (`enable_dns_support` e `enable_dns_hostnames`).
   - **Subnets Públicas**: `10.0.0.0/24` e `10.0.1.0/24`, com `map_public_ip_on_launch = true` e tags para integração com ELBs públicos (`kubernetes.io/role/elb = 1`). Cada subnet fica em uma das primeiras duas AZs disponíveis na região configurada; os nomes das AZs não são fixos.
   - **Subnets Privadas**: `10.0.10.0/24` e `10.0.11.0/24`, nas mesmas duas AZs, sem atribuição automática de IP público e com tags para ELBs internos (`kubernetes.io/role/internal-elb = 1`). Os dois conjuntos também recebem a tag compartilhada do cluster `eks-oficina-mecanica`.
   - **Internet Gateway (IGW)** para a saída das subnets públicas e **um NAT Gateway**, com Elastic IP na primeira subnet pública, para a saída à internet das duas subnets privadas. A criação do NAT depende do IGW.
   - **Tabelas de roteamento**: uma pública, com rota `0.0.0.0/0` para o IGW, e uma privada, com rota `0.0.0.0/0` para o NAT. Cada tabela tem duas associações, uma por subnet do seu conjunto.
   - **Security Group de identidade dos nós do EKS (`secgrp-eks-nodes-oficina-mecanica`)**: grupo sem regras próprias de entrada ou saída, exportado via `eks_nodes_security_group_id` para ser anexado aos nós do EKS pelo Launch Template do `infra-k8s` e referenciado nas regras de entrada dos bancos de dados (RDS) e cache (ElastiCache) dos serviços (ver [ADR 0004](docs/adr/0004-security-group-de-identidade-dos-nos-do-eks.md)).

Os CIDRs são configuráveis. `locals.tf` seleciona apenas as primeiras duas AZs
e os primeiros dois CIDRs de cada lista; CIDRs adicionais não criam outras
subnets. O provider aplica as tags `Project`, `ManagedBy` e `Environment`.
As tags Kubernetes identificam as subnets para integração, mas não criam
balanceadores por si mesmas.

Esta stack provisiona a rede compartilhada e o Security Group de identidade dos
nós do EKS. EKS, RDS, ElastiCache, Lambda, API Gateway e os Security Groups com
regras de porta pertencem aos repositórios consumidores. O NLB da API é
**interno**, nas subnets privadas, e é provisionado pela infraestrutura
Kubernetes. Bucket de state, roles IAM, NACLs customizadas, Flow Logs e VPC
Endpoints não são criados por este módulo.

![Arquitetura da infraestrutura base](docs/diagrams/infrastructure.png)

---

## 📁 Estrutura do Repositório

```text
.
├── .github/
│   └── workflows/
│       ├── cd.yml  # Apply na main ou apply/destroy via workflow_dispatch (input action)
│       └── ci.yml  # Valida Terraform e abre PR; plan condicionado a credenciais
├── docs/
│   ├── adr/
│   │   ├── 0001-escolha-de-nuvem-e-infra-base.md
│   │   ├── 0002-postura-de-rede-apenas-security-groups.md
│   │   ├── 0003-ci-tolerante-a-indisponibilidade-do-lab.md
│   │   ├── 0004-security-group-de-identidade-dos-nos-do-eks.md
│   │   └── 0005-ciclo-de-vida-do-ambiente-por-script.md
│   ├── diagrams/
│   │   ├── cd-workflow.png  # Job e steps do workflow de CD
│   │   ├── ci-workflow.png  # Jobs e steps do workflow de CI
│   │   ├── environment-lifecycle.png  # Camadas de subida e derrubada do ambiente
│   │   └── infrastructure.png  # Arquitetura do componente
│   ├── ci-cd.md  # Jobs, steps, conditions e diagramas de CI/CD
│   └── runbook.md  # Runbook operacional da sessão no AWS Academy (subida, derrubada e passos manuais)
├── scripts/
│   ├── environment-down.sh  # Derruba o ambiente na ordem inversa e audita sobras na conta AWS
│   ├── environment-layers.sh  # Tabela declarativa das camadas e funções de disparo/espera via gh
│   └── environment-up.sh  # Sobe todas as camadas na ordem de dependências e valida /health/<contexto>
├── terraform/
│   ├── .terraform.lock.hcl  # Versões e checksums dos providers
│   ├── backend.tf  # Backend S3 e lock nativo
│   ├── locals.tf  # Seleção/convenções locais de recursos
│   ├── networking.tf  # VPC, AZs, subnets, IGW, NAT, rotas, associações e SG de identidade dos nós
│   ├── outputs.tf  # Outputs de integração
│   ├── providers.tf  # Providers e leitura de remote state quando aplicável
│   ├── terraform.tfvars  # Configuração estável da stack
│   ├── terraform.tfvars.example  # Referência para configurar o ambiente
│   └── variables.tf  # Variáveis de entrada
├── .gitignore  # Arquivos locais ignorados
└── README.md  # Entrada do componente e guia local
```

---

## 💾 Estado Remoto (Remote State)

O estado do Terraform é armazenado remotamente em um bucket S3 com criptografia
em repouso e suporte ao **lock nativo do S3** (`use_lockfile = true`):

- **Bucket**: o valor da variável de Actions da organização `TF_STATE_BUCKET`
- **Chave (Key)**: `infra/prod-simulated/infra-base/terraform.tfstate`
- **Região**: `us-east-1`

O bucket deve existir previamente. O nome fica em variável para que possa ser
trocado sem editar arquivo versionado: o `backend.tf` não declara o bucket, e os
workflows passam `-backend-config="bucket=$TF_STATE_BUCKET"` no `terraform init`. A identidade AWS precisa ler/gravar o state e
criar/remover o lockfile. A key é um identificador estável, compartilhado com os
consumidores; não é renomeada junto dos repositórios.

Os outputs são consumidos diretamente via `data.terraform_remote_state`:

| Consumidor | Uso |
| --- | --- |
| [Infraestrutura Kubernetes](https://github.com/FIAP-15SOAT/oficina-mecanica-infra-k8s) | VPC/CIDR, subnets privadas para nodes/NLB, subnets públicas + privadas associadas ao EKS e `eks_nodes_security_group_id` no Launch Template dos nós |
| [Infraestrutura de database (Work Order)](https://github.com/FIAP-15SOAT/oficina-mecanica-infra-database-work-order) | VPC, subnets privadas e `eks_nodes_security_group_id` para o RDS PostgreSQL e ElastiCache Valkey |
| [Infraestrutura de database (Identity)](https://github.com/FIAP-15SOAT/oficina-mecanica-infra-database-identity) | VPC, subnets privadas e `eks_nodes_security_group_id` para o RDS PostgreSQL |
| [Infraestrutura de database (Billing)](https://github.com/FIAP-15SOAT/oficina-mecanica-infra-database-billing) | VPC, subnets privadas e `eks_nodes_security_group_id` para o RDS PostgreSQL |
| [Infraestrutura de database (Inventory)](https://github.com/FIAP-15SOAT/oficina-mecanica-infra-database-inventory) | VPC, subnets privadas e `eks_nodes_security_group_id` para o RDS PostgreSQL |
| [API Gateway](https://github.com/FIAP-15SOAT/oficina-mecanica-api-gateway) | VPC/CIDR e subnets privadas para o VPC Link |
| [Lambda de autenticação (Customer)](https://github.com/FIAP-15SOAT/oficina-mecanica-lambda-customer-auth) | VPC e subnets privadas para a função |
| [Lambda de autenticação (Staff)](https://github.com/FIAP-15SOAT/oficina-mecanica-lambda-staff-auth) | VPC e subnets privadas para a função |

O monitoramento consome o state do Gateway, sem leitura direta deste state.

---

## ⚙️ Variáveis e Saídas

### Principais Variáveis de Entrada

| Variável | Tipo | Default | Descrição | Uso |
| --- | --- | --- | --- | --- |
| `aws_region` | `string` | `us-east-1` | Região da AWS | Região dos recursos |
| `project_name` | `string` | `oficina-mecanica` | Prefixo usado para nomes de recursos e tags | Compõe nomes e tags |
| `environment` | `string` | `prod-simulated` | Ambiente de implantação | Tag Environment |
| `vpc_cidr` | `string` | `10.0.0.0/16` | Bloco CIDR da VPC | CIDR da VPC |
| `public_subnet_cidrs` | `list(string)` | `["10.0.0.0/24", "10.0.1.0/24"]` | CIDRs das subnets públicas (mínimo 2) | Ao menos dois CIDRs; somente os primeiros dois são usados |
| `private_subnet_cidrs` | `list(string)` | `["10.0.10.0/24", "10.0.11.0/24"]` | CIDRs das subnets privadas (mínimo 2) | Ao menos dois CIDRs; somente os primeiros dois são usados |

---

### Saídas Exportadas (Outputs)

| Output | Descrição | Uso |
| --- | --- | --- |
| `vpc_id` | ID da VPC criada | VPC para SGs e integrações dos consumidores |
| `vpc_cidr` | Bloco CIDR da VPC | CIDR usado nas regras de acesso |
| `private_subnet_ids` | IDs das subnets privadas | Subnets de nodes EKS, RDS, ElastiCache, VPC Link e Lambdas |
| `public_subnet_ids` | IDs das subnets públicas | Subnets também associadas ao control plane EKS |
| `eks_nodes_security_group_id` | ID do Security Group de identidade dos nós do EKS (`secgrp-eks-nodes-oficina-mecanica`) | Anexado aos nós pelo Launch Template do `infra-k8s` e autorizado nos Security Groups de RDS e ElastiCache dos serviços |

---

## 🚀 Como Executar Localmente

### Pré-requisitos

- **Terraform ≥ 1.11.0**.
- **AWS provider ≥ 6.46.0 e < 7.0.0**; as versões/checksums instalados ficam em `terraform/.terraform.lock.hcl`.
- **AWS CLI v2** configurada com as três credenciais temporárias do AWS Academy: access key, secret key e session token (`aws configure`).
- Acesso ao bucket de state S3 (o valor de `TF_STATE_BUCKET`) e permissões para os recursos de rede.
- Valores de `terraform.tfvars` revisados; a referência é `terraform.tfvars.example`. Não substitua um arquivo existente sem revisar seus valores.

### Passo a Passo

```bash
# 1. Clonar o repositório
git clone https://github.com/FIAP-15SOAT/oficina-mecanica-infra-base.git

# 2. Entrar no diretório que contém a configuração Terraform
cd oficina-mecanica-infra-base/terraform

# 3. Inicializar os providers e o backend S3, informando o bucket de state
export TF_STATE_BUCKET=<nome do bucket>
terraform init -backend-config="bucket=$TF_STATE_BUCKET"

# 4. Verificar a formatação sem modificar arquivos
terraform fmt -check -recursive

# 5. Validar a sintaxe e a consistência da configuração
terraform validate

# 6. Visualizar o plano de execução, incluindo as consultas AWS necessárias
terraform plan

# 7. Aplicar o provisionamento após revisar o plano exibido
terraform apply

# 8. Consultar os outputs para integrar os repositórios consumidores
terraform output
```

### Validação estática, sem sessão AWS ativa

Na pasta `terraform/`, é possível verificar a configuração sem inicializar o
backend ou consultar recursos AWS:

```bash
# Verificar a formatação da configuração e de seus subdiretórios
terraform fmt -check -recursive

# Instalar os providers sem conectar ao backend remoto
terraform init -backend=false

# Validar a configuração usando os schemas dos providers instalados
terraform validate
```

A instalação exige acesso ao registry ou a um cache local. Quando já houver
lockfile e for necessário preservar suas versões/checksums, acrescente
`-lockfile=readonly` ao `init`. Antes de um plan remoto após essa inicialização,
use `terraform init -reconfigure -backend-config="bucket=$TF_STATE_BUCKET"` para configurar o backend. `validate` não
comprova permissões AWS nem o resultado de um plan.

### Ordem de provisionamento e encerramento do laboratório

A subida e a derrubada completa do ambiente `prod-simulated` através dos repositórios da organização `FIAP-15SOAT` são automatizadas pelos scripts em `scripts/` (ver [ADR 0005](docs/adr/0005-ciclo-de-vida-do-ambiente-por-script.md) e o [Runbook da Sessão](docs/runbook.md)):

```bash
# 1. Atualizar os secrets da organização com as credenciais temporárias da sessão ativa do AWS Academy
gh secret set AWS_ACCESS_KEY_ID --org FIAP-15SOAT --body "$AWS_ACCESS_KEY_ID"
gh secret set AWS_SECRET_ACCESS_KEY --org FIAP-15SOAT --body "$AWS_SECRET_ACCESS_KEY"
gh secret set AWS_SESSION_TOKEN --org FIAP-15SOAT --body "$AWS_SESSION_TOKEN"

# 2. Subir todas as camadas do ambiente na ordem de dependências (cria o bucket de state se necessário, dispara os CDs por camada, confere GET /health/<contexto> no Gateway e ativa o monitoramento)
./scripts/environment-up.sh

# 3. Ao final da sessão, pausar o monitoramento, destruir todas as camadas na ordem inversa e auditar que não restaram recursos cobrando na conta AWS
./scripts/environment-down.sh
```

O script `scripts/environment-up.sh` cria automaticamente o bucket S3 de state (`TF_STATE_BUCKET`) com versionamento caso ele ainda não exista na conta, sobe sequencialmente a rede base (`infra-base`), a camada de plataforma em paralelo (`infra-k8s`, `infra-messaging` e os 4 repositórios `infra-database*`), os microsserviços, o `api-gateway` (seguido da verificação pública de `/health/work-order`, `/health/identity`, `/health/billing` e `/health/inventory`), as funções Lambda e a ativação do `custom-monitoring` (`ENVIRONMENT_ONLINE=true`).

O script `scripts/environment-down.sh` pausa os testes sintéticos no Datadog (`ENVIRONMENT_ONLINE=false`), destrói na ordem inversa (Lambdas → API Gateway → plataforma em paralelo → `infra-base` com retentativa automática enquanto ENIs são liberadas) e executa uma conferência final via AWS CLI para garantir que nenhum recurso cobrável permaneça ativo ao encerrar o laboratório. O bucket S3 de state é preservado entre sessões.

Consulte o [Runbook da Sessão](docs/runbook.md) para o procedimento detalhado de conferência de créditos do Lab (V8), configuração do webhook do Mercado Pago, limpeza de cache no ElastiCache for Valkey e resolução de falhas conhecidas.

---

## 🔄 Pipelines de CI/CD

O repositório conta com dois workflows automatizados via GitHub Actions:

- **CI**: push em `feature/**` e `fix/**`; valida Terraform, faz plan quando a autenticação AWS está disponível e abre PR para `main` com GitHub App.
- **CD**: push em `main` ou `workflow_dispatch` (com input `action`: `apply` por padrão ou `destroy`); executa plan/apply ou destroy sob `production`, com gate por `main` e `ENABLE_DEPLOY` ou disparo manual. Não há dependência `needs` entre os dois workflows.

A [documentação de CI/CD](docs/ci-cd.md) explica cada job/step, conditions, autenticação, configuração GitHub e falhas, e **renderiza os diagramas de CI e CD**. O [Runbook da Sessão](docs/runbook.md) documenta a operação completa do ambiente com os scripts de ciclo de vida.

---

## 📐 Decisões Arquiteturais

- [ADR 0001 — Escolha da nuvem (AWS) e criação da infraestrutura de rede base](docs/adr/0001-escolha-de-nuvem-e-infra-base.md)
- [ADR 0002 — Controle de tráfego só por Security Groups, sem NACLs nem VPC Flow Logs](docs/adr/0002-postura-de-rede-apenas-security-groups.md)
- [ADR 0003 — CI tolerante à indisponibilidade do ambiente AWS Academy](docs/adr/0003-ci-tolerante-a-indisponibilidade-do-lab.md)
- [ADR 0004 — Security group de identidade dos nós do EKS](docs/adr/0004-security-group-de-identidade-dos-nos-do-eks.md)
- [ADR 0005 — Ciclo de vida do ambiente por script](docs/adr/0005-ciclo-de-vida-do-ambiente-por-script.md)

## 👥 Autores

- [Guilherme da Rocha Salvador](https://github.com/guilhermesalvador404)
- [Lucas Almeida da Silva](https://github.com/lucas-almeida-silva)
- [Ramoon Lincoln Barros Camacho](https://github.com/ramooncamacho)
- [Renan Santana Camacho](https://github.com/renancamacho)

## 📄 Licença

Projeto acadêmico (FIAP — 15SOAT), para fins educacionais. Sem licença aberta declarada (`UNLICENSED`).

