# ADR 0001: Escolha da nuvem (AWS) e criação da infraestrutura de rede base

## Status

Aceito — 2026-09-07

## Contexto

O projeto Oficina Mecânica precisa hospedar sua API (`oficina-mecanica-app`), banco de dados (`oficina-mecanica-database`) e cluster Kubernetes (`oficina-mecanica-k8s`) em algum provedor de nuvem. Este repositório (`oficina-mecanica-infra-base`) é a camada mais baixa do IaC do projeto: a fundação de rede (VPC, subnets, gateways) sobre a qual todos os demais repositórios de infraestrutura se apoiam via `terraform_remote_state`.

A restrição decisiva do ambiente é o contexto acadêmico: o grupo tem acesso a contas **AWS Academy Learner Lab**, com um orçamento de crédito de laboratório limitado (na ordem de US$50) e sessões de lab com duração e reinícios periódicos. Isso implica duas limitações estruturais que moldam toda decisão de infraestrutura no projeto:

1. **Sem acesso ao IAM**: não é possível criar roles, policies ou usuários IAM — apenas usar roles pré-existentes fornecidas pelo laboratório (lidas via `data "aws_iam_role"`, nunca `resource`).
2. **Credenciais e roles rotativas**: a cada reinício do lab, credenciais e IDs de role mudam, exigindo que a IaC trate esses valores como variáveis injetadas externamente (via `TF_VAR_*` nos workflows), nunca hardcoded.

## Decisão

Adotar a **AWS (Amazon Web Services)** como provedor de nuvem único do projeto, e provisionar como infraestrutura de rede base:

- Uma **VPC** dedicada (`10.0.0.0/16`) com suporte a DNS interno.
- **2 subnets públicas** (`10.0.0.0/24`, `10.0.1.0/24`) em 2 zonas de disponibilidade de `us-east-1`, com IP público automático e tags para integração com Load Balancers públicos do Kubernetes (`kubernetes.io/role/elb`).
- **2 subnets privadas** (`10.0.10.0/24`, `10.0.11.0/24`) nas mesmas 2 AZs, com tags para ELBs internos (`kubernetes.io/role/internal-elb`), destinadas ao cluster EKS e ao RDS.
- Um **Internet Gateway** para saída/entrada pública e um único **NAT Gateway** (com Elastic IP, numa subnet pública) para dar saída à internet aos recursos das subnets privadas (necessário para os nós do EKS puxarem imagens de container e para o RDS aplicar patches).
- Tabelas de rotas públicas e privadas associadas às subnets correspondentes.

O estado do Terraform é mantido remotamente num bucket S3 (`bkt-oficina-mecanica`, chave `infra/prod-simulated/infra-base/terraform.tfstate`), com lock nativo do S3 (`use_lockfile = true`, Terraform ≥ 1.11) em vez de uma tabela DynamoDB de lock — os outputs (`vpc_id`, `vpc_cidr`, `public_subnet_ids`, `private_subnet_ids`) são consumidos por `oficina-mecanica-k8s` e `oficina-mecanica-database` via `data.terraform_remote_state`.

## Alternativas consideradas

### Multi-cloud ou outro provedor (GCP, Azure)

Descartada de imediato: o ambiente de laboratório disponibilizado pela disciplina (FIAP 15SOAT) é especificamente **AWS Academy**, sem crédito equivalente em outro provedor. Não havia alternativa real disponível para o grupo.

### Uma única VPC/subnet, sem separação pública/privada

Simplificaria a topologia de rede, com uma subnet só. Descartada porque o EKS e o RDS precisam ficar em subnets **privadas** (sem IP público, acessados apenas via rede interna ou por um Load Balancer na camada pública) por segurança — expor os nós do cluster ou o banco diretamente à internet pública seria uma prática insegura sem necessidade, já que o tráfego de entrada da aplicação é mediado por um Load Balancer (subnet pública) e o de saída pelos nós, pelo NAT Gateway.

### NAT Gateway por AZ (um por subnet privada, redundante)

Padrão recomendado para produção real: um NAT Gateway por zona de disponibilidade evita que a queda de uma AZ derrube a saída de internet das outras. Descartado por custo: cada NAT Gateway tem uma cobrança horária fixa própria, e um único NAT Gateway compartilhado entre as duas subnets privadas já é, isoladamente, um dos maiores consumidores do crédito de laboratório disponível — dobrá-lo não cabia no orçamento.

### VPC Endpoints (Gateway/Interface) para serviços AWS (S3, ECR, etc.)

Reduziria a dependência do NAT Gateway para tráfego destinado a serviços AWS (ex.: pull de imagens do ECR passaria pela rede AWS interna, não pelo NAT). Descartado por custo: VPC Endpoints de interface têm cobrança por hora e por AZ; para o volume de tráfego deste laboratório, o NAT Gateway único já cobre a necessidade funcional a um custo menor.

### Criar roles/policies IAM próprias via Terraform

Seria o padrão usual em um projeto AWS real, dando controle total sobre permissões. Descartado porque a conta AWS Academy **bloqueia** a criação de recursos IAM — só é possível ler (`data`) roles já provisionadas pelo laboratório. Essa não é uma escolha de design, mas uma restrição da plataforma.

## Consequências

### Positivas

- **Fundação de rede reutilizável**: os repositórios `oficina-mecanica-k8s` e `oficina-mecanica-database` consomem esta VPC via remote state, sem duplicar definição de rede — uma única fonte de verdade para CIDRs e subnets.
- **Isolamento por camada**: recursos que não precisam de exposição pública (EKS nodes, RDS) ficam em subnets privadas, reduzindo superfície de ataque.
- **Custo controlado**: um único NAT Gateway e ausência de VPC Endpoints mantêm o consumo de crédito de laboratório dentro do orçamento disponível para toda a duração do projeto.
- **Terraform como fonte única de verdade da rede**, com histórico de mudanças versionado e revisável via PR (CI valida `fmt`, `validate` e `plan` antes de qualquer aplicação).

### Negativas / Trade-offs

- **Ponto único de falha no NAT Gateway**: se a AZ onde o NAT Gateway está implantado cair, todas as subnets privadas (de ambas as AZs) perdem saída à internet simultaneamente — o padrão multi-AZ recomendado para produção real foi descartado por custo.
- **Sem VPC Endpoints**: todo tráfego para serviços AWS (ECR, S3, etc.) originado nas subnets privadas passa pelo NAT Gateway, consumindo sua capacidade e gerando custo de processamento de dados que um VPC Endpoint evitaria.
- **Acoplamento entre contas de laboratório e infraestrutura**: a necessidade de reinjetar IDs de role IAM a cada reinício do lab (via `TF_VAR_*` nos secrets/variables do GitHub) é um processo manual que não existiria numa conta AWS "real" com IAM sob controle total do time.

### Riscos mitigados

- **Exposição pública desnecessária de EKS e RDS**: mitigada pela separação em subnets privadas, com Load Balancer na subnet pública como único ponto de entrada mediado.
- **Perda de estado do Terraform ou aplicação concorrente conflitante**: mitigada pelo backend S3 remoto com lock nativo (`use_lockfile`), garantindo que aplicações concorrentes (ex.: dois membros do time rodando `terraform apply` ao mesmo tempo) sejam serializadas em vez de corromper o state.

## Referências

- [`oficina-mecanica-k8s` — README (consumo do remote state desta VPC)](https://github.com/FIAP-15SOAT/oficina-mecanica-k8s)
- [`oficina-mecanica-database` — README e ADR 0001 (consumo desta VPC pelo RDS)](https://github.com/FIAP-15SOAT/oficina-mecanica-database)
- [`oficina-mecanica-app` › ADR 0005 — Escolha de nuvem AWS (contexto do laboratório Academy, orçamento e limitações de IAM)](https://github.com/FIAP-15SOAT/oficina-mecanica-app/blob/master/docs/adr/0005-escolha-de-nuvem-aws.md)
- `terraform/networking.tf`, `terraform/variables.tf`, `terraform/outputs.tf` — configuração corrente da rede.
