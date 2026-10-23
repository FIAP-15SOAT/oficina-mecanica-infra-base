# ADR 0004: Security group de identidade dos nós do EKS

## Status

Aceito — 2026-10-23

## Contexto

Na Fase 4, a solução evolui para quatro microsserviços rodando no cluster EKS (`work-order`, `identity`, `billing` e `inventory`), cada um com seu próprio repositório de banco de dados relacional RDS PostgreSQL (e ElastiCache Redis no caso de `work-order`). Para cumprir o princípio de menor privilégio na rede (ADR 0002), os bancos de dados e caches devem aceitar conexões nas portas `5432` e `6379` apenas a partir dos nós de trabalho do EKS — e não de qualquer interface de rede nas subnets privadas.

 Ao mesmo tempo, na ordem de provisionamento da arquitetura (§22), os repositórios de dados (`infra-database`, `infra-database-identity`, `infra-database-billing`, `infra-database-inventory`) e o repositório do cluster (`infra-k8s`) compõem a camada de plataforma que sobe imediatamente após a rede base (`infra-base`), em paralelo entre si. Se os repositórios de dados dependessem do remote state do `infra-k8s` para obter o Security Group do cluster EKS, perderiam a capacidade de subir em paralelo com o cluster (que leva cerca de 12 a 15 minutos para ser provisionado).

## Decisão

Provisionar no `oficina-mecanica-infra-base` (`terraform/networking.tf`) um Security Group dedicado exclusivamente à **identidade dos nós do EKS** (`secgrp-eks-nodes-oficina-mecanica`), **sem regras próprias de entrada ou saída**, e exportar seu identificador no output `eks_nodes_security_group_id`:

1. O `oficina-mecanica-infra-k8s` lê `eks_nodes_security_group_id` via `data.terraform_remote_state` do `infra-base` e anexa esse Security Group (junto ao Security Group gerenciado do cluster EKS) no Launch Template do Node Group. Como o VPC CNI do EKS atribui IPs secundários das ENIs do nó aos pods, todo tráfego originado pelos pods carrega esse Security Group.
2. Os repositórios de dados (`infra-database`, `infra-database-identity`, `infra-database-billing` e `infra-database-inventory`) leem `eks_nodes_security_group_id` diretamente do state do `infra-base` e autorizam entrada em `5432/tcp` (e `6379/tcp` no Redis) tendo esse Security Group como `referenced_security_group_id`.

## Alternativas consideradas

### Ler o Security Group do cluster pelo remote state do `infra-k8s`

Os repositórios de dados consumiriam `data.terraform_remote_state.infra_k8s` para referenciar o Security Group gerenciado do cluster EKS (`cluster_security_group_id`). Descartada porque criaria uma dependência sequencial entre os quatro repositórios de banco de dados e o provisionamento do cluster EKS, impedindo que bancos e cluster subam em paralelo na camada pós-rede base e aumentando o tempo total de bootstrap da sessão do AWS Academy Learner Lab.

### Restringir o acesso aos bancos pelo CIDR das subnets privadas

Os Security Groups de RDS e ElastiCache liberariam entrada a partir dos blocos CIDR das subnets privadas (`10.0.10.0/24` e `10.0.11.0/24`) ou do `vpc_cidr`. Descartada porque qualquer outra ENI provisionada nas subnets privadas — como as funções AWS Lambda de autenticação (`lambda-customer-auth`, `lambda-staff-auth`) ou o VPC Link do API Gateway — também teria permissão de rede para alcançar as portas dos bancos e do cache, violando o isolamento de que apenas os nós do EKS devem acessar a camada de persistência.

## Consequências

### Positivas

- **Desacoplamento na ordem de provisionamento**: `infra-k8s` e os quatro repositórios de dados dependem apenas do state do `infra-base`, podendo ser provisionados simultaneamente.
- **Controle de acesso por identidade de Security Group**: o tráfego para RDS e ElastiCache é restrito às ENIs que carregam `secgrp-eks-nodes-oficina-mecanica`, excluindo Lambdas e demais recursos da VPC.
- **Responsabilidades claras**: o `infra-base` define apenas a identidade compartilhada sem regras de aplicação, enquanto cada repositório consumidor define as regras das portas que lhe pertencem.

### Negativas / Trade-offs

- **Exige que o Launch Template do EKS liste explicitamente os dois Security Groups**: ao especificar `vpc_security_group_ids` no Launch Template dos nós, o EKS deixa de anexar automaticamente o Security Group do cluster; portanto, o `infra-k8s` precisa informar tanto `cluster_security_group_id` quanto `eks_nodes_security_group_id`.

### Riscos aceitos

- **Compartilhamento da mesma identidade de rede entre os quatro serviços no cluster**: como todos os pods compartilham as ENIs dos nós do Node Group único, a distinção de acesso por serviço a cada banco ocorre pelas credenciais e endpoints de conexão injetados por namespace, e não por Security Group individual por pod (já que Security Groups for Pods exigiriam roles IAM dedicadas indisponíveis no AWS Academy).

## Referências

- [ADR 0001 — Escolha da nuvem e criação da infraestrutura de rede base](0001-escolha-de-nuvem-e-infra-base.md)
- [ADR 0002 — Controle de tráfego só por Security Groups, sem NACLs nem VPC Flow Logs](0002-postura-de-rede-apenas-security-groups.md)
- `terraform/networking.tf` e `terraform/outputs.tf` — declaração de `aws_security_group.secgrp_eks_nodes` e output `eks_nodes_security_group_id`.
- [`oficina-mecanica-infra-k8s` — Launch Template dos nós do EKS](https://github.com/FIAP-15SOAT/oficina-mecanica-infra-k8s/blob/main/terraform/eks.tf)
