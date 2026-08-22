<div align="center">

# ☁️ Oficina Mecânica — Infraestrutura Base AWS (IaC)

**Provisionamento automatizado da infraestrutura base na AWS com Terraform para a solução Oficina Mecânica.**

![Terraform](https://img.shields.io/badge/Terraform-%3E%3D1.11.0-844FBA?logo=terraform&logoColor=white)
![AWS](https://img.shields.io/badge/AWS-Cloud-FF9900?logo=amazon-aws&logoColor=white)
![Amazon EKS](https://img.shields.io/badge/Amazon%20EKS-1.35-FF9900?logo=amazoneks&logoColor=white)
![Amazon ECR](https://img.shields.io/badge/Amazon%20ECR-Registry-FF9900?logo=amazonaws&logoColor=white)

</div>

## 📋 Sobre

Este repositório contém o código de **Infraestrutura como Código (IaC)** responsável pelo provisionamento de toda a fundação em nuvem na AWS para a aplicação **Oficina Mecânica**.

Faz parte do ecossistema de microsserviços e infraestrutura da pós-graduação em Arquitetura de Software da FIAP (turma 15SOAT, Fase 2).

### 🏗️ Recursos Provisionados

1. **Rede e Conectividade (`networking.tf`)**:
   - **VPC** dedicada com bloco CIDR `10.0.0.0/16`, com suporte a DNS interno habilitado (`enable_dns_support` e `enable_dns_hostnames`).
   - **Subnets Públicas (2 AZs em `us-east-1`)**: `10.0.0.0/24` e `10.0.1.0/24` com `map_public_ip_on_launch = true` e tags para integração com ELBs públicos (`kubernetes.io/role/elb = 1`).
   - **Subnets Privadas (2 AZs em `us-east-1`)**: `10.0.10.0/24` e `10.0.11.0/24` com tags para ELBs internos (`kubernetes.io/role/internal-elb = 1`).
   - **Internet Gateway (IGW)** para saída pública e **NAT Gateway** (alocado com Elastic IP na subnet pública) para saída à internet dos nós privados.
   - Tabelas de roteamento públicas e privadas devidamente associadas.

2. **Cluster Kubernetes Gerenciado (`eks.tf`)**:
   - **Amazon EKS Cluster** versão `1.35` com endpoint público e privado habilitados.
   - **Logs do Control Plane**: Ativação de logs de `api`, `audit`, `authenticator`, `controllerManager` e `scheduler` direcionados ao **CloudWatch Log Group** com retenção de 14 dias.
   - **Security Group**: Control plane com tráfego HTTPS (porta 443) restrito à CIDR da VPC.
   - **Node Group Gerenciado**: Instâncias `t3.small` alocadas exclusivamente nas subnets privadas.

3. **Registry de Containers (`ecr.tf`)**:
   - **Amazon Elastic Container Registry (ECR)** para armazenar as imagens Docker da aplicação com varredura de vulnerabilidades (`scan_on_push = true`) e criptografia `AES256`.
   - **Lifecycle Policy**: Mantém as últimas 20 imagens, descartando builds antigas automaticamente.

---

## 📁 Estrutura do Repositório

```text
.
├── .github/
│   └── workflows/
│       ├── ci.yml        # Validação do Terraform (fmt, validate, plan) e abertura automática de PR
│       └── cd.yml        # Deploy automatizado (terraform apply) em push na main ou disparo manual
├── terraform/
│   ├── backend.tf        # Configuração do backend S3 e lock nativo
│   ├── providers.tf      # Configuração do provider AWS
│   ├── networking.tf     # VPC, Subnets, IGW, NAT Gateway e Route Tables
│   ├── eks.tf            # Cluster EKS, Node Group e CloudWatch Logs
│   ├── ecr.tf            # Repositório de imagens ECR
│   ├── locals.tf         # Convenções de nomenclatura e tags locais
│   ├── variables.tf      # Declaração de variáveis de entrada
│   ├── outputs.tf        # Saídas (cluster_name, endpoint, CA data, etc.)
│   ├── terraform.tfvars  # Valores de variáveis padrão
│   └── terraform.tfvars.example
└── .gitignore
```

---

## 💾 Estado Remoto (Remote State)

O estado do Terraform é armazenado remotamente em um bucket S3 com criptografia em repouso e suporte ao **lock nativo do S3** (disponível no Terraform ≥ 1.11 via `use_lockfile = true`):

- **Bucket**: `bkt-oficina-mecanica`
- **Chave (Key)**: `infra/prod-simulated/infra-base/terraform.tfstate`
- **Região**: `us-east-1`

Essas informações de estado são posteriormente consumidas pelo repositório [`oficina-mecanica-k8s`](https://github.com/FIAP-15SOAT/oficina-mecanica-k8s) via `data.terraform_remote_state`.

---

## ⚙️ Variáveis e Saídas

### Principais Variáveis de Entrada

| Variável | Tipo | Padrão | Descrição |
|---|---|---|---|
| `aws_region` | `string` | `us-east-1` | Região da AWS |
| `project_name` | `string` | `oficina-mecanica` | Prefixo usado para nomes de recursos e tags |
| `environment` | `string` | `prod-simulated` | Ambiente de implantação |
| `kubernetes_version` | `string` | `1.35` | Versão do Kubernetes para o cluster EKS |
| `vpc_cidr` | `string` | `10.0.0.0/16` | Bloco CIDR da VPC |
| `public_subnet_cidrs` | `list(string)` | `["10.0.0.0/24", "10.0.1.0/24"]` | CIDRs das subnets públicas (mínimo 2) |
| `private_subnet_cidrs`| `list(string)` | `["10.0.10.0/24", "10.0.11.0/24"]` | CIDRs das subnets privadas (mínimo 2) |
| `node_instance_type` | `string` | `t3.small` | Tipo de instância dos nós de trabalho |

### Saídas Exportadas (Outputs)

| Saída | Descrição |
|---|---|
| `cluster_name` | Nome do cluster EKS provisionado (consumido pelo `k8s`) |
| `cluster_endpoint` | Endpoint do API Server do cluster |
| `cluster_certificate_authority_data` | Dados da Autoridade Certificadora do cluster em base64 |
| `vpc_id` | ID da VPC criada |
| `public_subnet_ids` / `private_subnet_ids` | IDs das subnets públicas e privadas |
| `zz_next_steps` | Guia com instruções pós-apply para atualizar o kubeconfig |

---

## 🚀 Como Executar Localmente

### Pré-requisitos

- **Terraform ≥ 1.11.0**
- **AWS CLI v2** configurada com credenciais válidas (`aws configure`)
- Acesso ao bucket de state S3 (`bkt-oficina-mecanica`)

### Passo a Passo

```bash
# 1. Clonar o repositório e entrar na pasta terraform
git clone https://github.com/FIAP-15SOAT/oficina-mecanica-infra-base.git
cd oficina-mecanica-infra-base/terraform

# 2. Inicializar o Terraform
terraform init

# 3. Visualizar o plano de execução
terraform plan

# 4. Aplicar o provisionamento
terraform apply
```

Ao final do `apply`, conecte seu cliente local `kubectl` ao cluster:
```bash
aws eks update-kubeconfig --region us-east-1 --name eks-oficina-mecanica
kubectl get nodes
```

---

## 🔄 Pipelines de CI/CD

O repositório conta com pipelines automatizados via GitHub Actions:

- **CI ([`ci.yml`](.github/workflows/ci.yml))**:
  - **Gatilho**: Push em branches `feature/**` e `fix/**`.
  - **Ações**: Executa `terraform fmt -check`, `terraform init -backend=false`, `terraform validate` e gera uma prévia com `terraform plan`. Se tudo passar, abre automaticamente um Pull Request para a branch `main`.
- **CD ([`cd.yml`](.github/workflows/cd.yml))**:
  - **Gatilho**: Push na branch `main` ou disparo manual via **Run workflow** (`workflow_dispatch`).
  - **Ações**: Executa `terraform apply -auto-approve` na pasta `terraform/`. Controlado pela variável `ENABLE_DEPLOY` (executa automaticamente se `true` ou mediante disparo manual).

---

## 👥 Autores

- [Guilherme da Rocha Salvador](https://github.com/guilhermesalvador404)
- [Lucas Almeida da Silva](https://github.com/lucas-almeida-silva)
- [Ramoon Lincoln Barros Camacho](https://github.com/ramooncamacho)
- [Renan Santana Camacho](https://github.com/renancamacho)

## 📄 Licença

Projeto acadêmico (FIAP — 15SOAT), para fins educacionais. Sem licença aberta declarada (`UNLICENSED`).
