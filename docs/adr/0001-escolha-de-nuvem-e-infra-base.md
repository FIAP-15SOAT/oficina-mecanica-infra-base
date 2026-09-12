# ADR 0001: Escolha da nuvem (AWS) e criação da infraestrutura de rede base

## Status

Aceito — 2026-09-07

## Contexto

O projeto Oficina Mecânica precisa hospedar sua API (`oficina-mecanica-api`), banco de dados (`oficina-mecanica-infra-database`) e cluster Kubernetes (`oficina-mecanica-infra-k8s`) em algum provedor de nuvem. Este repositório (`oficina-mecanica-infra-base`) é a camada mais baixa do IaC do projeto: a fundação de rede (VPC, subnets, gateways) sobre a qual todos os demais repositórios de infraestrutura se apoiam via `terraform_remote_state`.

A restrição decisiva do ambiente é o contexto acadêmico: o grupo tem acesso a contas **AWS Academy Learner Lab**, com um orçamento de crédito de laboratório limitado (na ordem de US$50) e sessões de lab com duração e reinícios periódicos. Isso implica duas limitações estruturais que moldam toda decisão de infraestrutura no projeto:

1. **Sem acesso ao IAM**: não é possível criar roles, policies ou usuários IAM — apenas usar roles pré-existentes fornecidas pelo laboratório (lidas via `data "aws_iam_role"`, nunca `resource`).
2. **Sessões temporárias e roles da conta**: as credenciais de sessão expiram; os nomes das roles existentes devem ser conferidos quando a conta de laboratório mudar. Isso exige que os consumidores de IAM recebam esses nomes por variáveis injetadas externamente (`TF_VAR_*` nos workflows). Esta stack de rede não consome nem cria roles.

## Decisão

Adotar a **AWS (Amazon Web Services)** como provedor de nuvem único do projeto, e provisionar como infraestrutura de rede base:

- Uma **VPC** dedicada (`10.0.0.0/16`) com suporte a DNS interno.
- **2 subnets públicas** (`10.0.0.0/24`, `10.0.1.0/24`) em 2 zonas de disponibilidade de `us-east-1`, com IP público automático e tags para integração com Load Balancers públicos do Kubernetes (`kubernetes.io/role/elb`).
- **2 subnets privadas** (`10.0.10.0/24`, `10.0.11.0/24`) nas mesmas 2 AZs, com tags para ELBs internos (`kubernetes.io/role/internal-elb`), destinadas ao cluster EKS e ao RDS.
- Um **Internet Gateway** para conectividade pública e um único **NAT Gateway** (com Elastic IP, na primeira subnet pública) para saída dos recursos privados.
- Tabelas de rotas públicas e privadas associadas às subnets correspondentes.

O estado do Terraform é mantido remotamente no bucket S3 externo `bkt-oficina-mecanica`, chave `infra/prod-simulated/infra-base/terraform.tfstate`, com criptografia e lock nativo (`use_lockfile = true`, Terraform ≥ 1.11). O módulo não cria o bucket nem tabela DynamoDB. Os outputs `vpc_id`, `vpc_cidr`, `public_subnet_ids` e `private_subnet_ids` são consumidos, conforme a necessidade de cada stack, por Kubernetes, database, API Gateway e Lambda via `terraform_remote_state`. Os locals usam somente os primeiros dois CIDRs de cada lista.

## Alternativas consideradas

### Multi-cloud ou outro provedor (GCP, Azure)

Descartada de imediato: o ambiente de laboratório disponibilizado pela disciplina (FIAP 15SOAT) é especificamente **AWS Academy**, sem crédito equivalente em outro provedor. Não havia alternativa real disponível para o grupo.

### Uma única VPC/subnet, sem separação pública/privada

Simplificaria a topologia de rede, com uma subnet só. Descartada para separar recursos privados e conectividade pública. Os nodes EKS, RDS, NLB e VPC Link usam subnets privadas; o control plane EKS associa subnets públicas e privadas e mantém endpoints público e privado. A entrada da aplicação é HTTP API Gateway → VPC Link → NLB interno, sem um Load Balancer público nesta solução. A saída dos workloads privados usa o NAT.

### NAT Gateway por AZ (um por subnet privada, redundante)

Padrão recomendado para produção real: um NAT Gateway por zona de disponibilidade evita que a queda de uma AZ derrube a saída de internet das outras. Descartado por custo: cada NAT Gateway tem uma cobrança horária fixa própria, e um único NAT Gateway compartilhado entre as duas subnets privadas já é, isoladamente, um dos maiores consumidores do crédito de laboratório disponível — dobrá-lo não cabia no orçamento.

### VPC Endpoints (Gateway/Interface) para serviços AWS (S3, ECR, etc.)

Reduziria a dependência do NAT Gateway para tráfego destinado a serviços AWS (ex.: pull de imagens do ECR passaria pela rede AWS interna, não pelo NAT). Descartado por custo: VPC Endpoints de interface têm cobrança por hora e por AZ; para o volume de tráfego deste laboratório, o NAT Gateway único já cobre a necessidade funcional a um custo menor.

### Criar roles/policies IAM próprias via Terraform

Seria o padrão usual em um projeto AWS real, dando controle total sobre permissões. Descartado porque a conta AWS Academy **bloqueia** a criação de recursos IAM — só é possível ler (`data`) roles já provisionadas pelo laboratório. Essa não é uma escolha de design, mas uma restrição da plataforma.

## Consequências

### Positivas

- **Fundação de rede reutilizável**: Kubernetes, database, API Gateway e Lambda consomem esta VPC via remote state, sem duplicar definição de rede.
- **Isolamento por camada**: recursos que não precisam de exposição pública (EKS nodes, RDS) ficam em subnets privadas, reduzindo superfície de ataque.
- **Custo controlado**: um único NAT Gateway e ausência de VPC Endpoints mantêm o consumo de crédito de laboratório dentro do orçamento disponível para toda a duração do projeto.
- **Terraform como fonte da rede**, com histórico revisável via PR: CI executa fmt/validate sempre e plan quando a configuração de credenciais AWS tem sucesso. O skip do plan não equivale a uma prévia validada.

### Negativas / Trade-offs

- **Ponto único de falha no NAT Gateway**: se a AZ onde o NAT Gateway está implantado cair, todas as subnets privadas (de ambas as AZs) perdem saída à internet simultaneamente — o padrão multi-AZ recomendado para produção real foi descartado por custo.
- **Sem VPC Endpoints**: todo tráfego para serviços AWS (ECR, S3, etc.) originado nas subnets privadas passa pelo NAT Gateway, consumindo sua capacidade e gerando custo de processamento de dados que um VPC Endpoint evitaria.
- **Dependência da conta de laboratório**: renovar credenciais temporárias e conferir as roles dos consumidores ao mudar de conta é uma operação manual; infra-base não possui inputs de role IAM.

### Riscos mitigados

- **Exposição dos workloads e banco**: nodes, RDS e NLB usam subnets privadas. A entrada de negócio é mediada pelo HTTP API Gateway; o endpoint público de administração do EKS tem contrato de segurança próprio no repositório Kubernetes.
- **Perda de estado do Terraform ou aplicação concorrente conflitante**: mitigada pelo backend S3 remoto com lock nativo (`use_lockfile`), garantindo que aplicações concorrentes (ex.: dois membros do time rodando `terraform apply` ao mesmo tempo) sejam serializadas em vez de corromper o state.

## Referências

- [`oficina-mecanica-infra-k8s` — README (consumo do remote state desta VPC)](https://github.com/FIAP-15SOAT/oficina-mecanica-infra-k8s)
- [`oficina-mecanica-infra-database` — README e ADR 0001 (consumo desta VPC pelo RDS)](https://github.com/FIAP-15SOAT/oficina-mecanica-infra-database)
- [`oficina-mecanica-api` — Visão de infraestrutura](https://github.com/FIAP-15SOAT/oficina-mecanica-api/blob/main/docs/infra/overview.md)
- `terraform/networking.tf`, `terraform/variables.tf`, `terraform/outputs.tf` — configuração corrente da rede.
